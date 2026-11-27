/*
 * Link a program into the 8 MB SDRAM at 0x8000_0000.
 *
 * For programs larger than the boot RAM, and for QEMU, whose virt machine has
 * no memory at address 0. In the SoC simulation a jump stub in boot RAM enters
 * the program; on the board something (a BIOS) has to load it first.
 */

MEMORY
{
    RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 8M
}

STACK_SIZE = 16K;

INCLUDE sections.ld
