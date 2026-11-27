/*
 * 15_fence - FENCE, FENCE.TSO, PAUSE and FENCE.I.
 *
 * Three of these retire as NOPs and always have. FENCE.I does not any more:
 * it now asks the SoC to write the data cache back and invalidate the
 * instruction cache, and holds the pipeline until both report done.
 *
 * That handshake is the reason this test exists. It waits for a signal to rise
 * and then fall, and a handshake that waits for something which never happens
 * does not fail loudly - it stops the machine. fast_sim has no caches at all
 * and answers at once, the SoC has two, and FENCE.I has to terminate in both. So the whole
 * point of most of what is below is simply that it is reached.
 *
 * What FENCE.I actually does to the caches cannot be tested from here: these
 * tests run out of boot RAM, which is deliberately not cacheable. That half is
 * checked by the BIOS, which writes an instruction into SDRAM and calls it.
 */

#include "test_macros.h"

        TEST_ENTRY

        # Values that must survive every barrier below, including the ones that
        # now stall the pipeline. A hold that mishandles stage 3 would let the
        # instruction ahead commit twice, and these would move.
        li      s1, 0x11111111
        li      s2, 0x22222222
        li      s3, 0
        li      s4, 0

        # --- the three that are still no-ops ---------------------------------
        fence
        CHECK   s1, 0x11111111, 1

        fence.tso
        CHECK   s2, 0x22222222, 2

        # PAUSE is FENCE with pred=W, succ=0, fm=0 - a hint, encoded as a
        # FENCE that no assembler older than this one will name.
        .word   0x0100000F
        CHECK   s1, 0x11111111, 3

        # --- FENCE.I ---------------------------------------------------------
        # Reaching the next instruction at all is the check: this is the one
        # that waits on a handshake.
        fence.i
        li      s3, 0xABC
        CHECK   s3, 0xABC, 4
        CHECK   s1, 0x11111111, 5
        CHECK   s2, 0x22222222, 6

        # Back to back, so the sequencer has to return to idle and be usable
        # again rather than latching busy once.
        fence.i
        fence.i
        fence.i
        addi    s4, s4, 1
        CHECK   s4, 1, 7

        # --- it must not disturb the instruction ahead of it -----------------
        # An arithmetic result produced in the cycle before the stall begins has
        # to commit exactly once. Doubling it is the classic symptom of a hold
        # that stalls stage 2 without bubbling stage 3.
        li      s5, 0
        addi    s5, s5, 5
        fence.i
        CHECK   s5, 5, 8

        li      s6, 100
        addi    s6, s6, -1
        fence.i
        addi    s6, s6, -1
        fence.i
        addi    s6, s6, -1
        CHECK   s6, 97, 9

        # --- and it must not eat a branch ------------------------------------
        # The redirect is asserted for exactly the cycle the branch is in
        # stage 2. A stall that lets the branch advance while blocking the PC
        # loses it, and execution falls through.
        li      s7, 0
        li      t0, 3
1:      addi    s7, s7, 1
        fence.i
        addi    t0, t0, -1
        bnez    t0, 1b
        CHECK   s7, 3, 10

        # A taken branch immediately after a FENCE.I.
        li      s8, 0
        fence.i
        beqz    x0, 2f
        li      s8, 0xBAD               # skipped, or the branch was lost
2:      CHECK   s8, 0, 11

        # --- and a load in flight must still land ----------------------------
        la      t1, scratch
        li      t2, 0xDEADBEEF
        sw      t2, 0(t1)
        fence.i
        lw      t3, 0(t1)
        fence.i
        CHECK   t3, 0xDEADBEEF, 12

        TEST_END

        .section .data
        .align 2
scratch:
        .word 0
