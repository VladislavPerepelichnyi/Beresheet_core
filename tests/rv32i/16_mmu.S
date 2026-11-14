/*
 * 16_mmu - Sv32 translation, end to end.
 *
 * The MMU has a unit testbench that checks every permission rule directly.
 * What that cannot check is the *integration*: that the translated address is
 * the one the memory stage actually uses, that a page fault reaches the trap
 * logic as a precise trap on the right instruction, that a fetch which cannot
 * be translated becomes a trap rather than an executed nothing, and that
 * writing satp invalidates what the TLB cached under the old root.
 *
 * Method: identity-map the low 4 MiB with a megapage so code, stack and page
 * tables all keep working, then add a second mapping of the *same* physical
 * memory at a different virtual address. If translation is real, the two
 * addresses are the same memory. If the physical address is being ignored
 * somewhere in the pipeline, they are not.
 *
 * SoC only: it needs one unified memory that both the walker and the fetch
 * path can see.
 *
 * Reserved: s7 come-home address, s8 last mcause, s9 trap count
 */

#include "test_macros.h"

#define MSTATUS_MPP     (3 << 11)
#define MSTATUS_MPP_S   (1 << 11)
#define MSTATUS_SUM     (1 << 18)

#define SATP_SV32       (1 << 31)

/* V | R | W | X | A | D - a supervisor page, read-write-execute */
#define PTE_SRWX        0xCF
/* the same, plus U */
#define PTE_URWX        0xDF

/* Virtual bases. vpn1 is bits 31:22, so each step is 4 MiB. */
#define VA_ALIAS        0x00800000      /* vpn1 = 2, mapped to physical 0     */
#define VA_USER         0x01000000      /* vpn1 = 4, mapped to 0 but U=1      */
#define VA_UNMAPPED     0x00C00000      /* vpn1 = 3, deliberately absent      */

        TEST_ENTRY

        la      t0, m_handler
        csrw    mtvec, t0
        csrw    medeleg, x0             # everything to M-mode
        csrw    mideleg, x0
        li      s9, 0
        li      s8, 0

        # ===============================================================
        # 1. Build the root page table.
        #
        # Zero it first: every entry that is not written must be invalid,
        # because the unmapped-address checks below depend on it.
        # ===============================================================
        la      s1, root_table
        li      t1, 1024                # 1024 entries
        add     t2, s1, x0
1:      sw      x0, 0(t2)
        addi    t2, t2, 4
        addi    t1, t1, -1
        bnez    t1, 1b

        # root[0]: identity, 0 .. 4 MiB. PPN = 0, so PA = VA for this range,
        # which keeps the code, the stack and this table itself addressable
        # once translation is on.
        li      t1, PTE_SRWX
        sw      t1, 0(s1)

        # root[2]: the same physical 4 MiB, seen at VA_ALIAS. Identical PTE -
        # a megapage's PPN supplies only the top ten bits, so the low ten come
        # from the virtual address either way.
        li      t1, PTE_SRWX
        sw      t1, 8(s1)

        # root[4]: same again, but a *user* page. S-mode must not reach it
        # unless SUM says so.
        li      t1, PTE_URWX
        sw      t1, 16(s1)

        # ===============================================================
        # 2. Turn translation on and drop to S-mode.
        # ===============================================================
        srli    t0, s1, 12              # root PPN
        li      t1, SATP_SV32
        or      t0, t0, t1
        csrw    satp, t0                # also flushes both TLBs

        la      s7, back_1
        la      t0, s_code_1
        csrw    mepc, t0
        li      t0, MSTATUS_MPP
        csrc    mstatus, t0
        li      t0, MSTATUS_MPP_S
        csrs    mstatus, t0             # MPP = 01 = S
        mret

s_code_1:
        # Running translated now. Reaching this line at all means instruction
        # translation works: every fetch from here went through the ITLB.
        li      s2, 0x600D600D

        # The alias must be the same memory as the identity mapping.
        la      t0, scratch
        li      t1, 0xC0FFEE00
        sw      t1, 0(t0)               # store through the identity mapping
        li      t2, VA_ALIAS
        add     t2, t2, t0              # the same word, other address
        lw      t3, 0(t2)
        li      t4, 0xC0FFEE00
        bne     t3, t4, fail_in_s

        # And the other way round: a store through the alias must be visible
        # at the identity address. If the physical address were being dropped
        # anywhere, these would be two different words.
        li      t1, 0x5A5A1234
        sw      t1, 0(t2)
        lw      t3, 0(t0)
        li      t4, 0x5A5A1234
        bne     t3, t4, fail_in_s

        li      s3, 1                   # got here with everything matching
        ebreak                          # come home

fail_in_s:
        li      s3, 0
        ebreak

back_1:
        CHECK   s2, 0x600D600D, 1       # S-mode code ran, translated
        CHECK   s3, 1, 2                # the alias is the same memory
        CHECK   s9, 1, 3                # exactly one trap so far

        # ===============================================================
        # 3. A load from an unmapped page: cause 13, precisely.
        # ===============================================================
        la      s7, back_2
        la      t0, s_code_2
        csrw    mepc, t0
        li      t0, MSTATUS_MPP
        csrc    mstatus, t0
        li      t0, MSTATUS_MPP_S
        csrs    mstatus, t0
        mret
s_code_2:
        li      t2, VA_UNMAPPED
        lw      t3, 0(t2)               # load page fault
        ebreak                          # not reached: the handler comes home
back_2:
        CHECK   s8, 13, 4               # load page fault

        # A store to the same place must report 15, not 13.
        la      s7, back_3
        la      t0, s_code_3
        csrw    mepc, t0
        li      t0, MSTATUS_MPP
        csrc    mstatus, t0
        li      t0, MSTATUS_MPP_S
        csrs    mstatus, t0
        mret
s_code_3:
        li      t2, VA_UNMAPPED
        sw      x0, 0(t2)               # store page fault
        ebreak
back_3:
        CHECK   s8, 15, 5               # store page fault

        # ===============================================================
        # 4. A fetch from an unmapped page: cause 12, and mepc is the
        #    address that could not be fetched.
        #
        #    This is the one that needs the poisoned IF/ID slot: the
        #    instruction never existed, so the trap has to be raised on
        #    behalf of an instruction that was never decoded.
        # ===============================================================
        la      s7, back_4
        la      t0, s_code_4
        csrw    mepc, t0
        li      t0, MSTATUS_MPP
        csrc    mstatus, t0
        li      t0, MSTATUS_MPP_S
        csrs    mstatus, t0
        mret
s_code_4:
        li      t2, VA_UNMAPPED
        jalr    x0, 0(t2)               # fetch page fault at VA_UNMAPPED
        ebreak
back_4:
        CHECK   s8, 12, 6               # instruction page fault
        li      t4, VA_UNMAPPED
        CHECK_REG s10, t4, 7            # mepc was the faulting address
        CHECK_REG s11, t4, 8            # and so was mtval

        # ===============================================================
        # 5. SUM. A user page is out of reach from S-mode until SUM is set.
        # ===============================================================
        la      s7, back_5
        la      t0, s_code_5
        csrw    mepc, t0
        li      t0, MSTATUS_MPP
        csrc    mstatus, t0
        li      t0, MSTATUS_MPP_S
        csrs    mstatus, t0
        li      t0, MSTATUS_SUM
        csrc    mstatus, t0             # SUM off
        mret
s_code_5:
        la      t0, scratch
        li      t2, VA_USER
        add     t2, t2, t0
        lw      t3, 0(t2)               # blocked: U=1 and SUM=0
        ebreak
back_5:
        CHECK   s8, 13, 9               # load page fault on a user page

        la      s7, back_6
        la      t0, s_code_6
        csrw    mepc, t0
        li      t0, MSTATUS_MPP
        csrc    mstatus, t0
        li      t0, MSTATUS_MPP_S
        csrs    mstatus, t0
        li      t0, MSTATUS_SUM
        csrs    mstatus, t0             # SUM on
        mret
s_code_6:
        la      t0, scratch
        li      t1, 0x11223344
        sw      t1, 0(t0)
        li      t2, VA_USER
        add     t2, t2, t0
        lw      t3, 0(t2)               # now permitted
        li      t4, 0x11223344
        bne     t3, t4, 2f
        li      s4, 1
        ebreak
2:      li      s4, 0
        ebreak
back_6:
        CHECK   s4, 1, 10               # SUM let the access through

        # ===============================================================
        # 5b. Atomics under translation.
        #
        #     Every atomic test until now ran with satp = 0, so the reservation
        #     and the AMO sequencer have only ever been exercised on untranslated
        #     addresses. Linux's printk ring buffer is built on cmpxchg loops, so
        #     an SC that always fails under translation is an infinite loop in
        #     the first thing the kernel does after printing its banner.
        #
        #     The address used is the *alias*, so the physical address the
        #     reservation is taken on is not the virtual one the instruction
        #     names.
        # ===============================================================
        la      s7, back_atomic
        la      t0, s_code_atomic
        csrw    mepc, t0
        li      t0, MSTATUS_MPP
        csrc    mstatus, t0
        li      t0, MSTATUS_MPP_S
        csrs    mstatus, t0
        mret
s_code_atomic:
        la      t0, scratch
        li      t2, VA_ALIAS
        add     t2, t2, t0              # the same word, other address
        li      t1, 0x1000
        sw      t1, 0(t2)

        # LR/SC must succeed when nothing intervenes.
        lr.w    t3, (t2)
        li      t4, 0x2000
        sc.w    t5, t4, (t2)
        bnez    t5, atomic_bad          # non-zero means the store failed
        lw      t3, 0(t2)
        li      t4, 0x2000
        bne     t3, t4, atomic_bad

        # And an AMO, which is a read-modify-write through the same path.
        li      t4, 0x11
        amoadd.w t3, t4, (t2)
        lw      t3, 0(t2)
        li      t4, 0x2011
        bne     t3, t4, atomic_bad

        # The value must be visible at the identity address too - the atomic
        # acted on physical memory, not on a virtual alias of it.
        la      t0, scratch
        lw      t3, 0(t0)
        li      t4, 0x2011
        bne     t3, t4, atomic_bad

        li      s5, 1
        ebreak
atomic_bad:
        li      s5, 0
        ebreak
back_atomic:
        CHECK   s5, 1, 13               # atomics work under translation

        # ===============================================================
        # 6. SFENCE.VMA. Change a live mapping and prove the TLB followed.
        #
        #    The alias is resident by now, so without an invalidate the old
        #    translation would keep being used - which is correct until the
        #    fence, and wrong after it.
        # ===============================================================
        li      t1, 0                   # invalidate root[2]
        sw      t1, 8(s1)
        sfence.vma

        la      s7, back_7
        la      t0, s_code_7
        csrw    mepc, t0
        li      t0, MSTATUS_MPP
        csrc    mstatus, t0
        li      t0, MSTATUS_MPP_S
        csrs    mstatus, t0
        mret
s_code_7:
        la      t0, scratch
        li      t2, VA_ALIAS
        add     t2, t2, t0
        lw      t3, 0(t2)               # the alias is gone now
        ebreak
back_7:
        CHECK   s8, 13, 11              # the mapping really was dropped

        # ===============================================================
        # 7. Turn translation off again. M-mode never translated anyway,
        #    but satp must go back to bare or nothing after this test
        #    would be addressable the way the harness expects.
        # ===============================================================
        csrw    satp, x0
        csrr    t0, satp
        CHECK   t0, 0, 12               # satp is real state, and now zero

        TEST_END

# =========================================================================
# Machine-mode handler.
#
# A page fault cannot be stepped over - the next instruction is in the same
# unmapped page - so anything that faults comes straight home. EBREAK is the
# deliberate come-home marker, as in 13_privilege.
# =========================================================================
        .align  2
m_handler:
        addi    s9, s9, 1
        csrr    t3, mcause
        blt     t3, x0, m_irq

        add     s8, t3, x0
        csrr    s10, mepc
        csrr    s11, mtval

        li      t4, 3                   # ebreak: come home
        beq     t3, t4, m_come_home
        li      t4, 12
        beq     t3, t4, m_come_home
        li      t4, 13
        beq     t3, t4, m_come_home
        li      t4, 15
        beq     t3, t4, m_come_home

        csrr    t3, mepc                # anything else: step over it
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
        .section .data
        .balign 4096
root_table:
        .space  4096
        .balign 4
scratch:
        .word   0
