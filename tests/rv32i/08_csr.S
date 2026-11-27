/*
 * 08_csr - the Zicsr instructions and the Zicntr counters.
 *
 * References, both in doc/isa/:
 *   Unprivileged manual chapter 6 - the six instructions, and Table 7, which
 *                                   decides whether a given access reads and/or
 *                                   writes the CSR
 *   Unprivileged manual chapter 7 - cycle, time, instret
 *   Privileged manual section 2.1 - address conventions, and the rule that
 *                                   writing a read-only CSR is illegal
 *
 * Table 7 is the part worth testing hardest, because the corner cases are what
 * make real code work:
 *
 *   CSRRW  with rd = x0     writes, does NOT read
 *   CSRRS  with rs1 = x0    reads,  does NOT write  <- this is what rdcycle is,
 *                                                      and why reading a
 *                                                      read-only counter is legal
 *   CSRRSI with uimm = 0    reads,  does NOT write
 *
 * The hazard cases at the end matter just as much. A CSR access is a two-cycle
 * read-modify-write, so its operand has to be final before the first cycle. If
 * the instruction ahead is a load still waiting on memory, the register file's
 * bypass has not delivered yet - exactly the trap the RV32M unit fell into.
 */

#include "test_macros.h"

TEST_ENTRY

        la      s0, scratch

        # ===============================================================
        # CSRRW - atomic swap. mscratch is a plain read/write register with
        # no side effects, which makes it the right place to test mechanics.
        # ===============================================================
        li      t0, 0x12345678
        csrrw   x0, mscratch, t0        # write, rd = x0 so no read
        csrr    t1, mscratch            # pseudo for csrrs t1, mscratch, x0
        CHECK   t1, 0x12345678, 1

        li      t2, 0xAABBCCDD
        csrrw   t3, mscratch, t2        # swap: t3 gets the old value
        CHECK   t3, 0x12345678, 2
        csrr    t4, mscratch
        CHECK   t4, 0xAABBCCDD, 3

        # CSRRW with rs1 = x0 writes zero, it does not skip the write
        csrrw   t5, mscratch, x0
        CHECK   t5, 0xAABBCCDD, 4
        csrr    t6, mscratch
        CHECK   t6, 0, 5

        # ===============================================================
        # CSRRS / CSRRC - set and clear bits
        # ===============================================================
        li      t0, 0x0F0F0F0F
        csrw    mscratch, t0            # pseudo for csrrw x0, mscratch, t0
        li      t1, 0xF0F0F0F0
        csrrs   t2, mscratch, t1        # old value out, bits set in the CSR
        CHECK   t2, 0x0F0F0F0F, 6
        csrr    t3, mscratch
        CHECK   t3, 0xFFFFFFFF, 7

        li      t1, 0x0000FFFF
        csrrc   t2, mscratch, t1        # clear the low half
        CHECK   t2, 0xFFFFFFFF, 8
        csrr    t3, mscratch
        CHECK   t3, 0xFFFF0000, 9

        # rs1 = x0 must read and NOT write, so a set of nothing changes nothing
        csrrs   t4, mscratch, x0
        CHECK   t4, 0xFFFF0000, 10
        csrr    t5, mscratch
        CHECK   t5, 0xFFFF0000, 11

        # same for a clear with a zero mask
        csrrc   t4, mscratch, x0
        CHECK   t4, 0xFFFF0000, 12
        csrr    t5, mscratch
        CHECK   t5, 0xFFFF0000, 13

        # ===============================================================
        # Immediate forms. uimm is 5 bits, zero extended.
        # ===============================================================
        csrw    mscratch, x0
        csrrwi  t0, mscratch, 31        # max uimm
        CHECK   t0, 0, 14
        csrr    t1, mscratch
        CHECK   t1, 31, 15

        csrrsi  t0, mscratch, 1         # set bit 0 (already set)
        CHECK   t0, 31, 16
        csrrci  t1, mscratch, 16        # clear bit 4
        CHECK   t1, 31, 17
        csrr    t2, mscratch
        CHECK   t2, 15, 18

        # uimm = 0 on a set/clear must read and not write
        csrrsi  t3, mscratch, 0
        CHECK   t3, 15, 19
        csrr    t4, mscratch
        CHECK   t4, 15, 20

        # ===============================================================
        # Machine information registers, all read-only
        # ===============================================================
        csrr    t0, mhartid             # single hart
        CHECK   t0, 0, 21
        csrr    t1, misa                # RV32 (MXL=1) + I + M + A + S + U
        CHECK   t1, 0x40141101, 22
        csrr    t2, mvendorid           # 0 = non-commercial
        CHECK   t2, 0, 23

        # ===============================================================
        # mstatus. MPP is real state now that there are modes below M, so
        # writing zero leaves it at 00 (U) rather than reading back 11.
        # ===============================================================
        csrw    mstatus, x0
        csrr    t0, mstatus
        CHECK   t0, 0x00000000, 24      # every field clear, MPP = U

        li      t1, 0x8                 # MIE
        csrrs   t2, mstatus, t1
        csrr    t3, mstatus
        CHECK   t3, 0x00000008, 25
        csrrc   t2, mstatus, t1
        csrr    t3, mstatus
        CHECK   t3, 0x00000000, 26

        # MPP is WARL over three legal values: 00 U, 01 S, 11 M. The reserved
        # encoding 10 has to land on something legal, and M is the safe choice -
        # it cannot grant a privilege the writer did not already hold.
        li      t0, 0x00000800          # MPP = 01 (S)
        csrw    mstatus, t0
        csrr    t1, mstatus
        CHECK   t1, 0x00000800, 27
        li      t0, 0x00001000          # MPP = 10, reserved
        csrw    mstatus, t0
        csrr    t1, mstatus
        CHECK   t1, 0x00001800, 28      # coerced to 11 (M)

        # The supervisor half of the same register. sstatus must show SIE, SPIE,
        # SPP, SUM and MXR and nothing else - a kernel writing sstatus must not
        # be able to reach MPP or MPIE, or it could rewrite the machine-mode
        # context it was interrupted from.
        #
        # SUM (18) and MXR (19) joined the view when the MMU arrived. They were
        # read-only zero before, because they control a translation that did not
        # exist; they are the kernel's own controls, so sstatus is exactly where
        # they belong.
        csrw    mstatus, x0
        li      t0, 0x00000122          # SPP | SPIE | SIE
        csrw    sstatus, t0
        csrr    t1, sstatus
        CHECK   t1, 0x00000122, 29
        csrr    t1, mstatus
        CHECK   t1, 0x00000122, 30      # the same bits, in the same register
        li      t0, 0xFFFFFFFF
        csrw    sstatus, t0             # try to reach MPP and MPIE through it
        csrr    t1, mstatus
        CHECK   t1, 0x000C0122, 31      # refused: only the S fields moved

        # mtvec forces MODE to 0: only Direct is implemented, so writing a
        # vectored setting must read back as Direct rather than lie.
        li      t0, 0x80001005          # BASE with MODE = 01
        csrw    mtvec, t0
        csrr    t1, mtvec
        CHECK   t1, 0x80001004, 32      # low two bits cleared

        # ===============================================================
        # Zicntr. cycle and instret must advance; the pseudo-instructions
        # rdcycle / rdinstret are csrrs rd, counter, x0 - a read of a
        # read-only CSR with a zero mask, hence legal.
        # ===============================================================
        rdcycle t0
        rdcycle t1
        sub     t2, t1, t0              # must be strictly positive
        li      t3, 0
        bge     t3, t2, csr_bad_cycle
        j       csr_cycle_ok
csr_bad_cycle:
        CHECK   x0, 1, 33
csr_cycle_ok:

        rdinstret t0
        nop
        nop
        nop
        rdinstret t1
        sub     t2, t1, t0
        li      t3, 3                   # at least the three nops retired
        blt     t2, t3, csr_bad_instret
        j       csr_instret_ok
csr_bad_instret:
        CHECK   x0, 1, 34
csr_instret_ok:

        # time must advance too - but not on every clock. It is a real-time
        # clock: in the SoC it is the CLINT's mtime, ticking at a fixed 1 MHz
        # regardless of the CPU frequency. Two adjacent reads can legitimately
        # return the same value, so this waits for a change rather than
        # assuming one, with a bound so a stopped clock still fails.
        rdtime  t0
        li      t4, 20000               # bound, in loop iterations
csr_time_wait:
        rdtime  t1
        bne     t1, t0, csr_time_ok
        addi    t4, t4, -1
        bnez    t4, csr_time_wait
        CHECK   x0, 1, 35               # time never changed
csr_time_ok:

        # mcycle is the writable original of the same counter, so writing it
        # must be visible through the read-only view at 0xC00.
        li      t0, 0x00010000
        csrw    mcycle, t0
        rdcycle t1
        li      t2, 0x00010000
        blt     t1, t2, csr_bad_mcycle  # must be at least what we wrote
        li      t3, 0x00010100
        blt     t1, t3, csr_mcycle_ok   # and not wildly beyond it
csr_bad_mcycle:
        CHECK   x0, 1, 36
csr_mcycle_ok:

        # The high halves exist and are readable. At this point the counters
        # have not run long enough to carry, so both read zero.
        rdcycleh   t0
        CHECK      t0, 0, 37
        rdinstreth t1
        CHECK      t1, 0, 38

        # ===============================================================
        # Atomicity. A CSR access must present one snapshot: the value that
        # reaches rd is the same one the modify was computed from. For a
        # counter that changes every cycle, re-reading instead of holding a
        # capture would show up here.
        # ===============================================================
        li      t0, 0x5A5A0000
        csrw    mscratch, t0
        li      t1, 0x0000A5A5
        csrrs   t2, mscratch, t1        # t2 = old, CSR = old | mask
        csrr    t3, mscratch
        CHECK   t2, 0x5A5A0000, 39      # rd saw the pre-modify value
        CHECK   t3, 0x5A5AA5A5, 40      # CSR got exactly old | mask

        # ===============================================================
        # Hazards. Every one of these puts a fresh value in the operand
        # register immediately before the CSR access.
        # ===============================================================

        # 1. operand written by the instruction directly before
        li      t0, 0x11112222
        csrw    mscratch, t0            # RAW distance 1 into the CSR write
        csrr    t1, mscratch
        CHECK   t1, 0x11112222, 41

        # 2. operand comes straight from a load. This is the case that needs
        #    the access held until the load's writeback lands: while the load
        #    is stalled on memory the bypass is off and rs1 still reads stale.
        li      t0, 0x33334444
        sw      t0, 0(s0)
        lw      t1, 0(s0)
        csrw    mscratch, t1            # load-use straight into a CSR write
        csrr    t2, mscratch
        CHECK   t2, 0x33334444, 42

        # 3. the same, through a set rather than a swap
        csrw    mscratch, x0
        li      t0, 0x0F0F0000
        sw      t0, 4(s0)
        lw      t1, 4(s0)
        csrrs   t2, mscratch, t1        # load-use into the mask
        csrr    t3, mscratch
        CHECK   t3, 0x0F0F0000, 43

        # 4. a CSR result feeding a load address on the very next instruction
        li      t0, 8
        csrw    mscratch, t0
        csrr    t1, mscratch
        add     t2, s0, t1              # CSR result used one instruction later
        li      t3, 0xC0DE
        sw      t3, 0(t2)
        lw      t4, 8(s0)
        CHECK   t4, 0xC0DE, 44

        # 5. a CSR result feeding a branch condition immediately
        li      t0, 42
        csrw    mscratch, t0
        csrr    t1, mscratch
        li      t2, 42
        beq     t1, t2, csr_br_ok
        CHECK   x0, 1, 45
csr_br_ok:

        # 6. a CSR result straight into a multiply. Two multi-cycle units
        #    back to back, each of which holds the pipeline.
        li      t0, 12
        csrw    mscratch, t0
        csrr    t1, mscratch
        mul     t2, t1, t1
        CHECK   t2, 144, 46

        # 7. a divide result straight into a CSR write - the same collision
        #    the other way round, and the divider takes 34 cycles
        li      t0, 1000
        li      t1, 8
        div     t2, t0, t1
        csrw    mscratch, t2            # RAW out of a long divide
        csrr    t3, mscratch
        CHECK   t3, 125, 47

        # 8. a store immediately before a CSR access. The bubble pushed into
        #    Mem/Writeback must not replay it.
        li      t0, 1
        sw      t0, 12(s0)
        li      t1, 0x777
        csrw    mscratch, t1
        lw      t2, 12(s0)
        CHECK   t2, 1, 48               # still 1, not stored twice
        csrr    t3, mscratch
        CHECK   t3, 0x777, 49

        # 9. a counter read held across a stalled load.
        #
        #    This is the case that needs the capture to be a capture. The load
        #    holds memory, so the CSR access starts and then waits several
        #    cycles before it can commit - and the value it is holding changes
        #    every one of them. Re-reading instead of holding produces a
        #    perfectly plausible cycle count, so only the testbench's structural
        #    check can see the difference; the point of the sequence here is to
        #    create the multi-cycle window for it to look at.
        li      t0, 0x1234
        sw      t0, 16(s0)
        lw      t1, 16(s0)
        rdcycle t2                      # capture during the load's stall
        rdcycle t3
        sub     t4, t3, t2
        li      t5, 0
        bge     t5, t4, csr_bad_held    # must still be monotonic
        j       csr_held_ok
csr_bad_held:
        CHECK   x0, 1, 50
csr_held_ok:
        CHECK   t1, 0x1234, 51          # and the load still landed correctly

        # 10. back-to-back CSR accesses, so the two-cycle sequencer has to
        #     return to idle cleanly between them
        li      t0, 0xAAAA0000
        csrw    mscratch, t0
        csrr    t1, mscratch
        csrr    t2, mscratch
        csrr    t3, mscratch
        CHECK   t1, 0xAAAA0000, 52
        CHECK   t2, 0xAAAA0000, 53
        CHECK   t3, 0xAAAA0000, 54

        # 11. a CSR access as the target of a taken branch, so it arrives
        #     immediately after a pipeline flush
        li      t0, 1
        beq     t0, t0, csr_after_branch
        CHECK   x0, 1, 55
csr_after_branch:
        li      t1, 0x9999
        csrw    mscratch, t1
        csrr    t2, mscratch
        CHECK   t2, 0x9999, 56

        # 12. a CSR access in a loop, mixed with loads and a data-dependent
        #     branch, accumulating through the CSR itself
        csrw    mscratch, x0
        li      s1, 0
        li      s2, 8
csr_loop:
        csrr    t0, mscratch
        addi    t0, t0, 3
        csrw    mscratch, t0
        addi    s1, s1, 1
        blt     s1, s2, csr_loop
        csrr    t1, mscratch
        CHECK   t1, 24, 57

TEST_END

        .section .bss
        .align  4
scratch:
        .space  64
