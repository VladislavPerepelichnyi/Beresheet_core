/*
 * 20_ifault_phantom_load - a faulted fetch must not issue a data access.
 *
 * Runs on the full SoC and on fast_sim. On the SoC the stale word comes from
 * the instruction cache; fast_sim supplies whatever memory holds at the
 * address on the fetch port.
 *
 * When a fetch page-faults, IF/ID still latches *something* as the
 * instruction: whatever the instruction cache last put on its output, which
 * is usually the word straight after the jump that led there. Those bits are
 * meaningless, but they were decoded anyway - and if they decoded as a load
 * or store, the data MMU was asked to translate them.
 *
 * That is not merely untidy. The fetch-fault trap waits for stage 1's fetch to
 * land (redirect_ok), and that fetch needs an ITLB walk. The phantom access to
 * an unmapped page faulted, re-walked, faulted again, and the data walker has
 * priority on the shared port, so the ITLB walk never ran: nothing retired,
 * ever. Linux hit it on the sret into busybox's first, not-yet-mapped page
 * (the stale word there decoded as `lw a5,48(s1)`).
 *
 * Which word it is follows from the instruction cache being virtually
 * indexed: on a fetch that cannot be translated, the cache still reads its
 * block RAM at the index given by the virtual address's low bits, and that
 * word is what IF/ID latches. busybox's entry 0x100f4 indexed a cached
 * `lw a5,48(s1)`. So the test jumps to an unmapped address whose low ten bits
 * equal those of a load it has just fetched, and that load's own address is
 * unmapped too. A correct core takes the fetch fault (cause 12, mepc = mtval =
 * the target). The old one hung, retiring nothing.
 *
 * Reserved: s7 come-home address, s8 last mcause, s9 trap count,
 *           s10 mepc, s11 mtval
 */

#include "test_macros.h"

#define MSTATUS_MPP     (3 << 11)
#define MSTATUS_MPP_S   (1 << 11)
#define SATP_SV32       (1 << 31)
#define PTE_SRWX        0xCF            /* V R W X A D, supervisor */
#define VA_UNMAPPED     0x00C00000      /* vpn1 = 3, deliberately absent */

        TEST_ENTRY

        la      t0, m_handler
        csrw    mtvec, t0
        csrw    medeleg, x0
        csrw    mideleg, x0
        li      s9, 0
        li      s8, 0

        # Root table: only root[0], an identity megapage over 0 .. 4 MiB.
        la      s1, root_table
        li      t1, 1024
        add     t2, s1, x0
1:      sw      x0, 0(t2)
        addi    t2, t2, 4
        addi    t1, t1, -1
        bnez    t1, 1b
        li      t1, PTE_SRWX
        sw      t1, 0(s1)

        srli    t0, s1, 12
        li      t1, SATP_SV32
        or      t0, t0, t1
        csrw    satp, t0

        la      s7, back_1
        la      t0, s_code_1
        csrw    mepc, t0
        li      t0, MSTATUS_MPP
        csrc    mstatus, t0
        li      t0, MSTATUS_MPP_S
        csrs    mstatus, t0
        mret

        # Translated S-mode. Both the jump target and the phantom load's
        # address are in the unmapped 4 MiB.
        .balign 16
s_code_1:
        li      s1, VA_UNMAPPED         # the phantom load's base: unmapped
        la      t2, phantom
        andi    t2, t2, 0x3FF           # same cache index as `phantom`...
        li      t3, VA_UNMAPPED
        or      t2, t2, t3              # ...in the unmapped 4 MiB
        jalr    x0, 0(t2)               # fetch page fault
phantom:
        lw      a5, 48(s1)              # cached by the fetch above; never runs
        lw      a5, 48(s1)
        ebreak

back_1:
        CHECK   s9, 1, 1                # exactly one trap
        CHECK   s8, 12, 2               # and it was the fetch page fault
        la      t4, phantom
        andi    t4, t4, 0x3FF
        li      t3, VA_UNMAPPED
        or      t4, t4, t3
        CHECK_REG s10, t4, 3            # mepc = the address not fetched
        CHECK_REG s11, t4, 4            # mtval too

        csrw    satp, x0
        TEST_END

        .align  2
m_handler:
        addi    s9, s9, 1
        csrr    s8, mcause
        csrr    s10, mepc
        csrr    s11, mtval
        csrw    mepc, s7                # every trap comes home
        li      t4, MSTATUS_MPP
        csrs    mstatus, t4             # MPP = M
        mret

        .section .data
        .balign 4096
root_table:
        .space  4096
