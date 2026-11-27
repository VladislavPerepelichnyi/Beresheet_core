/*
 * Linker script for the BIOS.
 *
 * Everything lives in the FPGA's block RAM: code, data, bss and stack. That is
 * deliberate. The BIOS has to be able to test SDRAM, which means it cannot be
 * running from it or keeping its stack there - a memory fault would take the
 * BIOS down with it and report nothing.
 *
 * SDRAM is therefore declared but nothing is placed in it. It exists here only
 * so the map is documented in one place.
 */

ENTRY(_start)

MEMORY
{
    /* Block RAM at the reset vector. Must match BOOT_RAM_BYTES in wb_defines.vh
     * and the region decode on addr[31:28]. */
    BOOT  (rwx) : ORIGIN = 0x00000000, LENGTH = 32K

    /* 8 MB embedded SDRAM. Test target only. */
    SDRAM (rw)  : ORIGIN = 0x80000000, LENGTH = 8M
}

SECTIONS
{
    .text : ALIGN(4)
    {
        *(.text.init)              /* reset vector first */
        *(.text .text.*)
    } > BOOT

    .rodata : ALIGN(4)
    {
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
    } > BOOT

    .data : ALIGN(4)
    {
        __data_start = .;
        *(.data .data.*)
        *(.sdata .sdata.*)
        __data_end = .;
    } > BOOT
    /* Load and run addresses are the same here; crt0 copies between them
     * anyway, so this stays correct if that ever changes. */
    __data_load_start = LOADADDR(.data);

    /*
     * gp points into the middle of the small-data area so that gp-relative
     * accesses reach +/- 2 KB of it. 0x800 is the conventional offset.
     */
    __global_pointer$ = MIN(__data_start + 0x800,
                            MAX(__data_start + 0x800, __data_end - 0x800));

    .bss (NOLOAD) : ALIGN(4)
    {
        __bss_start = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } > BOOT

    /* Stack occupies the top of the boot RAM and grows down towards .bss.
     * 4 KB is generous for a BIOS with no recursion. */
    __stack_size = 4K;
    __stack_top  = ORIGIN(BOOT) + LENGTH(BOOT);
    __heap_start = __bss_end;

    /* Fail the link rather than silently overlapping stack and bss. */
    ASSERT(__bss_end + __stack_size <= __stack_top,
           "BIOS does not fit: .bss plus stack overflows the boot RAM")

    /DISCARD/ : { *(.comment) *(.note .note.*) *(.riscv.attributes) *(.eh_frame) }
}
