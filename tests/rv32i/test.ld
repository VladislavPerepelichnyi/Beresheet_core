/*
 * Linker script for the directed tests in tests/rv32i.
 *
 * Everything - code, data, stack - lives in the SoC's boot RAM: 32 KiB at
 * 0x0000_0000, where the core starts fetching out of reset (BOOT_RAM_BYTES in
 * wb_defines.vh). The same ELF therefore runs unchanged on the full-SoC
 * simulator and on fast_sim, which models that RAM at the same address.
 *
 * The size is checked below rather than trusted. A test that outgrows the boot
 * RAM does not fail loudly on the SoC: the RAM decodes only its low address
 * bits, so the stack silently aliases onto the code.
 */

ENTRY(_start)

MEMORY
{
    RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 32K
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

    /* Scratch area for the load/store tests, and the stack top. */
    . = ALIGN(16);
    __heap_start = .;
    PROVIDE(__stack_top = ORIGIN(RAM) + LENGTH(RAM));

    ASSERT(__bss_end + 2K <= ORIGIN(RAM) + LENGTH(RAM),
           "test does not leave 2 KiB of stack in the 32 KiB boot RAM")

    /DISCARD/ : { *(.comment) *(.note.*) *(.riscv.attributes) }
}
