/*
 * 09_traps - trap entry, mepc/mcause/mtval, the mstatus stack, and MRET.
 *
 * The negative tests in traps/ only prove a fault is *detected*. This one
 * proves the handler is entered correctly and that execution resumes, which is
 * a much stronger statement and the thing OpenSBI depends on: it discovers
 * optional CSRs by executing them and catching the illegal-instruction trap,
 * so a trap has to be precise, resumable, and repeatable.
 *
 * The handler is deliberately minimal and shared. It records mcause, mepc and
 * mtval where the test can check them, advances mepc past the faulting
 * instruction, and returns. Everything it touches is a register the test does
 * not use, so there is no save/restore to get wrong.
 *
 * Reserved across the whole test:
 *   s8  last mcause      s9  last mepc      s10 last mtval
 *   s11 trap count
 *   a0, t6  the CHECK macro's scratch
 */

#include "test_macros.h"

TEST_ENTRY

        li      sp, 0x3F00
        la      s0, scratch
        li      s11, 0                  # trap counter

        # Install the handler. mtvec MODE is Direct, so every trap lands on
        # the same address and the handler dispatches on mcause itself.
        la      t0, trap_handler
        csrw    mtvec, t0

        # ===============================================================
        # 1. ECALL. The canonical synchronous trap.
        # ===============================================================
        la      t1, ecall_site
        ecall
ecall_site:
        # mcause = 11 (environment call from M-mode)
        CHECK   s8, 11, 1
        # mepc points at the ECALL itself, not past it. The handler had to add
        # 4 to get back here - that is software's job, not the hardware's.
        addi    t2, t1, -4
        CHECK_REG s9, t2, 2
        CHECK   s11, 1, 3

        # ===============================================================
        # 2. EBREAK. mcause = 3, breakpoint.
        # ===============================================================
        ebreak
        CHECK   s8, 3, 4
        CHECK   s11, 2, 5

        # ===============================================================
        # 3. Illegal instruction. mtval must carry the instruction bits, so a
        #    handler can decode it without re-fetching.
        # ===============================================================
        la      t1, illegal_site
        .word   0x00033283              # ld x5, 0(x6): RV64 only
illegal_site:
        CHECK   s8, 2, 6
        CHECK   s10, 0x00033283, 7      # mtval = the offending instruction
        addi    t2, t1, -4
        CHECK_REG s9, t2, 8

        # ===============================================================
        # 4. Misaligned load. mtval must carry the faulting address.
        # ===============================================================
        la      t3, scratch
        addi    t3, t3, 2               # deliberately unaligned
        lw      t4, 0(t3)
        CHECK   s8, 4, 9                # load address misaligned
        CHECK_REG s10, t3, 10           # mtval = the bad address

        # ===============================================================
        # 5. Misaligned store, a different cause with the same shape.
        # ===============================================================
        la      t3, scratch
        addi    t3, t3, 1
        sh      t4, 0(t3)
        CHECK   s8, 6, 11               # store address misaligned
        CHECK_REG s10, t3, 12

        # ===============================================================
        # 6. A non-existent CSR, which is how OpenSBI probes for features.
        #    It must trap, and it must be resumable so the probe can continue.
        # ===============================================================
        csrr    t0, 0x3A0               # pmpcfg0, deliberately not implemented
        CHECK   s8, 2, 13
        csrr    t0, 0x7C0               # a custom address, also absent
        CHECK   s8, 2, 14

        # Writing a read-only CSR, versus reading one, which must NOT trap
        csrw    cycle, x0               # illegal: CSRRW always writes
        CHECK   s8, 2, 15
        li      s7, 0
        add     s7, s11, x0             # remember the count
        rdcycle t0                      # legal: csrrs with a zero mask
        CHECK_REG s11, s7, 16           # no new trap

        # ===============================================================
        # 7. Repeatability. Ten faults in a row, which is what a feature
        #    probe actually looks like.
        # ===============================================================
        li      s7, 0
        li      t5, 10
probe_loop:
        csrr    t0, 0x3A0               # traps every time
        addi    s7, s7, 1
        blt     s7, t5, probe_loop
        CHECK   s7, 10, 17
        CHECK   s8, 2, 18

        # ===============================================================
        # 8. The mstatus privilege stack.
        #
        # On trap entry MPIE takes MIE's value and MIE clears. MRET reverses
        # it and sets MPIE to 1. So after a trap taken with MIE set and an
        # MRET, MIE must be back on.
        # ===============================================================
        # Start from a known state. MPIE is already 1 at this point, because
        # every MRET so far has set it - so the baseline has to be established
        # rather than assumed.
        # MPP is no longer pinned at 11: every MRET sets it to U, deliberately,
        # so that a handler which forgets to reload it fails loudly instead of
        # returning to the wrong mode. Establish it explicitly rather than
        # assuming what the last MRET left behind.
        li      t0, 0x88                # MIE | MPIE
        csrc    mstatus, t0
        li      t0, 0x1800              # MPP = M
        csrs    mstatus, t0
        csrr    t1, mstatus
        CHECK   t1, 0x00001800, 19

        li      t0, 0x8                 # MIE
        csrs    mstatus, t0
        csrr    t1, mstatus
        CHECK   t1, 0x00001808, 20      # MIE set

        ecall                           # entry pushes MIE into MPIE, clears MIE
        csrr    t1, mstatus
        # MIE is back on and MPIE is 1, but MPP is now 00: MRET sets it to the
        # least privileged supported mode on the way out. That is the spec being
        # deliberately unhelpful, so a handler that forgets to reload MPP
        # returns to U-mode and fails immediately rather than silently running
        # privileged code in the wrong mode.
        CHECK   t1, 0x00000088, 21

        # The handler runs with interrupts disabled - the hardware cleared MIE
        # on entry - and MPIE holds what MIE was. s6 is the handler's snapshot.
        CHECK   s6, 0x00001880, 22      # in the handler: MIE clear, MPIE set

        li      t0, 0x8
        csrc    mstatus, t0             # put MIE back to 0 for the rest

        # ===============================================================
        # 9. Traps interleaved with multi-cycle instructions. A divide takes
        #    34 cycles and a CSR access two; a trap must not land inside
        #    either, and must not lose the instruction ahead of it.
        # ===============================================================
        li      t0, 1000
        li      t1, 8
        div     t2, t0, t1              # 125, must complete
        ecall                           # trap immediately after
        CHECK   t2, 125, 23
        CHECK   s8, 11, 24

        li      t0, 7
        mul     t3, t0, t0              # 49
        .word   0x00033283              # illegal, right after the multiply
        CHECK   t3, 49, 25
        CHECK   s8, 2, 26

        # A store immediately before a trap must commit exactly once
        li      t0, 0x1234
        sw      t0, 16(s0)
        ecall
        lw      t1, 16(s0)
        CHECK   t1, 0x1234, 27

        # ===============================================================
        # 10. A trap taken on the target of a branch, so it arrives right
        #     after a pipeline flush
        # ===============================================================
        li      t0, 1
        beq     t0, t0, after_branch
        CHECK   x0, 1, 28
after_branch:
        ecall
        CHECK   s8, 11, 29

        # ===============================================================
        # 11. WFI. The spec calls it a hint and explicitly permits treating
        #     "wait for interrupt" as "carry on", which is what this core
        #     does - it has no clock to gate. So it must retire like a NOP:
        #     no trap, no stall, and execution continues past it.
        #
        #     Worth a check of its own because the alternative - decoding it
        #     as illegal - would fault OpenSBI's idle loop, and the failure
        #     would look like a hang rather than a decode bug.
        # ===============================================================
        add     s7, s11, x0             # remember the trap count
        li      t0, 0x5A5A
        wfi
        CHECK_REG s11, s7, 30           # no trap taken
        CHECK   t0, 0x5A5A, 31          # and nothing else disturbed
        wfi
        wfi                             # back to back, in case of a state machine
        CHECK_REG s11, s7, 32

TEST_END

# =========================================================================
# Trap handler.
#
# Direct mode, so this is the single entry point for every cause. It runs with
# interrupts disabled - the hardware cleared MIE on entry - so there is no
# reentrancy to worry about and no need to save anything beyond what it uses.
#
# The one thing it must get right is mepc. mepc points at the *faulting*
# instruction, so returning without advancing it would re-execute the fault
# forever. Every cause handled here is one the test wants to skip past, so it
# always adds 4. A real handler would decide per cause: a page fault fixes the
# mapping and re-executes, an ecall skips.
# =========================================================================
        .align  2
trap_handler:
        csrr    s8, mcause
        csrr    s9, mepc
        csrr    s10, mtval
        csrr    s6, mstatus             # so the test can see MIE is clear here
        addi    s11, s11, 1             # count the traps

        # Skip the faulting instruction. Every instruction here is 4 bytes
        # because there is no compressed extension.
        addi    s9, s9, 4
        csrw    mepc, s9
        csrr    s9, mepc                # read back, so the test sees mepc + 4
        addi    s9, s9, -4              # ...but report the original
        mret

        .section .bss
        .align  4
scratch:
        .space  64
