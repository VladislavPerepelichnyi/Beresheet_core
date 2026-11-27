/*
 * Linker script for running the directed tests inside the full SoC simulation.
 *
 * Identical to test.ld apart from the region size: the SoC's boot memory is a
 * 32 KB block RAM (BOOT_RAM_BYTES in wb_defines.vh), not the 64 KB flat memory
 * the core-only testbench models. Getting that wrong does not fail loudly - the
 * boot RAM simply truncates the index and the stack silently aliases onto code.
 *
 * Running the tests here as well as against the core alone is the point: with
 * zero-latency memory, mem_stall never asserts, so every hazard that depends on
 * a stalled load is untestable. Over the Wishbone bus they are real.
 */

ENTRY(_start)

MEMORY
{
    RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 32K
}

SECTIONS
{
    .text : {
        *(.text.init)
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

    . = ALIGN(16);
    __heap_start = .;
    PROVIDE(__stack_top = ORIGIN(RAM) + LENGTH(RAM));

    ASSERT(__bss_end + 2K <= ORIGIN(RAM) + LENGTH(RAM),
           "test does not fit in the SoC boot RAM")

    /DISCARD/ : { *(.comment) *(.note.*) *(.riscv.attributes) }
}
