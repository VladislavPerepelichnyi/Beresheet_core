/*
 * 13_privilege - M / S / U modes, trap delegation, and the restricted views.
 *
 * The point of this test is not that the registers exist; 08_csr covers that.
 * It is that privilege *changes* behaviour: the same instruction is legal in one
 * mode and illegal in another, the same trap lands in one handler or a different
 * one depending on medeleg, and the same register shows different bits through
 * sstatus than through mstatus.
 *
 * How to get in and out of a lower mode, since it is not obvious:
 *
 *   down    set mstatus.MPP to the mode you want, mepc to where to land, MRET
 *   back    execute anything that traps. The trap goes to M (unless delegated),
 *           and the M handler returns to the address left in s7 with MPP = M.
 *
 * The M handler distinguishes the two cases by MPP - the mode the trap came
 * from. A trap from M just steps over the offending instruction; a trap from S
 * or U returns to s7. That needs no flags and cannot get out of step.
 *
 * Reserved: s7 M-mode resume address, s8 last mcause, s9 M trap count,
 *           s10 last scause, s11 S trap count.
 */

#include "test_macros.h"

#define MSTATUS_SIE   (1 << 1)
#define MSTATUS_MIE   (1 << 3)
#define MSTATUS_SPIE  (1 << 5)
#define MSTATUS_MPIE  (1 << 7)
#define MSTATUS_SPP   (1 << 8)
#define MSTATUS_MPP   (3 << 11)
#define MSTATUS_MPP_S (1 << 11)
#define MSTATUS_TVM   (1 << 20)
#define MSTATUS_TW    (1 << 21)
#define MSTATUS_TSR   (1 << 22)

#define MIP_SSIP      (1 << 1)
#define MIE_SSIE      (1 << 1)

TEST_ENTRY

        li      sp, 0x3F00
        li      s7, 0
        li      s9, 0
        li      s11, 0

        la      t0, m_handler
        csrw    mtvec, t0
        la      t0, s_handler
        csrw    stvec, t0

        # ===============================================================
        # 1. misa says S and U exist. OpenSBI reads exactly this to decide
        #    whether it may boot at all, so it is not decoration.
        # ===============================================================
        csrr    t0, misa
        CHECK   t0, 0x40141101, 1

        # ===============================================================
        # 2. medeleg and mideleg exist, and only the delegatable bits stick.
        #    The spec's discovery procedure is literally "write one to every
        #    bit location, then read back", so that is what this does.
        # ===============================================================
        li      t0, 0xFFFFFFFF
        csrw    medeleg, t0
        csrr    t1, medeleg
        CHECK   t1, 0x0000B35D, 2       # page faults, ecalls S/U, misaligned,
                                        # breakpoint, illegal, instr misaligned
        csrw    mideleg, t0
        csrr    t1, mideleg
        CHECK   t1, 0x00000222, 3       # SEI, STI, SSI only

        # Machine interrupts must never be delegatable: an M interrupt handed
        # to S-mode would be a trap moving to a lower privilege.
        csrr    t1, mideleg
        li      t3, 0x888               # MEI | MTI | MSI
        and     t2, t1, t3
        CHECK   t2, 0, 4

        csrw    medeleg, x0
        csrw    mideleg, x0

        # ===============================================================
        # 3. Drop to U-mode and come back. Nothing exotic, but everything
        #    after this depends on it working.
        # ===============================================================
        la      s7, back_from_u
        la      t0, u_code
        csrw    mepc, t0
        li      t0, MSTATUS_MPP
        csrc    mstatus, t0             # MPP = 00 = U
        li      s9, 0
        mret
u_code:
        ecall                           # cause 8: environment call from U-mode
        ebreak                          # come home
back_from_u:
        CHECK   s9, 2, 5
        CHECK   s8, 8, 6                # ECALL from U-mode

        # ===============================================================
        # 4. Drop to S-mode. Same shape, different cause.
        # ===============================================================
        la      s7, back_from_s
        la      t0, s_code
        csrw    mepc, t0
        li      t0, MSTATUS_MPP
        csrc    mstatus, t0
        li      t0, MSTATUS_MPP_S
        csrs    mstatus, t0             # MPP = 01 = S
        li      s9, 0
        mret
s_code:
        ecall                           # cause 9: environment call from S-mode
        ebreak
back_from_s:
        CHECK   s9, 2, 7
        CHECK   s8, 9, 8                # ECALL from S-mode

        # ===============================================================
        # 5. Privilege checks on CSR access. The address encodes the lowest
        #    mode that may touch it, so this is the whole rule.
        # ===============================================================
        la      s7, back_from_u2
        la      t0, u_csr
        csrw    mepc, t0
        li      t0, MSTATUS_MPP
        csrc    mstatus, t0
        li      s9, 0
        mret
u_csr:
        csrr    t0, mstatus             # 0x300, needs M
        csrr    t0, sstatus             # 0x100, needs S
        ebreak
back_from_u2:
        CHECK   s9, 3, 9                # two illegal accesses plus the ebreak
        CHECK   s8, 2, 10               # both were illegal instruction

        # From S-mode, sstatus is legal and mstatus is not.
        la      s7, back_from_s2
        la      t0, s_csr
        csrw    mepc, t0
        li      t0, MSTATUS_MPP
        csrc    mstatus, t0
        li      t0, MSTATUS_MPP_S
        csrs    mstatus, t0
        li      s9, 0
        mret
s_csr:
        csrr    t0, sstatus             # legal in S
        csrr    t0, mstatus             # not legal in S
        ebreak
back_from_s2:
        CHECK   s9, 2, 11               # one illegal access plus the ebreak
        CHECK   s8, 2, 12

        # ===============================================================
        # 6. MRET is M-only. Running it in S-mode must fault rather than
        #    silently promoting the caller.
        # ===============================================================
        la      s7, back_from_s3
        la      t0, s_mret
        csrw    mepc, t0
        li      t0, MSTATUS_MPP
        csrc    mstatus, t0
        li      t0, MSTATUS_MPP_S
        csrs    mstatus, t0
        li      s9, 0
        mret
s_mret:
        mret                            # illegal from S-mode
        ebreak
back_from_s3:
        CHECK   s9, 2, 13
        CHECK   s8, 2, 14               # the MRET faulted as an illegal instruction

        # ===============================================================
        # 7. Exception delegation. With ECALL-from-U delegated, the same
        #    instruction lands in the S-mode handler instead, and the machine
        #    registers must be left alone - "the mcause, mepc, and mtval
        #    registers and the MPP and MPIE fields of mstatus are not written".
        # ===============================================================
        li      t0, 0x100               # bit 8: ECALL from U-mode
        csrw    medeleg, t0

        li      s9, 0
        li      s11, 0

        la      s7, back_from_deleg
        la      t0, u_deleg
        csrw    mepc, t0
        li      t0, MSTATUS_MPP
        csrc    mstatus, t0
        mret
u_deleg:
        ecall                           # now delegated: goes to S, not M
        # The S handler steps over it and returns here, still in U-mode.
        # Breakpoint is not delegated, so that is the way back to M.
        ebreak
back_from_deleg:
        CHECK   s11, 1, 15              # the S handler ran...
        CHECK   s10, 8, 16              # ...with scause = ECALL from U-mode
        CHECK   s9, 1, 17               # and M saw only the breakpoint
        csrw    medeleg, x0

        # ===============================================================
        # 8. A trap taken in M-mode is never delegated, however medeleg is
        #    set. Traps do not move to a lower privilege.
        # ===============================================================
        li      t0, 0x4                 # bit 2: illegal instruction
        csrw    medeleg, t0
        li      s9, 0
        li      s11, 0
        li      s7, 0                   # trapping from M: step over it
        csrr    t0, 0x3A0               # pmpcfg0: illegal, executed in M-mode
        CHECK   s9, 1, 18               # handled in M...
        CHECK   s11, 0, 19              # ...and S never saw it
        csrw    medeleg, x0

        # ===============================================================
        # 9. sstatus is a view, not a register. Writing it must reach SIE,
        #    SPIE and SPP and nothing else, or a kernel could rewrite the
        #    machine context it was interrupted from.
        # ===============================================================
        csrw    mstatus, x0
        li      t0, MSTATUS_MPP | MSTATUS_MPIE
        csrs    mstatus, t0             # MPP = M, MPIE = 1
        li      t0, 0xFFFFFFFF
        csrw    sstatus, t0             # try to clear them through sstatus
        csrr    t1, mstatus
        andi    t2, t1, 0x80            # MPIE
        CHECK   t2, 0x80, 20            # untouched
        srli    t2, t1, 11
        andi    t2, t2, 3               # MPP
        CHECK   t2, 3, 21               # untouched
        csrr    t1, sstatus
        CHECK   t1, 0x000C0122, 22      # MXR | SUM | SPP | SPIE | SIE, and
                                        # nothing else. SUM and MXR became
                                        # real when translation did.

        # ===============================================================
        # 10. sie and sip are gated by mideleg: an interrupt that is not
        #     delegated is read-only zero there, so a kernel cannot mask an
        #     interrupt machine mode kept for itself.
        # ===============================================================
        csrw    mideleg, x0
        li      t0, 0xFFFFFFFF
        csrw    sie, t0                 # nothing is delegated yet
        csrr    t1, sie
        CHECK   t1, 0, 23

        li      t0, MIE_SSIE
        csrw    mideleg, t0             # delegate the supervisor software irq
        csrw    sie, t0
        csrr    t1, sie
        CHECK   t1, MIE_SSIE, 24        # now visible and settable
        csrr    t1, mie
        CHECK   t1, MIE_SSIE, 25        # and it is the same bit of mie

        # ===============================================================
        # 11. A delegated interrupt taken in S-mode. This is the mechanism
        #     the whole SBI timer path is built on: machine mode raises a
        #     supervisor pending bit, and the kernel's handler sees it.
        # ===============================================================
        li      t0, MIP_SSIP
        csrw    mip, t0                 # M-mode raises SSIP for the kernel
        csrr    t1, mip
        andi    t2, t1, MIP_SSIP
        CHECK   t2, MIP_SSIP, 26

        li      s9, 0
        li      s11, 0
        la      s7, back_from_irq
        la      t0, s_irq
        csrw    mepc, t0
        li      t0, MSTATUS_MPP
        csrc    mstatus, t0
        li      t0, MSTATUS_MPP_S
        csrs    mstatus, t0
        li      t0, MSTATUS_SPIE
        csrs    mstatus, t0             # SIE <- 1 on the way in, via SPIE
        mret
s_irq:
        # SIE is now set, SSIE is set, SSIP is pending and delegated, so the
        # interrupt fires here rather than on any instruction in particular.
        nop
        nop
        nop
        ebreak                          # come home either way; if the interrupt
                                        # never arrived, the next check fails
back_from_irq:
        CHECK   s11, 1, 27              # the S handler ran exactly once
        li      t0, 0x80000001          # interrupt bit + cause 1 (SSI)
        CHECK_REG s10, t0, 28

        # The handler cleared SSIP, so nothing is left pending.
        csrr    t1, mip
        andi    t2, t1, MIP_SSIP
        CHECK   t2, 0, 29

        csrw    mideleg, x0
        csrw    mie, x0
        csrw    mip, x0

        # ===============================================================
        # 12. Counter enables. mcounteren had to arrive with U-mode - the
        #     spec makes it mandatory there and forbids it otherwise - and
        #     this is what it does.
        # ===============================================================
        csrw    mcounteren, x0
        csrw    scounteren, x0

        la      s7, back_from_ctr
        la      t0, u_ctr
        csrw    mepc, t0
        li      t0, MSTATUS_MPP
        csrc    mstatus, t0
        li      s9, 0
        mret
u_ctr:
        rdcycle t0                      # denied: mcounteren.CY is clear
        rdtime  t0                      # denied
        ebreak
back_from_ctr:
        CHECK   s9, 3, 30               # two denials plus the breakpoint

        # Enable them for S and U, then the same reads must work.
        li      t0, 0x7                 # CY | TM | IR
        csrw    mcounteren, t0
        csrw    scounteren, t0

        la      s7, back_from_ctr2
        la      t0, u_ctr2
        csrw    mepc, t0
        li      t0, MSTATUS_MPP
        csrc    mstatus, t0
        li      s9, 0
        mret
u_ctr2:
        rdcycle t0
        rdtime  t0
        rdinstret t0
        ebreak
back_from_ctr2:
        CHECK   s9, 1, 31               # only the breakpoint trapped

        # ===============================================================
        # 13. mstatus.TW and mstatus.TSR. Both exist so machine mode can
        #     intercept something a lower mode would otherwise do freely.
        # ===============================================================
        li      t0, MSTATUS_TW
        csrs    mstatus, t0

        la      s7, back_from_tw
        la      t0, u_tw
        csrw    mepc, t0
        li      t0, MSTATUS_MPP
        csrc    mstatus, t0
        li      s9, 0
        mret
u_tw:
        wfi                             # illegal outside M when TW is set
        ebreak
back_from_tw:
        CHECK   s9, 2, 32
        CHECK   s8, 2, 33
        li      t0, MSTATUS_TW
        csrc    mstatus, t0

        # WFI is fine again with TW clear.
        la      s7, back_from_tw2
        la      t0, u_tw2
        csrw    mepc, t0
        li      t0, MSTATUS_MPP
        csrc    mstatus, t0
        li      s9, 0
        mret
u_tw2:
        wfi                             # a no-op now
        ebreak
back_from_tw2:
        CHECK   s9, 1, 34

        # TSR makes SRET trap in S-mode.
        li      t0, MSTATUS_TSR
        csrs    mstatus, t0
        la      s7, back_from_tsr
        la      t0, s_tsr
        csrw    mepc, t0
        li      t0, MSTATUS_MPP
        csrc    mstatus, t0
        li      t0, MSTATUS_MPP_S
        csrs    mstatus, t0
        li      s9, 0
        mret
s_tsr:
        sret                            # illegal from S when TSR is set
        ebreak
back_from_tsr:
        CHECK   s9, 2, 35
        li      t0, MSTATUS_TSR
        csrc    mstatus, t0

        # ===============================================================
        # 14. satp exists and reads zero, which is how a hart says it
        #     supports no translation mode. TVM still guards it.
        # ===============================================================
        csrr    t0, satp
        CHECK   t0, 0, 36

        li      t0, MSTATUS_TVM
        csrs    mstatus, t0
        la      s7, back_from_tvm
        la      t0, s_tvm
        csrw    mepc, t0
        li      t0, MSTATUS_MPP
        csrc    mstatus, t0
        li      t0, MSTATUS_MPP_S
        csrs    mstatus, t0
        li      s9, 0
        mret
s_tvm:
        csrr    t0, satp                # illegal from S when TVM is set
        ebreak
back_from_tvm:
        CHECK   s9, 2, 37
        li      t0, MSTATUS_TVM
        csrc    mstatus, t0

        # ===============================================================
        # 15. sfence.vma is accepted and does nothing. With no translation
        #     there is nothing cached to invalidate, but Linux executes it
        #     during early boot, so decoding it is not optional.
        # ===============================================================
        li      s9, 0
        li      s7, 0
        sfence.vma
        sfence.vma x0, x0
        CHECK   s9, 0, 38               # no trap in M-mode

TEST_END

# =========================================================================
# Machine-mode handler.
#
# EBREAK is this test's "come home" marker, and everything else is stepped over.
# That split is what lets a block running in U-mode hit several faults in a row
# and only then climb back to M: an earlier version returned to M on the first
# trap of any kind, which made every excursion exactly one instruction long.
#
# Stepping over keeps the current mode, because MRET returns to MPP and MPP still
# holds the mode the trap came from. Coming home overwrites MPP with M first.
#
# Breakpoint causes are not recorded in s8, so s8 keeps the last *interesting*
# cause rather than always ending up as 3.
# =========================================================================
        .align  2
m_handler:
        addi    s9, s9, 1
        csrr    t3, mcause
        blt     t3, x0, m_irq

        li      t4, 3
        beq     t3, t4, m_come_home

        add     s8, t3, x0
        csrr    t3, mepc
        addi    t3, t3, 4
        csrw    mepc, t3
        mret

m_come_home:
        csrw    mepc, s7
        li      t4, MSTATUS_MPP
        csrs    mstatus, t4             # MPP = 11, so MRET lands in M
        mret

m_irq:
        add     s8, t3, x0
        csrw    mip, x0
        mret

# =========================================================================
# Supervisor-mode handler.
#
# Steps over the offending instruction and returns with SRET, staying in
# whatever mode the trap came from. It cannot bring the test back to M-mode -
# that needs MRET, which is illegal here, and proving that is check 12.
#
# It also cannot read mcause: that is an M-mode register and this runs in S.
# Which is the reason the "a delegated trap leaves the machine registers alone"
# property is checked by a structural invariant in the testbench instead of
# here - see tb_rv32i.v.
# =========================================================================
        .align  2
s_handler:
        addi    s11, s11, 1
        csrr    s10, scause
        blt     s10, x0, s_irq_h

        csrr    t3, sepc
        addi    t3, t3, 4
        csrw    sepc, t3
        sret

s_irq_h:
        # A supervisor software interrupt is a plain latch, cleared at the
        # source - which from S-mode means writing sip.
        csrw    sip, x0
        sret
