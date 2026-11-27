/*
 * Section layout shared by boot.ld and sdram.ld. Everything - code, data, bss
 * and stack - goes into the single RAM region those scripts define. Load and
 * run addresses are the same, so crt0 has no .data to copy.
 */

ENTRY(_start)

SECTIONS
{
    .text : ALIGN(4) {
        *(.text.init)
        *(.text .text.*)
    } > RAM

    .rodata : ALIGN(4) {
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
    } > RAM

    .data : ALIGN(4) {
        __data_start = .;
        *(.data .data.*)
        *(.sdata .sdata.*)
        __data_end = .;
    } > RAM

    /* gp-relative accesses reach +/- 2 KB around this point. */
    __global_pointer$ = __data_start + 0x800;

    .bss (NOLOAD) : ALIGN(4) {
        __bss_start = .;
        *(.sbss .sbss.*)
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } > RAM

    __stack_top = ORIGIN(RAM) + LENGTH(RAM);
    ASSERT(__bss_end + STACK_SIZE <= __stack_top,
           "program does not fit: .bss plus the stack overflows RAM")

    /DISCARD/ : { *(.comment) *(.note .note.*) *(.riscv.attributes) *(.eh_frame) }
}
