#!/usr/bin/env python3
"""
Build a FAT32 SD card image for the SoC simulation, in the sparse form
RTL/sim/soc/sd_model.v reads.

The partition table and filesystem are made by sfdisk and mkfs.vfat rather than
by this script, so the BIOS's FAT32 reader is tested against another
implementation's reading of the specification; fsck.vfat then checks the
directory entries this script adds.

The card holds the BIOS's probe file (PROBE.TXT), a file with a long name, and
a small BOOT.TXT boot set, so the loader can be exercised without a multi-
megabyte kernel.

Usage:  mksdimage.py <out_dir> [probe_file]

Output in <out_dir>:
  sdcard.img   the whole image (usable with dd or a loop mount)
  sd_lba.hex   numbers of the non-zero sectors   (+sd_lba= in tb_soc)
  sd_dat.hex   contents of those sectors         (+sd_dat= in tb_soc)
"""
import os
import struct
import subprocess
import sys

IMG_MB      = 48
SECTOR      = 512
PART_LBA    = 2048
OUT_DIR     = "build/sim/sd"          # replaced by the command line
IMG         = os.path.join(OUT_DIR, "sdcard.img")
MAX_SPARSE  = 64          # sectors the Verilog model can hold


def run(*cmd, **kw):
    subprocess.run(cmd, check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, **kw)


def rd16(b, o): return struct.unpack_from("<H", b, o)[0]
def rd32(b, o): return struct.unpack_from("<I", b, o)[0]


def lfn_checksum(short11):
    s = 0
    for c in short11:
        s = (((s >> 1) | ((s & 1) << 7)) + c) & 0xFF
    return s


def lfn_entries(name, short11):
    """The long-name records that precede a 8.3 record, in on-disk order."""
    chk   = lfn_checksum(short11)
    utf16 = [ord(c) for c in name] + [0x0000]
    while len(utf16) % 13:
        utf16.append(0xFFFF)
    nfrag = len(utf16) // 13
    slots = [1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30]

    out = b""
    for i in range(nfrag, 0, -1):          # stored last fragment first
        e = bytearray(32)
        e[0]  = i | (0x40 if i == nfrag else 0)
        e[11] = 0x0F                       # the long-name attribute
        e[13] = chk
        for k, off in enumerate(slots):
            struct.pack_into("<H", e, off, utf16[(i - 1) * 13 + k])
        out += bytes(e)
    return out


def sfn(base, ext):
    return (base.ljust(8) + ext.ljust(3)).encode("ascii")


class Volume:
    def __init__(self, img, part_lba):
        self.f    = img
        self.base = part_lba * SECTOR
        b = self.rd(self.base, SECTOR)

        self.bps      = rd16(b, 11)
        self.spc      = b[13]
        self.reserved = rd16(b, 14)
        self.nfats    = b[16]
        self.spf      = rd32(b, 36)
        self.root     = rd32(b, 44)
        self.fsinfo   = rd16(b, 48)

        assert self.bps == SECTOR, "this script assumes 512-byte sectors"
        self.fat_off  = self.base + self.reserved * self.bps
        self.data_off = self.fat_off + self.nfats * self.spf * self.bps

    def rd(self, off, n):
        self.f.seek(off)
        return self.f.read(n)

    def wr(self, off, data):
        self.f.seek(off)
        self.f.write(data)

    def cluster_off(self, n):
        return self.data_off + (n - 2) * self.spc * self.bps

    def fat_get(self, n):
        return rd32(self.rd(self.fat_off + n * 4, 4), 0) & 0x0FFFFFFF

    def fat_set(self, n, val):
        """Write every copy of the FAT - fsck compares them."""
        for i in range(self.nfats):
            off = self.fat_off + i * self.spf * self.bps + n * 4
            old = rd32(self.rd(off, 4), 0)
            self.wr(off, struct.pack("<I", (old & 0xF0000000) | val))

    def alloc(self):
        n = 2
        while self.fat_get(n) != 0:
            n += 1
        self.fat_set(n, 0x0FFFFFFF)
        return n

    def add_file(self, base, ext, data, long_name=None, nt_flags=0):
        # Chain as many clusters as the data needs. A single-cluster writer was
        # enough until the boot descriptor grew past 512 bytes, which is exactly
        # the size a comment block reaches without anyone noticing.
        csize = self.spc * self.bps
        nclust = max(1, (len(data) + csize - 1) // csize)
        chain = [self.alloc() for _ in range(nclust)]
        for i, c in enumerate(chain):
            chunk = data[i * csize:(i + 1) * csize]
            self.wr(self.cluster_off(c), chunk.ljust(csize, b"\0"))
            # Link to the next, or leave the end-of-chain marker alloc() wrote.
            if i + 1 < nclust:
                self.fat_set(c, chain[i + 1])
        cluster = chain[0]

        short = sfn(base, ext)
        e = bytearray(32)
        e[0:11] = short
        e[11]   = 0x20                     # ATTR_ARCHIVE
        e[12]   = nt_flags                 # bit 3: lowercase base, bit 4: ext
        struct.pack_into("<H", e, 20, cluster >> 16)
        struct.pack_into("<H", e, 26, cluster & 0xFFFF)
        struct.pack_into("<I", e, 28, len(data))
        # A plausible date, so the entry does not look like uninitialised space.
        struct.pack_into("<H", e, 24, ((2026 - 1980) << 9) | (8 << 5) | 20)

        record = (lfn_entries(long_name, short) if long_name else b"") + bytes(e)
        self.append_root(record)

    def append_root(self, record):
        """Drop a record into the first free slot of the root directory."""
        off = self.cluster_off(self.root)
        end = off + self.spc * self.bps
        while off < end:
            if self.rd(off, 1)[0] in (0x00, 0xE5):
                if off + len(record) > end:
                    raise RuntimeError("root directory cluster is full")
                self.wr(off, record)
                return
            off += 32
        raise RuntimeError("root directory cluster is full")

    def invalidate_free_count(self):
        """Say 'unknown' rather than leave a stale count for fsck to complain
        about. 0xFFFFFFFF is the specified value for that."""
        off = self.base + self.fsinfo * self.bps
        if rd32(self.rd(off, 4), 0) == 0x41615252:
            self.wr(off + 488, struct.pack("<II", 0xFFFFFFFF, 0xFFFFFFFF))


def build(probe):
    os.makedirs(OUT_DIR, exist_ok=True)

    with open(IMG, "wb") as f:
        f.truncate(IMG_MB * 1024 * 1024)

    # One primary partition, type 0x0C (FAT32 LBA), starting at the customary
    # 2048-sector alignment.
    subprocess.run(["sfdisk", IMG], check=True,
                   input=f"label: dos\nstart={PART_LBA}, type=0c\n".encode(),
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    run("mkfs.vfat", "-F", "32", "-n", "BOOT", "--offset", str(PART_LBA), IMG)

    with open(IMG, "r+b") as f:
        v = Volume(f, PART_LBA)
        # NT flag bit 4 marks a lowercase extension: this is what a Linux host
        # writes for "PROBE.txt", a name that fits 8.3 apart from its case.
        v.add_file("PROBE", "TXT", probe, nt_flags=0x10)
        # A second file that genuinely needs long-name records, so the
        # reassembly path is exercised too.
        v.add_file("KERNEL~1", "BIN", bytes(range(256)),
                   long_name="kernel-image-long-name.bin")
        add_boot_set(v)
        v.invalidate_free_count()
        v.f.flush()

    check_fs()
    return sparse_sectors()


def check_fs():
    """fsck.vfat has no offset option, so hand it just the partition."""
    part = os.path.join(OUT_DIR, "part.img")
    with open(IMG, "rb") as src, open(part, "wb") as dst:
        src.seek(PART_LBA * SECTOR)
        while True:
            chunk = src.read(1 << 20)
            if not chunk:
                break
            dst.write(chunk)
    r = subprocess.run(["fsck.vfat", "-n", part],
                       capture_output=True, text=True)
    os.remove(part)
    if r.returncode != 0:
        sys.stderr.write(r.stdout + r.stderr)
        raise RuntimeError("fsck.vfat rejected the generated image")
    print("  fsck.vfat: clean")


def sparse_sectors():
    """Every sector that is not all zeroes. A 48 MB image has only a handful."""
    out = []
    with open(IMG, "rb") as f:
        lba = 0
        while True:
            s = f.read(SECTOR)
            if not s:
                break
            if any(s):
                out.append((lba, s))
            lba += 1
    return out


BOOT_TXT = """\
# Boot descriptor. One entry per line: role, file, load address.
#
# role     what the BIOS does with it
#   sbi    jump here in machine mode
#   kernel what the SBI enters next, in supervisor mode
#   dtb    passed in a1
#   load   copied in and left alone (an initrd, for instance)
#
# The addresses here are the real Linux map: the kernel takes the base of SDRAM
# because RV32 setup_vm needs a 4 MiB-aligned load address and a 4 MB Image only
# fits in the first of the two available slots.

sbi      FWDYN.BIN    0x80400000
kernel   IMAGE        0x80000000
dtb      RV32.DTB     0x80500000
"""


def add_boot_set(v):
    """
    A descriptor plus stand-in files, so the loader can be exercised without a
    four-megabyte kernel.

    Reading a real kernel over the simulated SPI link would take 8 192 sectors
    at 6 MHz - seconds of simulated time, billions of cycles. The loader's job
    is parsing, lookup, address checking and copying; none of that cares how big
    the file is. So the loader is tested here against bytes it can afford, and
    the kernel is tested by being placed in memory directly.
    """
    v.add_file("BOOT", "TXT", BOOT_TXT.encode())
    # Recognisable payloads: if the loader puts one at the wrong address, the
    # pattern says which file it was.
    v.add_file("FWDYN", "BIN", bytes([0xA1]) * 256)
    v.add_file("IMAGE", "", bytes([0xA2]) * 256)
    v.add_file("RV32", "DTB", bytes([0xA3]) * 256)


def main():
    global OUT_DIR, IMG
    if len(sys.argv) not in (2, 3):
        sys.exit(__doc__)
    OUT_DIR = sys.argv[1]
    IMG = os.path.join(OUT_DIR, "sdcard.img")
    if len(sys.argv) == 3:
        with open(sys.argv[2], "rb") as f:
            probe = f.read()
    else:
        probe = b"Probe file on the simulated SD card.\n"

    sectors = build(probe)
    print(f"  image    : {IMG} ({IMG_MB} MB)")
    print(f"  non-zero : {len(sectors)} sectors")

    if len(sectors) > MAX_SPARSE:
        raise RuntimeError(f"{len(sectors)} sectors exceeds the model's "
                           f"{MAX_SPARSE}; raise SD_SECTORS in sd_model.v")

    with open(os.path.join(OUT_DIR, "sd_lba.hex"), "w") as f:
        for lba, _ in sectors:
            f.write(f"{lba:08x}\n")
        for _ in range(MAX_SPARSE - len(sectors)):
            f.write("ffffffff\n")

    with open(os.path.join(OUT_DIR, "sd_dat.hex"), "w") as f:
        for _, data in sectors:
            for i in range(0, SECTOR, 16):
                f.write(" ".join(f"{b:02x}" for b in data[i:i + 16]) + "\n")
        for _ in range((MAX_SPARSE - len(sectors)) * SECTOR // 16):
            f.write(" ".join(["00"] * 16) + "\n")

    print(f"  model    : {OUT_DIR}/sd_lba.hex, {OUT_DIR}/sd_dat.hex")


if __name__ == "__main__":
    main()
