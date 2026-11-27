#include "fat32.h"
#include "sdcard.h"
#include "uart.h"

/* --- byte access -------------------------------------------------------- */
/*
 * FAT stores everything little-endian and packs fields at whatever offset they
 * fall on - a 32-bit field at offset 0x1BE+8 is not word aligned. This core
 * traps on a misaligned load, so every multi-byte field is assembled from
 * bytes. It also makes the code independent of the host's endianness, which
 * matters here because the SD FIFO already had an opinion about that.
 */
static inline uint16_t rd16(const uint8_t *p)
{
    return (uint16_t)(p[0] | ((uint16_t)p[1] << 8));
}

static inline uint32_t rd32(const uint8_t *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

/* --- geometry ----------------------------------------------------------- */

static struct {
    uint32_t part_lba;        /* where the partition starts on the card   */
    uint32_t fat_lba;         /* first sector of FAT #1                   */
    uint32_t data_lba;        /* sector holding cluster 2                 */
    uint32_t sectors_per_fat;
    uint32_t root_cluster;
    uint32_t total_clusters;
    uint16_t bytes_per_sector;
    uint8_t  sectors_per_cluster;
    uint8_t  num_fats;
    uint8_t  mounted;
} fs;

static char        vol_label[12];
static const char *fat_err = "not mounted";

const char *fat32_error_text(void) { return fat_err; }
const char *fat32_label(void)      { return vol_label; }

/*
 * One sector of scratch, plus a separate one-sector FAT cache. Walking a chain
 * alternates between reading the FAT and reading data; with a single buffer
 * every step would evict the other and the card would be read twice per
 * cluster. Two buffers is 1 KB of the 32 KB boot RAM and removes that entirely.
 */
static uint8_t  sec_buf[SD_BLOCK_SIZE];
static uint8_t  fat_buf[SD_BLOCK_SIZE];
static uint32_t fat_buf_lba = 0xFFFFFFFFu;

static int read_sector(uint32_t lba, uint8_t *buf)
{
    if (sd_read_block(lba, buf) != 0) {
        fat_err = sd_error_text();
        return -1;
    }
    return 0;
}

/* First sector of a cluster. Cluster numbering starts at 2 - 0 and 1 are
 * reserved as the "free" and "end" markers, so the data area is offset by two. */
static uint32_t cluster_lba(uint32_t cluster)
{
    return fs.data_lba + (cluster - 2u) * fs.sectors_per_cluster;
}

/*
 * Next cluster in the chain, or 0 to mean "the chain ends here". Values at or
 * above 0x0FFFFFF8 are end-of-chain markers and 0x0FFFFFF7 marks a bad cluster;
 * only the low 28 bits of a FAT32 entry belong to the cluster number.
 */
static uint32_t fat_next(uint32_t cluster)
{
    uint32_t off = cluster * 4u;
    uint32_t lba = fs.fat_lba + off / fs.bytes_per_sector;
    uint32_t idx = off % fs.bytes_per_sector;
    uint32_t val;

    if (cluster < 2u || cluster >= fs.total_clusters + 2u)
        return 0;

    if (lba != fat_buf_lba) {
        if (read_sector(lba, fat_buf) != 0) {
            fat_buf_lba = 0xFFFFFFFFu;
            return 0;
        }
        fat_buf_lba = lba;
    }

    val = rd32(&fat_buf[idx]) & 0x0FFFFFFFu;
    if (val < 2u || val >= 0x0FFFFFF7u)
        return 0;
    return val;
}

/* --- mounting ----------------------------------------------------------- */

/*
 * Validate a candidate boot sector as FAT32 and record the geometry.
 *
 * The type byte in the MBR is a hint, not a fact: cards get repartitioned and
 * the byte does not always follow. Checking the BPB itself is what actually
 * decides, and the deciding test is the cluster count - FAT12/16/32 are told
 * apart by how many clusters the volume has, not by the "FAT32" string, which
 * is only a label and is allowed to be wrong.
 */
static int parse_bpb(const uint8_t *b, uint32_t part_lba)
{
    uint32_t total_sectors, root_dir_sectors, data_sectors;
    uint16_t reserved;
    uint32_t sec_per_fat;

    if (rd16(&b[510]) != 0xAA55u)
        return -1;

    fs.bytes_per_sector    = rd16(&b[11]);
    fs.sectors_per_cluster = b[13];
    reserved               = rd16(&b[14]);
    fs.num_fats            = b[16];

    if (fs.bytes_per_sector != SD_BLOCK_SIZE)
        return -1;                       /* this reader assumes 512 */
    if (fs.sectors_per_cluster == 0 || reserved == 0 || fs.num_fats == 0)
        return -1;

    /* The 16-bit count is zero on any volume too large for it; the 32-bit
     * field at 0x20 carries the real number in that case. Same idea for the
     * FAT length, which moves to a 32-bit field on FAT32. */
    total_sectors = rd16(&b[19]);
    if (total_sectors == 0)
        total_sectors = rd32(&b[32]);

    sec_per_fat = rd16(&b[22]);
    if (sec_per_fat == 0)
        sec_per_fat = rd32(&b[36]);
    if (sec_per_fat == 0 || total_sectors == 0)
        return -1;

    /* FAT32 has no fixed-size root directory, so this term is zero - but
     * computing it the general way is what makes the cluster count, and
     * therefore the FAT type test below, correct. */
    root_dir_sectors = ((uint32_t)rd16(&b[17]) * 32u + fs.bytes_per_sector - 1u)
                       / fs.bytes_per_sector;

    data_sectors = total_sectors - (reserved + fs.num_fats * sec_per_fat
                                    + root_dir_sectors);
    fs.total_clusters = data_sectors / fs.sectors_per_cluster;

    if (fs.total_clusters < 65525u)
        return -1;                       /* FAT12 or FAT16, not ours */

    fs.part_lba        = part_lba;
    fs.sectors_per_fat = sec_per_fat;
    fs.fat_lba         = part_lba + reserved;
    fs.data_lba        = fs.fat_lba + fs.num_fats * sec_per_fat + root_dir_sectors;
    fs.root_cluster    = rd32(&b[44]);

    if (fs.root_cluster < 2u)
        return -1;

    /* BS_VolLab, 11 bytes, space padded. The root directory may carry a more
     * authoritative one; see the scan in fat32_mount(). */
    {
        int i, n = 0;
        for (i = 0; i < 11; i++)
            vol_label[n++] = (char)b[71 + i];
        vol_label[n] = '\0';
        while (n > 0 && vol_label[n - 1] == ' ')
            vol_label[--n] = '\0';
    }

    return 0;
}

static void find_volume_label(void)
{
    uint32_t cluster = fs.root_cluster;
    uint32_t s;
    int      i, n;

    while (cluster) {
        for (s = 0; s < fs.sectors_per_cluster; s++) {
            if (read_sector(cluster_lba(cluster) + s, sec_buf) != 0)
                return;
            for (i = 0; i < SD_BLOCK_SIZE; i += 32) {
                uint8_t *e = &sec_buf[i];
                if (e[0] == 0x00)
                    return;                          /* end of directory */
                if (e[0] == 0xE5)
                    continue;                        /* deleted */
                if ((e[11] & 0x0F) == 0x0F)
                    continue;                        /* long-name fragment */
                if (e[11] & 0x08) {                  /* ATTR_VOLUME_ID */
                    for (n = 0; n < 11; n++)
                        vol_label[n] = (char)e[n];
                    vol_label[11] = '\0';
                    n = 11;
                    while (n > 0 && vol_label[n - 1] == ' ')
                        vol_label[--n] = '\0';
                    return;
                }
            }
        }
        cluster = fat_next(cluster);
    }
}

int fat32_mount(void)
{
    int i;

    fs.mounted  = 0;
    fat_buf_lba = 0xFFFFFFFFu;
    vol_label[0] = '\0';

    if (read_sector(0, sec_buf) != 0)
        return -1;

    /*
     * A card can be laid out either way: partitioned, or with the filesystem
     * starting at sector 0 with no partition table at all ("superfloppy").
     * Sector 0 is a valid BPB in the second case, so try it first - and if it
     * parses, there is no partition table to look at.
     */
    if (parse_bpb(sec_buf, 0) == 0) {
        fs.mounted = 1;
    } else {
        uint32_t starts[4];
        uint8_t  types[4];

        /* The partition table has to be copied out before the buffer is reused
         * to read each candidate's boot sector. */
        for (i = 0; i < 4; i++) {
            starts[i] = rd32(&sec_buf[446 + i * 16 + 8]);
            types[i]  = sec_buf[446 + i * 16 + 4];
        }

        for (i = 0; i < 4; i++) {
            if (types[i] == 0x00 || starts[i] == 0)
                continue;
            if (read_sector(starts[i], sec_buf) != 0)
                return -1;
            if (parse_bpb(sec_buf, starts[i]) == 0) {
                fs.mounted = 1;
                break;
            }
        }
    }

    if (!fs.mounted) {
        fat_err = "no FAT32 filesystem found";
        return -1;
    }

    find_volume_label();
    fat_err = "ok";
    return 0;
}

/* --- names -------------------------------------------------------------- */

static char upcase(char c)
{
    return (c >= 'a' && c <= 'z') ? (char)(c - 'a' + 'A') : c;
}

static int name_eq(const char *a, const char *b)
{
    while (*a && *b) {
        if (upcase(*a) != upcase(*b))
            return 0;
        a++; b++;
    }
    return *a == *b;
}

/* "CLAUDE  TXT" (11 bytes, space padded) -> "CLAUDE.TXT" */
static void short_name(const uint8_t *e, char *out)
{
    int i, n = 0;

    for (i = 0; i < 8 && e[i] != ' '; i++)
        out[n++] = (char)e[i];
    if (e[8] != ' ') {
        out[n++] = '.';
        for (i = 8; i < 11 && e[i] != ' '; i++)
            out[n++] = (char)e[i];
    }
    out[n] = '\0';
}

/*
 * Long names are stored backwards: the fragments precede the 8.3 record, in
 * reverse order, with a sequence number in the first byte and 0x40 marking the
 * last fragment (which is therefore the first one encountered). Thirteen
 * UTF-16 characters per fragment, split across three ranges of the record
 * because the fields around them were already spoken for by the 8.3 layout
 * this had to stay compatible with.
 *
 * Only the low byte of each character is kept: this is a boot loader reading
 * ASCII filenames, and a partial character is more use in a log than none.
 */
static void lfn_fragment(const uint8_t *e, char *dst, int *have)
{
    static const uint8_t pos[13] = { 1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30 };
    uint32_t seq = e[0] & 0x1Fu;
    int      base, i;

    if (seq == 0 || seq > 4)               /* 4 * 13 = 52 chars, our limit */
        return;

    base = (int)(seq - 1u) * 13;
    for (i = 0; i < 13; i++) {
        uint16_t ch = rd16(&e[pos[i]]);
        int      at = base + i;

        if (at >= FAT32_NAME_MAX - 1)
            break;
        if (ch == 0x0000u || ch == 0xFFFFu) {
            dst[at] = '\0';
            if (at > *have) *have = at;
            return;
        }
        dst[at] = (ch < 0x80u) ? (char)ch : '?';
        if (at + 1 > *have) *have = at + 1;
    }
}

/* --- directory walking -------------------------------------------------- */

/*
 * Both readdir and find need the same scan, so it exists once. `want` selects:
 * NULL walks and stops at entry number *idx, non-NULL searches by name.
 */
static int scan_root(const char *want, uint32_t *idx, fat32_dirent_t *out)
{
    uint32_t cluster = fs.root_cluster;
    uint32_t seen = 0;
    uint32_t s;
    char     lfn[FAT32_NAME_MAX];
    int      lfn_len = 0;
    int      i;

    if (!fs.mounted) {
        fat_err = "not mounted";
        return 0;
    }

    lfn[0] = '\0';

    while (cluster) {
        for (s = 0; s < fs.sectors_per_cluster; s++) {
            if (read_sector(cluster_lba(cluster) + s, sec_buf) != 0)
                return 0;

            for (i = 0; i < SD_BLOCK_SIZE; i += 32) {
                uint8_t *e = &sec_buf[i];
                char     sname[13];

                if (e[0] == 0x00)
                    return 0;                       /* end of directory */
                if (e[0] == 0xE5) {
                    lfn_len = 0; lfn[0] = '\0';
                    continue;
                }
                if ((e[11] & 0x0F) == 0x0F) {       /* long-name fragment */
                    if (e[0] & 0x40) {              /* last fragment: restart */
                        lfn_len = 0;
                        lfn[0]  = '\0';
                    }
                    lfn_fragment(e, lfn, &lfn_len);
                    continue;
                }
                if (e[11] & 0x08) {                 /* volume label */
                    lfn_len = 0; lfn[0] = '\0';
                    continue;
                }

                if (lfn_len > 0 && lfn_len < FAT32_NAME_MAX)
                    lfn[lfn_len] = '\0';

                short_name(e, sname);

                /*
                 * Match on either name. A file created on a PC usually has
                 * both, and which one the user types is their business.
                 */
                if (want) {
                    if (!name_eq(want, sname) &&
                        !(lfn_len > 0 && name_eq(want, lfn))) {
                        lfn_len = 0; lfn[0] = '\0';
                        continue;
                    }
                } else if (seen++ != *idx) {
                    lfn_len = 0; lfn[0] = '\0';
                    continue;
                }

                {
                    const char *src = (lfn_len > 0) ? lfn : sname;
                    int n = 0;
                    while (src[n] && n < FAT32_NAME_MAX - 1) {
                        out->name[n] = src[n];
                        n++;
                    }
                    out->name[n] = '\0';
                }
                out->first_cluster = ((uint32_t)rd16(&e[20]) << 16) | rd16(&e[26]);
                out->size          = rd32(&e[28]);
                out->attr          = e[11];
                out->is_dir        = (e[11] & 0x10) ? 1 : 0;
                if (!want)
                    (*idx)++;
                return 1;
            }
        }
        cluster = fat_next(cluster);
    }
    return 0;
}

int fat32_readdir(uint32_t *idx, fat32_dirent_t *out)
{
    return scan_root(0, idx, out);
}

int fat32_find(const char *name, fat32_dirent_t *out)
{
    uint32_t dummy = 0;

    if (scan_root(name, &dummy, out))
        return 0;
    fat_err = "file not found";
    return -1;
}

/* --- reading ------------------------------------------------------------ */

int32_t fat32_read(const fat32_dirent_t *f, uint8_t *buf, uint32_t max)
{
    uint32_t cluster = f->first_cluster;
    uint32_t left    = f->size;
    uint32_t got     = 0;
    uint32_t s, n, k;

    if (!fs.mounted) {
        fat_err = "not mounted";
        return -1;
    }
    if (left > max)
        left = max;

    while (cluster && left > 0) {
        for (s = 0; s < fs.sectors_per_cluster && left > 0; s++) {
            if (read_sector(cluster_lba(cluster) + s, sec_buf) != 0)
                return -1;

            /*
             * The last sector of a file is only partly the file - the rest is
             * whatever the cluster happened to contain. The directory's size
             * field is the only thing that says where the data stops.
             */
            n = (left < SD_BLOCK_SIZE) ? left : SD_BLOCK_SIZE;
            for (k = 0; k < n; k++)
                buf[got + k] = sec_buf[k];
            got  += n;
            left -= n;
        }
        cluster = fat_next(cluster);
    }

    return (int32_t)got;
}
