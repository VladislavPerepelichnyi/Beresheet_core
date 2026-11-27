/*
 * Reset entry for the BIOS.
 *
 * Runs at address 0, which is where the core's PC_INIT_VALUE points and where
 * the linker script places .text.init. Nothing is set up yet, so the order
 * below is forced: a stack before any call, then .bss cleared before any C
 * code can read a zero-initialised global.
 */

    .section .text.init, "ax"
    .global _start
    .type   _start, @function

_start:
    /* Registers come out of reset as zero in this core, but a real reset is not
     * guaranteed to do that on every implementation, so do not depend on it for
     * anything that matters. */

    /* Stack at the top of the boot RAM, growing down. */
    la      sp, __stack_top

    /* Global pointer, for gp-relative access to small data. The .option lines
     * stop the assembler from relaxing this to a gp-relative form, which would
     * be circular since gp is what we are setting. */
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

    /* Copy .data from its load address to where it runs, in case they ever
     * differ. They do not today, since everything lives in one RAM, but the
     * loop costs nothing and removes a trap for later. */
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

    /* Install the trap vector before anything can fault. mtvec MODE stays 0
     * (Direct), so every trap lands on trap_entry and software dispatches. */
    la      t0, trap_entry
    csrw    mtvec, t0

    /* Into C. main's return value stays in a0, which is what the simulation
     * testbench reads at the ebreak below. */
    call    main

    /* Clear mtvec so the ebreak below actually stops rather than vectoring
     * back into the handler. A trap with a null vector is the one condition
     * from which no forward progress is possible, which is exactly what
     * "finished" should look like to the testbench. */
    csrw    mtvec, x0

    /* Halt. With no trap mechanism this freezes the pipeline, which is the
     * cleanest available "stop" and is what the testbench watches for. */
    ebreak

    /* If a future core resumes past ebreak, do not fall into whatever follows. */
halt_forever:
    j       halt_forever

    .size   _start, . - _start

/* =========================================================================
 * Trap entry.
 *
 * This part has to be assembly, and the reason is worth being clear about: an
 * interrupt can arrive between any two instructions, and the interrupted code
 * has no idea it happened. So everything the C handler is allowed to clobber
 * must be saved first. The RISC-V ABI says a function may freely destroy the
 * caller-saved registers - ra, t0-t6, a0-a7 - so those are exactly the ones
 * that need saving here. The callee-saved registers (s0-s11) are safe: if the C
 * handler uses them it will save them itself.
 *
 * That is 16 words, and this cost is why interrupt latency is never zero.
 *
 * The stack used is whatever sp happens to hold. That is fine for M-mode-only
 * firmware where there is one stack. The moment U-mode exists, sp could belong
 * to user code and might be garbage - which is what mscratch is for: swap in a
 * known-good handler stack with a single csrrw before touching memory.
 * =========================================================================*/
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

    /* trap_handler(mcause, mepc, mtval) -> the address to resume at */
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

    /* MRET restores MIE from MPIE and jumps to mepc. Everything the trap
     * pushed is popped by this one instruction. */
    mret

    .size   trap_entry, . - trap_entry
