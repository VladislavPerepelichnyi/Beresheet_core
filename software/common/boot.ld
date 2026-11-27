/*
 * Link a program into the 32 KB boot RAM at the reset vector.
 *
 * This is what the board runs when the program replaces the BIOS
 * (make synth BIOS_BR=...), and what `make sim` loads directly.
 */

MEMORY
{
    RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 32K
}

STACK_SIZE = 2K;

INCLUDE sections.ld
