/*
 * 21_amo_perm - AMOs and SC.W are writes to the MMU.
 *
 * An AMO reads and writes memory, so the privileged spec checks it as a store:
 * the page must be writable, and a page whose D bit is clear faults so that
 * software can set it (A and D are managed by software on this core). Both
 * failures are a store/AMO page fault, cause 15. SC.W is the same. LR.W is
 * only a load.
 *
 * The data MMU used to be asked about the store bit alone, so every AMO was
 * checked as a load: it could modify a read-only page, did not need D, and a
 * real fault came out as cause 13. Nothing in a single-hart system notices -
 * until copy-on-write, which relies on exactly that write fault to give a
 * process its own copy of a shared page. A lock word in a page still shared
 * after fork() would be changed in the parent as well.
 *
 * Method: a two-level Sv32 table identity-maps the boot RAM as 4 KiB user
 * pages, with three pages set apart - read-only, writable with D clear, and
 * writable with D set. U-mode runs one access per case; the M-mode handler
 * records the cause and steps over the faulting instruction.
 *
 * Needs one unified memory that both the walker and the fetch path see: the
 * SoC's bus, or fast_sim's single memory model.
 *
 * Reserved: s1 last mtval, s7 come-home address, s8 last mcause (-1 = no
 *           trap), s9 trap count.
 * Page bases: s0 read-only, s2 D clear, s4 writable.
 */

#include "test_macros.h"

#define MSTATUS_MPP     (3 << 11)
#define SATP_SV32       (1 << 31)

/* PTE flag bits */
#define PTE_V   0x01
#define PTE_R   0x02
#define PTE_W   0x04
#define PTE_X   0x08
#define PTE_U   0x10
#define PTE_A   0x40
#define PTE_D   0x80

#define PTE_NEXT    PTE_V                                       /* pointer to the next level */
#define PTE_URWX    (PTE_V | PTE_R | PTE_W | PTE_X | PTE_U | PTE_A | PTE_D)
#define PTE_URO     (PTE_V | PTE_R | PTE_U | PTE_A | PTE_D)
#define PTE_URW_ND  (PTE_V | PTE_R | PTE_W | PTE_U | PTE_A)     /* D clear */
#define PTE_URW     (PTE_V | PTE_R | PTE_W | PTE_U | PTE_A | PTE_D)

#define RO_INIT     0x11111111
#define ND_INIT     0x22222222
#define SENTINEL    0x0BADF00D

        TEST_ENTRY

        la      t0, m_handler
        csrw    mtvec, t0
        csrw    medeleg, x0             # everything to M-mode, one handler
        li      s9, 0

        la      s0, page_ro
        la      s2, page_nd
        la      s4, page_rw

        # Initial contents, written untranslated from M-mode.
        li      t0, RO_INIT
        sw      t0, 0(s0)
        li      t0, ND_INIT
        sw      t0, 0(s2)
        li      t0, 100
        sw      t0, 0(s4)

        # ===============================================================
        # 1. Page tables. The leaf table identity-maps the eight 4 KiB pages
        #    of boot RAM as user RWX, then three entries are overridden.
        # ===============================================================
        la      s5, leaf_table
        li      t1, 0                   # page index = PPN, identity map
        li      t3, 8
1:      slli    t2, t1, 10
        ori     t2, t2, PTE_URWX
        slli    t4, t1, 2
        add     t4, t4, s5
        sw      t2, 0(t4)
        addi    t1, t1, 1
        bne     t1, t3, 1b

        # leaf[page >> 12] = (page >> 12) << 10 | flags
        .macro SET_LEAF base, flags
        srli    t1, \base, 12
        slli    t2, t1, 10
        ori     t2, t2, \flags
        slli    t1, t1, 2
        add     t1, t1, s5
        sw      t2, 0(t1)
        .endm

        SET_LEAF s0, PTE_URO
        SET_LEAF s2, PTE_URW_ND
        SET_LEAF s4, PTE_URW

        # root[0] -> leaf table; VA 0..4 MiB is described by the leaf.
        la      s6, root_table
        srli    t1, s5, 12
        slli    t1, t1, 10
        ori     t1, t1, PTE_NEXT
        sw      t1, 0(s6)

        srli    t0, s6, 12
        li      t1, SATP_SV32
        or      t0, t0, t1
        csrw    satp, t0                # translation on, both TLBs flushed

        # ===============================================================
        # 2. Drop to U-mode and make one access per case.
        # ===============================================================
        la      s7, back
        la      t0, u_code
        csrw    mepc, t0
        li      t0, MSTATUS_MPP
        csrc    mstatus, t0             # MPP = 00 = U
        mret

u_code:
        li      t1, 5
        li      t2, 0x5A5A5A5A

        # (a) AMOs to a read-only page: store/AMO page fault, and rd untouched.
        li      s8, -1
        li      s3, SENTINEL
        amoadd.w s3, t1, (s0)
        mv      a1, s8

        li      s8, -1
        li      s5, SENTINEL
        amoswap.w s5, t2, (s0)
        mv      a2, s8

        # (b) An AMO to a writable page with D clear faults the same way.
        li      s8, -1
        amoadd.w s6, t1, (s2)
        mv      a3, s8

        # (c) A writable, dirty page: the AMO completes.
        li      s8, -1
        amoadd.w s10, t1, (s4)          # old 100, memory 105
        mv      a4, s8
        li      s8, -1
        amoswap.w s11, t2, (s4)         # old 105, memory 0x5A5A5A5A
        mv      a5, s8

        # (d) LR.W is a load, so the read-only page is fine; SC.W is a store.
        li      s8, -1
        lr.w    a6, (s0)
        mv      a7, s8
        li      s8, -1
        sc.w    t3, t1, (s0)            # reservation is valid; still faults
        mv      t4, s8

        ecall                           # cause 8: back to M-mode to check

back:
        # (a)
        CHECK   a1, 15, 1               # amoadd.w to read-only: cause 15, not 13
        CHECK   a2, 15, 2               # amoswap.w to read-only
        lw      t0, 0(s0)
        CHECK   t0, RO_INIT, 3          # and the page was not modified
        CHECK   s3, SENTINEL, 4         # a faulting AMO does not write rd
        CHECK   s5, SENTINEL, 5

        # (b)
        CHECK   a3, 15, 6               # D clear: cause 15
        lw      t0, 0(s2)
        CHECK   t0, ND_INIT, 7

        # (c)
        CHECK   a4, -1, 8               # no trap
        CHECK   s10, 100, 9             # amoadd.w returns the old value
        CHECK   a5, -1, 10
        CHECK   s11, 105, 11            # and amoswap.w saw the sum
        lw      t0, 0(s4)
        CHECK   t0, 0x5A5A5A5A, 12

        # (d)
        CHECK   a7, -1, 13              # lr.w on a read-only page: no trap
        CHECK   a6, RO_INIT, 14
        CHECK   t4, 15, 15              # sc.w there: cause 15
        lw      t0, 0(s0)
        CHECK   t0, RO_INIT, 16
        CHECK_REG s1, s0, 17            # mtval = the faulting address

        # Four faults and the ecall. More means a fault failed to step over.
        CHECK   s9, 5, 18

        TEST_END

# -----------------------------------------------------------------------------
# M-mode handler. Page faults record the cause and the address and step over
# the instruction, returning to U-mode. The ecall comes home to M-mode.
# Anything else also comes home, and the CHECKs report it.
# -----------------------------------------------------------------------------
m_handler:
        addi    s9, s9, 1
        csrr    s8, mcause
        li      t0, 8
        beq     s8, t0, h_home
        li      t0, 13
        beq     s8, t0, h_step
        li      t0, 15
        beq     s8, t0, h_step
h_home:
        csrw    mepc, s7
        li      t0, MSTATUS_MPP
        csrs    mstatus, t0             # MPP = 11: mret lands in M-mode
        mret
h_step:
        csrr    s1, mtval
        csrr    t0, mepc
        addi    t0, t0, 4
        csrw    mepc, t0
        mret

# =========================================================================
        .section .data
        .balign 4096
root_table:
        .space  4096
leaf_table:
        .space  4096
page_ro:
        .space  4096
page_nd:
        .space  4096
page_rw:
        .space  4096
