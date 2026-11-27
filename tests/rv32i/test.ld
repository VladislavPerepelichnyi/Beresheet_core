/*
 * Linker script for the RV32I directed tests.
 *
 * One flat 64 KiB region at the reset vector. Both simulation memories are
 * initialised from the same image, so .text is fetched from the instruction
 * memory while .rodata and .data are read from the data memory at identical
 * addresses.
 */

ENTRY(_start)

MEMORY
{
    RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 64K
}

SECTIONS
{
    .text : {
        *(.text.init)           /* reset vector first */
        *(.text)
        *(.text.*)
    } > RAM

    .rodata : ALIGN(4) {
        *(.rodata)
        *(.rodata.*)
        *(.srodata .srodata.*)
    } > RAM

    .data : ALIGN(4) {
        *(.data)
        *(.data.*)
        *(.sdata .sdata.*)
    } > RAM

    .bss (NOLOAD) : ALIGN(4) {
        __bss_start = .;
        *(.bss)
        *(.bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        __bss_end = .;
    } > RAM

    /* Scratch area the load/store tests write into, and the stack top. */
    . = ALIGN(16);
    __heap_start = .;
    PROVIDE(__stack_top = ORIGIN(RAM) + LENGTH(RAM));

    /DISCARD/ : { *(.comment) *(.note.*) *(.riscv.attributes) }
}
