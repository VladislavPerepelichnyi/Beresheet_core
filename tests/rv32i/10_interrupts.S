/*
 * 10_interrupts - timer and software interrupts from the CLINT.
 *
 * Needs a CLINT at 0x0200_0000: runs on the full SoC and on fast_sim, which
 * models one with the same register map and the same 1 MHz mtime.
 *
 * The two sources are deliberately different in character:
 *
 *   msip   software sets it, software clears it. No timing involved, which
 *          makes it the right first interrupt to bring up.
 *   mtip   a comparison, not a latch: it is asserted for as long as
 *          mtime >= mtimecmp. The only way to clear it is to move mtimecmp
 *          forward. A handler that forgets re-enters immediately - and that is
 *          checked here, because it is the classic first timer bug.
 *
 * Reserved: s8 mcause, s9 trap count, s10 timer-tick count, s11 handler scratch
 */

#include "test_macros.h"

#define CLINT_BASE      0x02000000
#define CLINT_MSIP      (CLINT_BASE + 0x0000)
#define CLINT_MTIMECMP  (CLINT_BASE + 0x4000)
#define CLINT_MTIME     (CLINT_BASE + 0xBFF8)

#define MIE_MSIE        (1 << 3)
#define MIE_MTIE        (1 << 7)
#define MSTATUS_MIE     (1 << 3)

TEST_ENTRY

        li      sp, 0x3F00
        li      s9, 0                   # trap count
        li      s10, 0                  # timer ticks

        la      t0, irq_handler
        csrw    mtvec, t0

        # ===============================================================
        # 1. mtime advances on its own, with no help from software.
        # ===============================================================
        li      t0, CLINT_MTIME
        lw      t1, 0(t0)
        lw      t2, 0(t0)
        sub     t3, t2, t1
        li      t4, 0
        bltu    t4, t3, mtime_moves
        # a single read pair can land inside one tick, so allow a retry
        lw      t1, 0(t0)
        li      t5, 200
mtime_spin:
        addi    t5, t5, -1
        bnez    t5, mtime_spin
        lw      t2, 0(t0)
        sub     t3, t2, t1
        bltu    t4, t3, mtime_moves
        CHECK   x0, 1, 1
mtime_moves:

        # mtime must be readable through the `time` CSR too, since Zicntr
        # defines `time` as a read-only view of exactly this counter.
        rdtime  t1
        li      t0, CLINT_MTIME
        lw      t2, 0(t0)
        sub     t3, t2, t1
        li      t4, 64                  # a few ticks of slack
        bltu    t3, t4, time_csr_ok
        CHECK   x0, 1, 2
time_csr_ok:

        # ===============================================================
        # 2. A pending interrupt does nothing while it is masked. This is the
        #    two-level gate: per-source in mie, global in mstatus.MIE.
        # ===============================================================
        li      t0, CLINT_MSIP
        li      t1, 1
        sw      t1, 0(t0)               # raise the software interrupt

        csrr    t2, mip
        li      t3, (1 << 3)
        and     t2, t2, t3
        CHECK   t2, 8, 3                # mip.MSIP is set...

        li      t4, 100                 # ...but nothing happens: mie is clear
        li      t5, 0
masked_spin:
        addi    t5, t5, 1
        blt     t5, t4, masked_spin
        CHECK   s9, 0, 4                # no trap taken

        # Enabling the source alone is still not enough without the global bit
        li      t0, MIE_MSIE
        csrs    mie, t0
        li      t5, 0
masked_spin2:
        addi    t5, t5, 1
        blt     t5, t4, masked_spin2
        CHECK   s9, 0, 5                # still nothing: mstatus.MIE is clear

        # ===============================================================
        # 3. Setting mstatus.MIE takes it immediately. The spec requires the
        #    interrupt condition be re-evaluated right after a CSR write that
        #    affects it, so the very next instruction should not run.
        # ===============================================================
        li      t0, MSTATUS_MIE
        csrs    mstatus, t0             # the trap fires out of this write
        CHECK   s9, 1, 6
        CHECK   s8, 0x80000003, 7       # mcause: interrupt bit + code 3 (MSI)

        # The handler cleared msip, so mip is clear again
        csrr    t2, mip
        li      t3, (1 << 3)
        and     t2, t2, t3
        CHECK   t2, 0, 8

        # ===============================================================
        # 4. Timer interrupts. Arm mtimecmp a short way ahead and let it fire.
        # ===============================================================
        li      t0, MIE_MTIE
        csrs    mie, t0

        li      t0, CLINT_MTIME
        lw      t1, 0(t0)               # current mtime, low word
        addi    t1, t1, 40              # ~40 us at a 1 MHz tick
        li      t0, CLINT_MTIMECMP
        sw      t1, 0(t0)
        sw      x0, 4(t0)               # high word: the test never wraps

        li      t4, 20000
        li      t5, 0
timer_wait:
        addi    t5, t5, 1
        bge     s10, t4, timer_done     # never true; guards a runaway
        li      t3, 1
        bge     s10, t3, timer_done     # one tick is enough
        blt     t5, t4, timer_wait
        CHECK   x0, 1, 9                # timed out waiting for the timer
timer_done:
        CHECK   s8, 0x80000007, 10      # mcause: interrupt + code 7 (MTI)

        # ===============================================================
        # 5. mtip is a comparison, not a latch. The handler pushed mtimecmp
        #    forward, so the interrupt must have gone away - if it had only
        #    acknowledged something, it would re-enter forever and the count
        #    below would run away.
        # ===============================================================
        li      t4, 2000
        li      t5, 0
settle:
        addi    t5, t5, 1
        blt     t5, t4, settle
        # Ticks are still arriving on schedule, but nowhere near once per
        # instruction, which is what a non-clearing handler would give.
        li      t3, 100
        blt     s10, t3, tick_rate_ok
        CHECK   x0, 1, 11
tick_rate_ok:

        # ===============================================================
        # 6. Masking again stops them, and the state is undisturbed.
        # ===============================================================
        li      t0, MSTATUS_MIE
        csrc    mstatus, t0             # interrupts off
        add     s7, s10, x0             # remember the count
        li      t4, 4000
        li      t5, 0
off_spin:
        addi    t5, t5, 1
        blt     t5, t4, off_spin
        CHECK_REG s10, s7, 12           # not one more tick

        # ===============================================================
        # 7. Interrupts do not disturb ordinary work. Run a checksum with
        #    interrupts on and confirm both the result and that ticks arrived.
        # ===============================================================
        li      t0, CLINT_MTIME
        lw      t1, 0(t0)
        addi    t1, t1, 20
        li      t0, CLINT_MTIMECMP
        sw      t1, 0(t0)
        li      t0, MSTATUS_MIE
        csrs    mstatus, t0

        add     s7, s10, x0
        li      a1, 0                   # accumulator
        li      a2, 1
        li      a3, 200
sum_loop:
        add     a1, a1, a2
        mul     a4, a2, a2              # a multiply in the loop, for good measure
        add     a1, a1, a4
        addi    a2, a2, 1
        blt     a2, a3, sum_loop
        # sum of i + i*i for i = 1..199
        CHECK   a1, 2666600, 13
        # and at least one tick landed during it
        li      t3, 1
        sub     t4, s10, s7
        bge     t4, t3, worked_through
        CHECK   x0, 1, 14
worked_through:

        li      t0, MSTATUS_MIE
        csrc    mstatus, t0

TEST_END

# =========================================================================
# Interrupt handler.
#
# Interrupts are disabled on entry by hardware, so this cannot be re-entered
# and needs no save beyond the registers it uses.
#
# mepc is NOT advanced. That is the whole difference from an exception handler:
# for an interrupt mepc already points at the instruction that has not run yet,
# so MRET resumes it. Adding 4 here would silently skip an instruction.
# =========================================================================
        .align  2
irq_handler:
        csrr    s8, mcause
        addi    s9, s9, 1

        # Interrupt or exception? Bit 31 says which.
        blt     s8, x0, is_interrupt

        # An exception here is a test bug; skip it so we do not spin.
        csrr    s11, mepc
        addi    s11, s11, 4
        csrw    mepc, s11
        mret

is_interrupt:
        andi    s11, s8, 0x1F           # cause code
        li      t0, 3
        beq     s11, t0, clear_soft
        li      t0, 7
        beq     s11, t0, clear_timer
        mret                            # unknown: just return

        # A software interrupt is a latch, so clear it at the source.
clear_soft:
        li      t0, CLINT_MSIP
        sw      x0, 0(t0)
        mret

        # A timer interrupt is a comparison. Pushing mtimecmp forward is the
        # only thing that clears it.
clear_timer:
        addi    s10, s10, 1
        li      t0, CLINT_MTIME
        lw      t1, 0(t0)
        addi    t1, t1, 500             # next tick, ~500 us away
        li      t0, CLINT_MTIMECMP
        sw      t1, 0(t0)
        sw      x0, 4(t0)
        mret
