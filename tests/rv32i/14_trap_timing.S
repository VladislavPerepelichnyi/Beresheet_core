/*
 * 14_trap_timing - an interrupt arriving *on* a particular instruction.
 *
 * The trap decision is registered: detected in one cycle, taken in the next,
 * with the offending instruction held in Decode/Execute in between. That split
 * is invisible to a program - unless something starts during the holding cycle
 * that should not have. This test exists for exactly those cases, and each one
 * corresponds to a mutation that the rest of the suite did not catch.
 *
 * The trick that makes it possible: an interrupt that is pending but masked is
 * taken on the instruction immediately after the write that unmasks it. So
 * arming and then placing one instruction gives precise control over which
 * instruction the interrupt lands on.
 *
 * The interrupt used is a supervisor software interrupt left *undelegated*, so
 * it traps to M-mode. mip.SSIP is software-writable, which means no CLINT is
 * needed and the test runs identically on the bare core and over the bus.
 *
 * Reserved: s5 mepc override for the handler (0 = leave mepc alone),
 *           s6 handler's mstatus snapshot, s7 handler's mscratch snapshot,
 *           s8 last mcause, s9 trap count
 */

#include "test_macros.h"

#define MSTATUS_MIE   (1 << 3)
#define MSTATUS_MPIE  (1 << 7)
#define MIE_SSIE      (1 << 1)
#define MIP_SSIP      (1 << 1)

/*
 * Leave an SSI pending and masked. The next ARM completes the arming, and the
 * instruction after it is the one the interrupt lands on.
 */
.macro ARM_IRQ
        li      t5, MSTATUS_MIE
        csrc    mstatus, t5             # MIE off FIRST, or the interrupt becomes
                                        # takeable the moment mip is written and
                                        # lands on the arming code instead of on
                                        # the instruction under test
        li      t5, MIE_SSIE
        csrw    mie, t5
        li      t5, MIP_SSIP
        csrw    mip, t5
        li      t5, MSTATUS_MIE
        csrs    mstatus, t5             # unmask last; the next instruction traps
.endm

TEST_ENTRY

        li      sp, 0x3F00
        li      s5, 0
        li      s9, 0
        csrw    mideleg, x0             # keep it a machine interrupt

        la      t0, irq_handler
        csrw    mtvec, t0

        # ===============================================================
        # 1. The arming mechanism itself. Prove the interrupt lands where
        #    this test assumes it does before relying on it.
        # ===============================================================
        li      s9, 0
        ARM_IRQ
        addi    t3, x0, 5               # the interrupt lands on this
        CHECK   s9, 1, 1
        li      t0, 0x80000001          # interrupt bit + cause 1 (SSI)
        CHECK_REG s8, t0, 2
        CHECK   t3, 5, 3                # and it still executed, after the return

        # ===============================================================
        # 2. An interrupt on a multiply.
        #
        # The RV32M unit must not be started during the holding cycle. If it
        # is, the trap flushes it mid-operation and the unit is left busy with
        # nothing to deliver to - which corrupts the *next* multiply rather
        # than this one, so the check below runs two of them.
        # ===============================================================
        # A run of them rather than one, because over the bus redirect_ok can
        # push the trap a couple of instructions past the arming write. With a
        # run, wherever it lands it lands on a multiply.
        li      t1, 7
        li      t2, 6
        li      s9, 0
        ARM_IRQ
        mul     t3, t1, t2
        mul     t3, t1, t2
        mul     t3, t1, t2
        mul     t3, t1, t2
        CHECK   s9, 1, 4
        CHECK   t3, 42, 5               # re-executed correctly after the return
        mul     t4, t1, t2              # and the unit is still healthy
        CHECK   t4, 42, 6

        # An interrupt on a divide, which is 34 cycles rather than 2.
        li      t1, 1000
        li      t2, 8
        li      s9, 0
        ARM_IRQ
        div     t3, t1, t2
        div     t3, t1, t2
        div     t3, t1, t2
        CHECK   s9, 1, 7
        CHECK   t3, 125, 8
        div     t4, t1, t2
        CHECK   t4, 125, 9

        # ===============================================================
        # 3. An interrupt on a CSR access, which must commit exactly once.
        #
        # The obvious check - "the write had not happened when the trap was
        # taken" - is wrong, and wrong in a way only the bus shows. Over
        # Wishbone a CSR access can *start* in a cycle where redirect_ok is
        # still false, so the trap is detected one instruction later and the
        # write has legitimately already committed. That is not a violation:
        # the interrupt is still taken at an instruction boundary, just a later
        # one. The bare core never shows it because ready is always high.
        #
        # What is guaranteed in both is that the access happens exactly once.
        # csrrw makes that observable: rd receives the value from before the
        # write, so a second execution would return the first one's result.
        # ===============================================================
        csrw    mscratch, x0
        li      t1, 0x5A5A5A5A
        li      s9, 0
        ARM_IRQ
        csrrw   t2, mscratch, t1        # the interrupt lands on or near this
        CHECK   s9, 1, 10
        CHECK   t2, 0, 11               # rd got the pre-write value: one commit
        csrr    t3, mscratch
        CHECK_REG t3, t1, 12            # and the write did land

        # Again with a counter, where a repeated commit is destructive rather
        # than idempotent: writing mcycle twice would freeze it.
        li      t1, 0x1000
        li      s9, 0
        ARM_IRQ
        csrrw   t2, mcycle, t1
        CHECK   s9, 1, 13
        csrr    t3, mcycle
        li      t4, 0x1000
        blt     t3, t4, cycle_bad       # must be at least what was written
        li      t4, 0x1400
        blt     t3, t4, cycle_ok        # and must have advanced, not restarted
cycle_bad:
        CHECK   x0, 1, 14
cycle_ok:
        CHECK   s9, 1, 15

        # ===============================================================
        # 4. An interrupt on an MRET.
        #
        # The MRET must not execute during the holding cycle. If it does, it
        # pops the privilege stack and then the trap pushes onto what it just
        # popped - and with MPIE and MIE set to *different* values beforehand,
        # that double move is visible in what the handler sees.
        #
        #   correct   push only:  MPIE <- MIE(1) = 1
        #   broken    pop then push: MIE <- MPIE(0) = 0, then MPIE <- MIE(0) = 0
        # ===============================================================
        # The trap overwrites mepc with the MRET's own address, so the MRET
        # would otherwise return to itself forever - which is correct hardware
        # and a broken test. s5 tells the handler where to resume instead.
        la      s5, mret_landing
        li      t0, 0x1800              # MPP = M, so MRET would stay in M-mode
        csrs    mstatus, t0
        li      t0, MSTATUS_MPIE
        csrc    mstatus, t0             # MPIE = 0, deliberately unlike MIE
        li      s6, 0
        li      s9, 0
        ARM_IRQ                         # sets MIE = 1, leaves MPIE = 0
        mret                            # the interrupt lands here
mret_landing:
        CHECK   s9, 1, 16
        li      t0, MSTATUS_MPIE
        and     t1, s6, t0
        CHECK_REG t1, t0, 17            # the handler saw MPIE = 1: one push only

        # ===============================================================
        # 5. An interrupt on a load, a store and an atomic. These already work
        #    through mem_stall, but the holding cycle is new, so the ordering
        #    guarantee is worth re-checking with the interrupt placed exactly.
        # ===============================================================
        li      s0, 0x2000
        li      t1, 0x1234
        sw      t1, 0(s0)
        li      s9, 0
        ARM_IRQ
        lw      t2, 0(s0)               # the interrupt lands here
        CHECK   s9, 1, 18
        CHECK   t2, 0x1234, 19

        li      t1, 0x9876
        li      s9, 0
        ARM_IRQ
        sw      t1, 4(s0)               # the interrupt lands here
        CHECK   s9, 1, 20
        lw      t2, 4(s0)
        CHECK   t2, 0x9876, 21          # stored exactly once

        li      t1, 100
        sw      t1, 8(s0)
        addi    t6, s0, 8
        li      t2, 5
        li      s9, 0
        ARM_IRQ
        amoadd.w t3, t2, (t6)           # the interrupt lands here
        CHECK   s9, 1, 22
        CHECK   t3, 100, 23             # rd got the pre-modify value
        li      t4, 0x2008
        lw      t5, 0(t4)
        CHECK   t5, 105, 24             # added exactly once, not twice

        # ===============================================================
        # 6. An interrupt on a taken branch, so the redirect and the trap
        #    compete for the PC in the same cycle.
        # ===============================================================
        li      s9, 0
        li      t1, 1
        ARM_IRQ
        beq     t1, t1, branch_target   # the interrupt lands here
        CHECK   x0, 1, 25               # must not fall through
branch_target:
        CHECK   s9, 1, 26

        # ===============================================================
        # 7. Back-to-back: a second interrupt armed inside the shadow of the
        #    first, so a pending trap is latched while another is retiring.
        # ===============================================================
        li      s9, 0
        ARM_IRQ
        nop
        ARM_IRQ
        nop
        ARM_IRQ
        nop
        CHECK   s9, 3, 27

        csrw    mie, x0
        li      t0, MSTATUS_MIE
        csrc    mstatus, t0

TEST_END

# =========================================================================
# Interrupt handler.
#
# Snapshots mstatus and mscratch before touching anything, because both are
# evidence: mstatus shows how many times the privilege stack moved, and
# mscratch shows whether a CSR write committed that should not have.
#
# mepc is not advanced - for an interrupt it already points at the instruction
# that has not run.
# =========================================================================
        .align  2
irq_handler:
        csrr    s6, mstatus
        csrr    s7, mscratch
        csrr    s8, mcause
        addi    s9, s9, 1

        blt     s8, x0, clear_ssip

        # An exception here is a test bug; step over it so the run ends.
        csrr    t0, mepc
        addi    t0, t0, 4
        csrw    mepc, t0
        mret

clear_ssip:
        csrw    mip, x0                 # SSIP is a plain software latch
        beqz    s5, no_override
        csrw    mepc, s5                # resume somewhere the test chose
        li      s5, 0
no_override:
        mret
