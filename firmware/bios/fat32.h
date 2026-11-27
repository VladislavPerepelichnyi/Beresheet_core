/*
 * A read-only FAT32 reader, enough to find a file by name and read its bytes.
 *
 * The layout it walks, outermost first:
 *
 *   MBR         sector 0 of the card. Four 16-byte partition entries at 0x1BE,
 *               each giving a type byte and the LBA the partition starts at.
 *   BPB         the partition's first sector: sector size, cluster size, how
 *               many FATs there are and how long each one is. Every other
 *               address on the card is computed from these five numbers.
 *   FAT         one 32-bit entry per cluster, each holding the number of the
 *               next cluster in the file. A file is a linked list, and the list
 *               lives in the FAT rather than in the data.
 *   directory   32-byte records, themselves stored in a cluster chain.
 *
 * Read only, root directory only: enough for a boot loader to find a file by
 * name and read it.
 */
#ifndef FAT32_H
#define FAT32_H

#include <stdint.h>

#define FAT32_NAME_MAX 64

typedef struct {
    char     name[FAT32_NAME_MAX];  /* long name if present, else 8.3 */
    uint32_t first_cluster;
    uint32_t size;
    uint8_t  attr;
    uint8_t  is_dir;
} fat32_dirent_t;

/* Find and mount the first FAT32 partition. 0 on success. */
int fat32_mount(void);

/* The volume label, from the root directory if it has one, else the BPB. */
const char *fat32_label(void);
const char *fat32_error_text(void);

/* Walk the root directory. Set *idx to 0 first; returns 1 while entries
 * remain, 0 at the end. Volume-label and deleted records are skipped. */
int fat32_readdir(uint32_t *idx, fat32_dirent_t *out);

/* Find a file in the root directory by name, matched case-insensitively
 * against both the long name and the 8.3 name. 0 on success. */
int fat32_find(const char *name, fat32_dirent_t *out);

/* Read up to max bytes of the file into buf. Returns the byte count, or -1. */
int32_t fat32_read(const fat32_dirent_t *f, uint8_t *buf, uint32_t max);

#endif
