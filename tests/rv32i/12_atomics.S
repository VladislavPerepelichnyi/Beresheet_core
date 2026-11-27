/*
 * 12_atomics - the RV32A extension. Chapter 13 of the Unprivileged ISA.
 *
 * Two families with quite different failure modes, so they are tested
 * differently:
 *
 *   the AMOs      a read-modify-write with a defined result. Every one has an
 *                 arithmetic answer that can be checked, and rd must get the
 *                 value from *before* the modify - the classic bug is returning
 *                 the new value, which is invisible whenever the operation
 *                 happens to be idempotent.
 *   LR / SC       a protocol. Nothing about a single LR or SC is interesting;
 *                 what matters is which sequences make an SC fail. Since this
 *                 machine has one hart and nothing else writes memory, the
 *                 failures reachable from software are: no reservation at all,
 *                 a different address, an intervening SC, an intervening store,
 *                 and an intervening trap.
 *
 * Runs on fast_sim and on the full SoC. The SoC run is the one that means
 * something: with fast_sim's zero-latency memory the read and write halves of
 * an RMW are adjacent cycles, so nothing can get between them even if the
 * sequencer is wrong. Over Wishbone each half is a real multi-cycle
 * transaction.
 *
 * Reserved: s0 scratch base, s1 secondary address, s8 mcause, s9 trap count.
 * t6 is CHECK's own scratch register, so it must never hold an address across
 * a check.
 */

#include "test_macros.h"

#define MSTATUS_MIE     (1 << 3)

TEST_ENTRY

        li      sp, 0x3F00
        li      s0, 0x2000              # scratch area, well clear of the code
        li      s9, 0

        la      t0, exc_handler
        csrw    mtvec, t0

        # ===============================================================
        # 1. AMOADD. rd gets the old value, memory gets the sum.
        # ===============================================================
        li      t1, 100
        sw      t1, 0(s0)
        li      t2, 23
        amoadd.w t3, t2, (s0)
        CHECK   t3, 100, 1              # rd = the value from before
        lw      t4, 0(s0)
        CHECK   t4, 123, 2              # memory = old + rs2

        # Again on the same word, to prove the second one sees the first.
        li      t2, 7
        amoadd.w t3, t2, (s0)
        CHECK   t3, 123, 3
        lw      t4, 0(s0)
        CHECK   t4, 130, 4

        # Negative addend, and wrap-around.
        li      t1, 5
        sw      t1, 0(s0)
        li      t2, -8
        amoadd.w t3, t2, (s0)
        CHECK   t3, 5, 5
        lw      t4, 0(s0)
        CHECK   t4, -3, 6

        # ===============================================================
        # 2. AMOSWAP. The one that would pass a weak test even if rd were
        #    wrong, so the old value is checked explicitly.
        # ===============================================================
        li      t1, 0xAAAA5555
        sw      t1, 0(s0)
        li      t2, 0x12345678
        amoswap.w t3, t2, (s0)
        CHECK   t3, 0xAAAA5555, 7
        lw      t4, 0(s0)
        CHECK   t4, 0x12345678, 8

        # rd = x0. The read still happens and the write still happens; only the
        # register write is discarded. The spec calls this out as the form used
        # for parallel reductions.
        li      t2, 0x0F0F0F0F
        amoswap.w x0, t2, (s0)
        lw      t4, 0(s0)
        CHECK   t4, 0x0F0F0F0F, 9

        # rs2 = x0 is an ordinary zero operand, not a special case.
        amoswap.w t3, x0, (s0)
        CHECK   t3, 0x0F0F0F0F, 10
        lw      t4, 0(s0)
        CHECK   t4, 0, 11

        # ===============================================================
        # 3. The bitwise three.
        # ===============================================================
        li      t1, 0xFF00FF00
        sw      t1, 0(s0)
        li      t2, 0x0FF00FF0
        amoand.w t3, t2, (s0)
        CHECK   t3, 0xFF00FF00, 12
        lw      t4, 0(s0)
        CHECK   t4, 0x0F000F00, 13

        li      t1, 0xFF00FF00
        sw      t1, 0(s0)
        amoor.w t3, t2, (s0)
        CHECK   t3, 0xFF00FF00, 14
        lw      t4, 0(s0)
        CHECK   t4, 0xFFF0FFF0, 15

        li      t1, 0xFF00FF00
        sw      t1, 0(s0)
        amoxor.w t3, t2, (s0)
        CHECK   t3, 0xFF00FF00, 16
        lw      t4, 0(s0)
        CHECK   t4, 0xF0F0F0F0, 17

        # ===============================================================
        # 4. Signed and unsigned min/max. The point of testing all four is the
        #    sign boundary: 0xFFFFFFFF is -1 signed and the largest value
        #    unsigned, so a min/max that uses the wrong comparison gives the
        #    opposite answer on exactly this pair.
        # ===============================================================
        li      t1, -1
        sw      t1, 0(s0)
        li      t2, 1

        amomax.w t3, t2, (s0)           # signed: max(-1, 1) = 1
        CHECK   t3, -1, 18
        lw      t4, 0(s0)
        CHECK   t4, 1, 19

        li      t1, -1
        sw      t1, 0(s0)
        amomaxu.w t3, t2, (s0)          # unsigned: max(0xFFFFFFFF, 1) = 0xFFFFFFFF
        CHECK   t3, -1, 20
        lw      t4, 0(s0)
        CHECK   t4, -1, 21

        li      t1, -1
        sw      t1, 0(s0)
        amomin.w t3, t2, (s0)           # signed: min(-1, 1) = -1
        CHECK   t3, -1, 22
        lw      t4, 0(s0)
        CHECK   t4, -1, 23

        li      t1, -1
        sw      t1, 0(s0)
        amominu.w t3, t2, (s0)          # unsigned: min(0xFFFFFFFF, 1) = 1
        CHECK   t3, -1, 24
        lw      t4, 0(s0)
        CHECK   t4, 1, 25

        # Equal operands, where < and <= disagree. The result is the same either
        # way, which is the point: this must not depend on the tie-break.
        li      t1, 42
        sw      t1, 0(s0)
        li      t2, 42
        amomax.w t3, t2, (s0)
        CHECK   t3, 42, 26
        lw      t4, 0(s0)
        CHECK   t4, 42, 27

        # ===============================================================
        # 5. Hazards around an RMW.
        #
        # An AMO holds the pipeline for two bus transactions, so the
        # instructions on either side of it are the interesting ones: a
        # dependency feeding in, and a dependency reading the result out.
        # ===============================================================
        li      t1, 1000
        sw      t1, 0(s0)

        # rs2 produced by the immediately preceding instruction
        addi    t2, x0, 11
        amoadd.w t3, t2, (s0)
        CHECK   t3, 1000, 28

        # rd consumed by the immediately following instruction
        li      t2, 5
        amoadd.w t3, t2, (s0)
        addi    t5, t3, 1
        CHECK   t5, 1012, 29            # 1011 + 1

        # The address register produced by the instruction before
        addi    s1, s0, 4
        li      t1, 77
        sw      t1, 4(s0)
        li      t2, 3
        amoadd.w t3, t2, (s1)
        CHECK   t3, 77, 30
        lw      t4, 4(s0)
        CHECK   t4, 80, 31

        # An AMO immediately after a load from the same word: the load is still
        # in flight over the bus when the AMO reaches Decode/Execute.
        li      t1, 500
        sw      t1, 0(s0)
        lw      t1, 0(s0)
        amoadd.w t3, t1, (s0)           # rs2 is the value just loaded
        CHECK   t3, 500, 32
        lw      t4, 0(s0)
        CHECK   t4, 1000, 33

        # An AMO in a loop, so the same sequencer runs many times in a row. A
        # sequencer that restarted once would show up here as a doubled sum.
        sw      x0, 0(s0)
        li      t2, 1
        li      t5, 0
        li      a1, 20
amo_loop:
        amoadd.w x0, t2, (s0)
        addi    t5, t5, 1
        blt     t5, a1, amo_loop
        lw      t4, 0(s0)
        CHECK   t4, 20, 34

        # Back-to-back AMOs with no instruction in between.
        sw      x0, 0(s0)
        li      t2, 3
        amoadd.w t3, t2, (s0)
        amoadd.w t4, t2, (s0)
        amoadd.w t5, t2, (s0)
        CHECK   t3, 0, 35
        CHECK   t4, 3, 36
        CHECK   t5, 6, 37
        lw      t1, 0(s0)
        CHECK   t1, 9, 38

        # An AMO must not disturb its neighbours in memory.
        li      t1, 0x11111111
        sw      t1, -4(s0)
        li      t1, 0x33333333
        sw      t1, 4(s0)
        li      t1, 0x22222222
        sw      t1, 0(s0)
        li      t2, 1
        amoadd.w x0, t2, (s0)
        lw      t3, -4(s0)
        CHECK   t3, 0x11111111, 39
        lw      t3, 4(s0)
        CHECK   t3, 0x33333333, 40
        lw      t3, 0(s0)
        CHECK   t3, 0x22222223, 41

        # ===============================================================
        # 6. LR / SC, the straightforward case.
        # ===============================================================
        li      t1, 0x600D
        sw      t1, 0(s0)
        lr.w    t2, (s0)
        CHECK   t2, 0x600D, 42          # LR is a load
        li      t3, 0xBEEF
        sc.w    t4, t3, (s0)
        CHECK   t4, 0, 43               # 0 means it stored
        lw      t5, 0(s0)
        CHECK   t5, 0xBEEF, 44

        # ===============================================================
        # 7. The ways an SC must fail.
        # ===============================================================

        # (a) No reservation at all. The previous SC cleared it, and the spec
        #     is explicit that an SC invalidates the reservation whether it
        #     succeeded or not - which is what makes "an SC pairs with the most
        #     recent LR" true.
        li      t3, 0xDEAD
        sc.w    t4, t3, (s0)
        CHECK   t4, 1, 45               # non-zero: failed
        lw      t5, 0(s0)
        CHECK   t5, 0xBEEF, 46          # and memory is untouched

        # (b) A second SC after a successful one.
        lr.w    t2, (s0)
        li      t3, 0x1111
        sc.w    t4, t3, (s0)
        CHECK   t4, 0, 47
        li      t3, 0x2222
        sc.w    t4, t3, (s0)
        CHECK   t4, 1, 48
        lw      t5, 0(s0)
        CHECK   t5, 0x1111, 49          # the second store did not happen

        # (c) A different address from the LR.
        lr.w    t2, (s0)
        addi    s1, s0, 4
        li      t3, 0x3333
        sc.w    t4, t3, (s1)
        CHECK   t4, 1, 50
        lw      t5, 4(s0)
        CHECK   t5, 0x33333333, 51      # untouched, still the value from §5

        # ...and that failing SC must have invalidated the reservation too.
        # "An SC must fail if there is another SC (to any address) between the
        # LR and the SC" - which is what makes an SC pair with exactly one LR.
        #
        # This is the case a weaker test misses, because a *successful* SC also
        # invalidates simply by being a store to the reserved word: remove the
        # rule and nothing changes for the sequences that succeed. Only a failed
        # SC in between tells the two apart.
        li      t3, 0x4321
        sc.w    t4, t3, (s0)
        CHECK   t4, 1, 52               # the reservation went with the failed SC
        lw      t5, 0(s0)
        CHECK   t5, 0x1111, 53          # and nothing was stored

        # (d) An ordinary store to the reserved word in between. Not required
        #     for a single hart - only another hart's store must fail an SC -
        #     but this core clears the reservation anyway, and a constrained
        #     LR/SC loop is forbidden from containing stores, so nothing
        #     portable can notice.
        li      t1, 0x4444
        sw      t1, 0(s0)
        lr.w    t2, (s0)
        li      t1, 0x5555
        sw      t1, 0(s0)
        li      t3, 0x6666
        sc.w    t4, t3, (s0)
        CHECK   t4, 1, 54
        lw      t5, 0(s0)
        CHECK   t5, 0x5555, 55

        # (e) An AMO to the reserved word. Same rule: it is a store.
        lr.w    t2, (s0)
        li      t2, 1
        amoadd.w x0, t2, (s0)
        li      t3, 0x7777
        sc.w    t4, t3, (s0)
        CHECK   t4, 1, 56
        lw      t5, 0(s0)
        CHECK   t5, 0x5556, 57          # the AMO happened, the SC did not

        # (f) A trap in between. The spec lists "H traps" as a way for a
        #     constrained loop to end, and clearing here means a context switch
        #     cannot leave a stale reservation for the next thread to succeed
        #     against.
        li      t1, 0x8888
        sw      t1, 0(s0)
        lr.w    t2, (s0)
        ecall                           # exc_handler steps over it
        li      t3, 0x9999
        sc.w    t4, t3, (s0)
        CHECK   t4, 1, 58
        lw      t5, 0(s0)
        CHECK   t5, 0x8888, 59
        CHECK   s8, 11, 60              # and the trap really was taken

        # ===============================================================
        # 8. A compare-and-swap, written the way the spec's Listing 2 does.
        #    This is the sequence real code actually uses, and the reason the
        #    whole extension exists.
        # ===============================================================
        li      t1, 40
        sw      t1, 0(s0)

        # cas(addr = s0, expected = 40, desired = 41)
        li      a1, 40
        li      a2, 41
cas_retry:
        lr.w    t0, (s0)
        bne     t0, a1, cas_fail
        sc.w    t0, a2, (s0)
        bnez    t0, cas_retry           # spurious failure: try again
        li      a3, 0
        j       cas_done
cas_fail:
        li      a3, 1
cas_done:
        CHECK   a3, 0, 61               # it swapped
        lw      t5, 0(s0)
        CHECK   t5, 41, 62

        # And the mismatching case must not store.
        li      a1, 999                 # expected, deliberately wrong
        li      a2, 7
cas2_retry:
        lr.w    t0, (s0)
        bne     t0, a1, cas2_fail
        sc.w    t0, a2, (s0)
        bnez    t0, cas2_retry
        li      a3, 0
        j       cas2_done
cas2_fail:
        li      a3, 1
cas2_done:
        CHECK   a3, 1, 63
        lw      t5, 0(s0)
        CHECK   t5, 41, 64              # unchanged

        # ===============================================================
        # 9. A spinlock, acquired and released. amoswap with aq / rl - the
        #    ordering bits must be accepted even though this core needs no
        #    extra ordering to honour them.
        # ===============================================================
        sw      x0, 8(s0)               # lock = 0, free
        addi    s1, s0, 8

        li      t0, 1
        amoswap.w.aq t0, t0, (s1)
        CHECK   t0, 0, 65               # saw it free, so we hold it now
        lw      t1, 0(s1)
        CHECK   t1, 1, 66               # and it is marked held

        li      t0, 1
        amoswap.w.aq t0, t0, (s1)
        CHECK   t0, 1, 67               # a second attempt sees it held

        amoswap.w.rl x0, x0, (s1)       # release
        lw      t1, 0(s1)
        CHECK   t1, 0, 68

        # aq and rl on LR / SC, which is how a sequentially consistent LR/SC
        # sequence is written.
        lr.w.aq t2, (s1)
        CHECK   t2, 0, 69
        li      t3, 1
        sc.w.rl t4, t3, (s1)
        CHECK   t4, 0, 70

        # ===============================================================
        # 10. Alignment. An AMO or SC reports cause 6 (Store/AMO address
        #     misaligned) and an LR reports cause 4 (Load address misaligned) -
        #     the split matters because a handler dispatches on it.
        # ===============================================================
        addi    s1, s0, 2               # deliberately not word aligned

        li      s9, 0
        li      t2, 1
        amoadd.w t3, t2, (s1)
        CHECK   s8, 6, 71
        CHECK   s9, 1, 72

        li      s9, 0
        lr.w    t2, (s1)
        CHECK   s8, 4, 73
        CHECK   s9, 1, 74

        li      s9, 0
        li      t3, 5
        sc.w    t4, t3, (s1)
        CHECK   s8, 6, 75
        CHECK   s9, 1, 76

        # A misaligned atomic must not have written anything. 0(s0) still holds
        # what section 5 left there, and 8(s0) what section 9's SC stored.
        lw      t5, 8(s0)
        CHECK   t5, 1, 77

        # ===============================================================
        # 11. funct3 = 011 is the RV64 doubleword form and must trap here.
        #     Encoded by hand because the assembler refuses amoadd.d on RV32.
        # ===============================================================
        li      s9, 0
        .word   0x0060B02F              # amoadd.d x0, x6, (x1)
        CHECK   s8, 2, 78               # illegal instruction
        CHECK   s9, 1, 79

TEST_END

# =========================================================================
# Exception handler. Records the cause and steps over the offending
# instruction, so a deliberate fault does not end the run.
# =========================================================================
        .align  2
exc_handler:
        csrr    s8, mcause
        addi    s9, s9, 1
        csrr    t0, mepc
        addi    t0, t0, 4
        csrw    mepc, t0
        mret
