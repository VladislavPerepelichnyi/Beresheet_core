/*
 * Boot descriptor loader, in the spirit of LiteX's boot.json.
 *
 * The BIOS has no idea what it is booting. It mounts the first FAT32 partition,
 * reads a text file that says which files go where, copies them into SDRAM and
 * hands over. Changing what the machine boots is then editing a text file on
 * the card, not rebuilding the BIOS - which is the whole point.
 *
 * Format, one entry per line, '#' starts a comment:
 *
 *     # role   file             address
 *     kernel   Image            0x80000000
 *     sbi      fw_dynamic.bin   0x80400000
 *     dtb      rv32.dtb         0x80500000
 *     load     initrd.cpio      0x80600000
 *
 * The roles are what turn a list of files into a handoff:
 *
 *     sbi     where to jump, in machine mode
 *     kernel  what the SBI should enter next, in supervisor mode
 *     dtb     the device tree, passed in a1
 *     load    copied in and otherwise ignored - an initrd, a splash, anything
 *
 * A role is explicit rather than inferred from the filename because inferring
 * it is the kind of cleverness that fails silently on a card somebody else
 * prepared.
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
 * Mount, read the descriptor, load everything it names. Returns 0 if the plan
 * is complete enough to boot. Does not jump anywhere - the caller decides.
 */
int boot_load_from_sd(boot_plan_t *plan);

/* Hand over: a0 = hartid, a1 = dtb, a2 = the fw_dynamic struct. Never returns. */
void boot_handoff(const boot_plan_t *plan);

#endif
