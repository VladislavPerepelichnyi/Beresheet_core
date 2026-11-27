/*
 * BIOS reset entry and machine-mode trap entry.
 *
 * _start runs at address 0, the core's reset vector. It sets up the stack and
 * gp, clears .bss, copies .data, installs the trap vector and calls main().
 */

    .section .text.init, "ax"
    .global _start
    .type   _start, @function

_start:
    /* Stack at the top of boot RAM, growing down. */
    la      sp, __stack_top

    /* gp must be loaded without linker relaxation, which would turn this into
     * a gp-relative access to gp itself. */
    .option push
    .option norelax
    la      gp, __global_pointer$
    .option pop

    /* Clear .bss. */
    la      t0, __bss_start
    la      t1, __bss_end
    bgeu    t0, t1, bss_done
bss_loop:
    sw      zero, 0(t0)
    addi    t0, t0, 4
    bltu    t0, t1, bss_loop
bss_done:

    /* Copy .data to its run address. bios.ld places it in boot RAM, so load
     * and run addresses are equal and the loop is skipped. */
    la      t0, __data_load_start
    la      t1, __data_start
    la      t2, __data_end
    beq     t0, t1, data_done
    bgeu    t1, t2, data_done
data_loop:
    lw      t3, 0(t0)
    sw      t3, 0(t1)
    addi    t0, t0, 4
    addi    t1, t1, 4
    bltu    t1, t2, data_loop
data_done:

    /* Direct mode: every trap enters trap_entry. */
    la      t0, trap_entry
    csrw    mtvec, t0

    /* main's return value stays in a0, where the simulation testbench reads
     * the result when it sees the ebreak. */
    call    main

    /* With mtvec cleared, the ebreak below cannot vector back into the
     * handler; the testbench treats it as the end of the run. */
    csrw    mtvec, x0
    ebreak

halt_forever:
    j       halt_forever

    .size   _start, . - _start

/*
 * Trap entry.
 *
 * A trap can arrive between any two instructions, so every register the C
 * handler may clobber is saved first: ra, t0-t6 and a0-a7, the caller-saved set
 * of the RISC-V ABI. s0-s11 are preserved by the handler itself. The handler
 * runs on the interrupted stack, which is the BIOS's only stack.
 */
    .section .text, "ax"
    .align  4
    .global trap_entry
    .type   trap_entry, @function
trap_entry:
    addi    sp, sp, -64
    sw      ra,   0(sp)
    sw      t0,   4(sp)
    sw      t1,   8(sp)
    sw      t2,  12(sp)
    sw      t3,  16(sp)
    sw      t4,  20(sp)
    sw      t5,  24(sp)
    sw      t6,  28(sp)
    sw      a0,  32(sp)
    sw      a1,  36(sp)
    sw      a2,  40(sp)
    sw      a3,  44(sp)
    sw      a4,  48(sp)
    sw      a5,  52(sp)
    sw      a6,  56(sp)
    sw      a7,  60(sp)

    /* trap_handler(mcause, mepc, mtval) returns the address to resume at. */
    csrr    a0, mcause
    csrr    a1, mepc
    csrr    a2, mtval
    call    trap_handler
    csrw    mepc, a0

    lw      ra,   0(sp)
    lw      t0,   4(sp)
    lw      t1,   8(sp)
    lw      t2,  12(sp)
    lw      t3,  16(sp)
    lw      t4,  20(sp)
    lw      t5,  24(sp)
    lw      t6,  28(sp)
    lw      a0,  32(sp)
    lw      a1,  36(sp)
    lw      a2,  40(sp)
    lw      a3,  44(sp)
    lw      a4,  48(sp)
    lw      a5,  52(sp)
    lw      a6,  56(sp)
    lw      a7,  60(sp)
    addi    sp, sp, 64

    /* mret restores MIE from MPIE and the privilege mode from MPP. */
    mret

    .size   trap_entry, . - trap_entry
