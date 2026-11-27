/*
 * 18_div_irq - multi-cycle division with interrupts arriving mid-operation.
 *
 * The gap this closes: every existing test runs division with interrupts
 * globally masked. 06_muldiv and 12_atomics never touch mie, and neither did
 * 17_umode_mem. But the divider takes tens of cycles per operation, and Linux
 * takes a timer interrupt every 10 ms forever, so under an OS the two overlap
 * constantly and have never once been exercised together here.
 *
 * Why that matters: on hardware, a static glibc binary printed one line and
 * hung on the next. The next line was the first to format a number, which
 * compiles to divu/remu, and every assembly probe that ran correctly contained
 * zero div/rem instructions. Division in isolation is correct - in M-mode,
 * in U-mode, translated, with a zero divisor, with a dividend smaller than the
 * divisor, and next to a translated load. What was left untested was division
 * that gets interrupted.
 *
 * Two failure modes are being hunted, and they look very different from the
 * outside:
 *
 *   a hang - the interrupt flushes the pipeline while the divider is running
 *     and its busy flag is never cleared, so the next division stalls forever.
 *     This is silent, and over a serial console it is indistinguishable from a
 *     dead core. It is exactly what the board did.
 *
 *   a wrong answer - the division restarts or its result is committed to the
 *     wrong register after the interrupt. Worse than a hang, because userspace
 *     keeps running on corrupt arithmetic.
 *
 * Method: arm the CLINT to interrupt often relative to the division rate, then
 * run a long division loop checking every result against a value computed
 * without division. Ordering is deliberately varied - divisions back to back,
 * a division straddling a load, and a remainder immediately after a quotient -
 * because a stall-handshake bug usually needs one specific adjacency.
 *
 * SoC only: the CLINT is a bus slave.
 *
 * Reserved: s3/s4/s5 handler scratch, s8 last mcause, s9 interrupt count
 */

#include "test_macros.h"

#define CLINT_BASE      0x02000000
#define CLINT_MTIMECMP  (CLINT_BASE + 0x4000)
#define CLINT_MTIME     (CLINT_BASE + 0xBFF8)

#define MIE_MTIE        (1 << 7)
#define MSTATUS_MIE     (1 << 3)

/* How often the timer fires, in mtime ticks. mtime runs at 1 MHz, so 20 ticks
 * is 20 us - far more often than Linux, deliberately, to raise the chance of
 * landing inside a divide rather than between two of them. */
#define TICK_PERIOD     20

        TEST_ENTRY

        la      t0, m_handler
        csrw    mtvec, t0
        li      s9, 0                   # interrupts serviced
        li      s8, 0

        # Arm the first deadline, then enable the timer interrupt and the
        # global gate.
        li      t0, CLINT_MTIME
        lw      t1, 0(t0)
        li      t2, TICK_PERIOD
        add     t1, t1, t2
        li      t0, CLINT_MTIMECMP
        sw      t1, 0(t0)
        sw      x0, 4(t0)               # high word

        li      t0, MIE_MTIE
        csrs    mie, t0
        li      t0, MSTATUS_MIE
        csrs    mstatus, t0

        # ===============================================================
        # 1. Back-to-back divisions, 512 of them, every result checked.
        #
        #    The loop computes 1000/d and 1000%d for d = 1..8 repeatedly and
        #    reconstructs the dividend with a multiply: q*d + r must equal
        #    1000 exactly. That identity catches a wrong quotient and a wrong
        #    remainder without needing a division to verify a division.
        # ===============================================================
        li      s1, 512                 # iterations
        li      s2, 1                   # divisor, cycles 1..8
1:
        li      t0, 1000
        divu    t1, t0, s2              # quotient
        remu    t2, t0, s2              # remainder, straight after
        mul     t3, t1, s2
        add     t3, t3, t2
        CHECK   t3, 1000, 1             # q*d + r == dividend

        # A load between the divide and its use, so the divider's stall
        # overlaps a cache access as well as an interrupt.
        li      t0, 1000
        divu    t4, t0, s2
        lw      t5, scratch_ptr
        CHECK_REG t4, t1, 2             # same operands, same answer

        addi    s2, s2, 1
        li      t6, 9
        bne     s2, t6, 2f
        li      s2, 1
2:
        addi    s1, s1, -1
        bnez    s1, 1b

        # ===============================================================
        # 2. Signed division, same idea. The sign-fixup path is separate
        #    logic and gets its own interrupted run.
        # ===============================================================
        li      s1, 256
3:
        li      t0, -1000
        li      t1, 7
        div     t2, t0, t1
        rem     t3, t0, t1
        mul     t4, t2, t1
        add     t4, t4, t3
        CHECK   t4, -1000, 3            # holds for truncating division
        addi    s1, s1, -1
        bnez    s1, 3b

        # ===============================================================
        # 3. The interrupts have to have actually happened, or this test
        #    proves nothing at all. A quiet CLINT would let every check
        #    above pass while testing exactly what 06_muldiv already does.
        # ===============================================================
        li      t0, 8
        blt     s9, t0, 4f              # fewer than 8 is not a real overlap
        j       5f
4:      li      a0, 99                  # distinct id: the test did not run
        j       test_fail
5:

        csrw    mie, x0
        TEST_END

# -----------------------------------------------------------------------------
# Timer interrupt: rearm and return. mcause has the top bit set for interrupts,
# and 7 in the low bits for M-mode timer.
# -----------------------------------------------------------------------------
m_handler:
        csrr    s8, mcause
        addi    s9, s9, 1

        # s3/s4/s5 only, never t0-t6. The handler runs at an arbitrary point
        # inside the loop below, and that loop holds its quotient and remainder
        # in t1 and t2. A handler that used the temporaries would corrupt the
        # very results this test compares, and report a core bug that is really
        # a bug in the test - which is what the first version of this file did,
        # failing on its first iteration.
        #
        # Rearm before returning, or the interrupt re-fires immediately and no
        # forward progress is ever made: a self-inflicted version of the hang
        # being hunted.
        li      s3, CLINT_MTIME
        lw      s4, 0(s3)
        li      s5, TICK_PERIOD
        add     s4, s4, s5
        li      s3, CLINT_MTIMECMP
        sw      s4, 0(s3)
        mret

        .section .data
        .balign 4
scratch_ptr:
        .word   0x5A5A5A5A
