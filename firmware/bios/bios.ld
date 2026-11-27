/*
 * BIOS linker script.
 *
 * Code, data, bss and stack all live in boot RAM. Nothing is placed in SDRAM:
 * the BIOS tests SDRAM and loads images into it, so it must not depend on it.
 */

ENTRY(_start)

MEMORY
{
    /* Block RAM at the reset vector. Must match BOOT_RAM_BYTES in
     * RTL/bus/wb_defines.vh. */
    BOOT  (rwx) : ORIGIN = 0x00000000, LENGTH = 32K

    /* 8 MB SDRAM, listed for reference only. */
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
    __data_load_start = LOADADDR(.data);

    /* gp points 0x800 into the small-data area, so gp-relative accesses reach
     * +/- 2 KB around it. */
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

    /* The stack grows down from the top of boot RAM towards .bss. */
    __stack_size = 4K;
    __stack_top  = ORIGIN(BOOT) + LENGTH(BOOT);

    ASSERT(__bss_end + __stack_size <= __stack_top,
           "BIOS does not fit: .bss plus stack overflows the boot RAM")

    /DISCARD/ : { *(.comment) *(.note .note.*) *(.riscv.attributes) *(.eh_frame) }
}
