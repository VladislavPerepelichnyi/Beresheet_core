/*
 * Start-up code for bare-metal programs built with `make compile-bin`.
 *
 * Sets up gp and sp, clears .bss, calls main() and passes its return value to
 * _exit. Programs may also call _exit(code) directly.
 *
 * Exit convention, shared with the test suite (tests/rv32i/test_macros.h):
 * a0 holds the exit code (0 = success) and the program executes EBREAK with
 * mtvec = 0. The simulators treat a trap to address 0 as the end of the run,
 * and on the board the core stops there.
 *
 * QEMU has no such convention, so under QEMU (recognised by a non-zero
 * marchid; this core reports 0) _exit first writes the code to the virt
 * machine's SiFive test device, which ends the emulator.
 */

        .section .text.init, "ax"
        .globl  _start
_start:
        csrw    mtvec, zero             /* any trap ends the run */

        .option push
        .option norelax                 /* gp is not set up yet */
        la      gp, __global_pointer$
        .option pop
        la      sp, __stack_top

        la      t0, __bss_start
        la      t1, __bss_end
1:      bgeu    t0, t1, 2f
        sw      zero, 0(t0)
        addi    t0, t0, 4
        j       1b
2:
        call    main
        /* fall through with main's return value in a0 */

        .globl  _exit
_exit:
        csrr    t0, marchid
        beqz    t0, 4f

        li      t0, 0x00100000          /* QEMU virt: SiFive test device */
        li      t1, 0x5555              /* pass */
        beqz    a0, 3f
        slli    t1, a0, 16              /* fail: (code << 16) | 0x3333 */
        li      t2, 0x3333
        or      t1, t1, t2
3:      sw      t1, 0(t0)

4:      csrw    mtvec, zero
        ebreak
5:      j       5b
