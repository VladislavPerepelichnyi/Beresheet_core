/*
 * QEMU boot shim: stands in for the BIOS's SD boot hand-off.
 *
 * `make qemu BIN=<BOOT.TXT>` loads every image at its BOOT.TXT address and
 * starts here. Like the BIOS, this enters OpenSBI fw_dynamic in M-mode with
 *   a0 = hart id
 *   a1 = device tree
 *   a2 = struct fw_dynamic_info, asking OpenSBI to enter the kernel in S-mode
 * so QEMU boots the same images, at the same addresses, through the same
 * protocol as the board.
 *
 * BOOT_ENTRY, BOOT_DTB and BOOT_NEXT_ADDR come from the descriptor
 * (scripts/run_image.py defines). The shim is position independent and is
 * loaded into the virt machine's boot ROM, outside the RAM the images use.
 */

#define FW_DYNAMIC_MAGIC    0x4942534f      /* "OSBI" */
#define FW_DYNAMIC_VERSION  2
#define PRV_S               1

        .section .text.init, "ax"
        .globl  _start
_start:
        csrr    a0, mhartid
        li      a1, BOOT_DTB
        lla     a2, fw_dynamic_info
        li      t0, BOOT_ENTRY
        jr      t0

        .balign 4
fw_dynamic_info:                        /* include/sbi/fw_dynamic.h */
        .word   FW_DYNAMIC_MAGIC        /* magic */
        .word   FW_DYNAMIC_VERSION      /* version */
        .word   BOOT_NEXT_ADDR          /* next_addr */
        .word   PRV_S                   /* next_mode */
        .word   0                       /* options */
        .word   0                       /* boot_hart: QEMU runs one hart, id 0 */
