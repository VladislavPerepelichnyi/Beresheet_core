/*
 * Boot from SD card, driven by a descriptor file.
 *
 * The BIOS mounts the first FAT32 filesystem on the card, reads BOOT.TXT from
 * the root directory, copies each file it names into SDRAM, and jumps to the
 * SBI firmware. What to boot is changed by editing BOOT.TXT, not the BIOS.
 *
 * BOOT.TXT holds one entry per line: role, file name, load address in hex.
 * Blank lines and lines starting with '#' are ignored; CR LF is accepted.
 *
 *     # role   file             address
 *     kernel   Image            0x80000000
 *     load     rootfs.gz        0x80400000
 *     dtb      custom.dtb       0x806F0000
 *     sbi      fw_dynamic.bin   0x80700000
 *
 * Roles:
 *
 *     sbi     entered in M-mode (required)
 *     kernel  next stage, entered by the SBI in S-mode
 *     dtb     device tree, passed in a1
 *     load    loaded and otherwise unused, e.g. an initramfs
 *
 * Every file must lie entirely inside SDRAM.
 */
#ifndef BOOT_H
#define BOOT_H

#include <stdint.h>

#define BOOT_DESC_FILE "BOOT.TXT"

typedef struct {
    uint32_t sbi_addr;
    uint32_t kernel_addr;
    uint32_t dtb_addr;
    int      have_sbi, have_kernel, have_dtb;
    int      loaded;            /* files copied in */
    int      errors;
} boot_plan_t;

/*
 * Initialise the card, mount it, read the descriptor and load every file it
 * names. Returns 0 if all entries loaded and there is an sbi entry. Does not
 * jump.
 */
int boot_load_from_sd(boot_plan_t *plan);

/*
 * Jump to plan->sbi_addr in M-mode using OpenSBI's fw_dynamic protocol:
 * a0 = hart ID, a1 = plan->dtb_addr, a2 = struct fw_dynamic_info naming
 * plan->kernel_addr as the next stage. Never returns.
 */
void boot_handoff(const boot_plan_t *plan);

#endif
