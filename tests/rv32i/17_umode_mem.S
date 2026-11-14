/*
 * 17_umode_mem - misaligned accesses and atomics from U-mode, translated.
 *
 * This test exists because of a bring-up failure that took a dozen boot cycles
 * to corner. Linux boots, OpenSBI boots, and hand-written assembly runs in user
 * mode correctly - stack growth, brk, a fresh heap page, fork with COW, and a
 * store to address zero that faults with cause 0x0f and delivers SIGSEGV
 * exactly as it should. But every binary linked against a C library, glibc and
 * musl alike, hangs before printing a single character.
 *
 * Disassembling the probe that worked against the busybox that did not shows
 * what the working program never executed:
 *
 *     atomics (lr.w / sc.w / amo*)   probe: 0    busybox: 56
 *     misaligned word accesses       probe: 0    every memcpy and strlen
 *
 * and the kernel's own boot log reports
 *
 *     Ratio of byte access time to unaligned word access is 0.00,
 *     unaligned accesses are slow
 *
 * A ratio of 0.00 means the unaligned copy was immeasurably slower than the
 * byte copy: every one of those accesses takes a trap. That path demonstrably
 * works from M-mode, because 12_atomics passes and the kernel's own benchmark
 * completed. What has never been tested anywhere is either class from *U-mode
 * with translation on*, which is the only mode a libc ever runs in.
 *
 * The failure mode being hunted is specifically a trap that does not make
 * forward progress: if a misaligned access from U-mode traps, and after the
 * handler returns the same instruction faults again, the process spins
 * forever, silently, printing nothing and never dying. That is indistinguishable
 * from a hung core over a serial console, and it is exactly what a libc looks
 * like when it starts up.
 *
 * Method: identity-map the low 4 MiB as a user page, drop to U-mode, and run
 * each class with the trap handler counting and returning to a known label.
 * Every loop is bounded, because a test that hangs teaches nothing.
 *
 * SoC only: needs one unified memory the walker and the fetch path both see.
 *
 * Reserved: s7 come-home address, s8 last mcause, s9 trap count
 */

#include "test_macros.h"

#define MSTATUS_MPP     (3 << 11)       /* both bits, to clear the field    */
#define MSTATUS_MPP_U   (0 << 11)       /* U-mode is 00                     */

#define SATP_SV32       (1 << 31)

/* V | R | W | X | A | D | U - a user page, read-write-execute */
#define PTE_URWX        0xDF

        TEST_ENTRY

        la      t0, m_handler
        csrw    mtvec, t0
        csrw    medeleg, x0             # everything to M-mode, so one handler

        li      s9, 0                   # trap count
        li      s8, 0                   # last mcause
        li      s10, 0                  # first trap cause
        li      s11, 0                  # first trap mtval

        # ===============================================================
        # 1. A root page table at 4 MiB, identity-mapping the low 4 MiB
        #    as a USER page so U-mode can fetch, load and store in it.
        # ===============================================================
        # The root table and the scratch word are placed by the linker, not at
        # hardcoded addresses. This RAM is ORIGIN 0x0 LENGTH 32K (soc.ld), so
        # 0x00400000 does not exist - stores there go nowhere, satp then points
        # at garbage, and the first translated fetch returns a word that decodes
        # as an illegal instruction. That is what the first version of this test
        # did, and it looked exactly like a core bug.
        la      s1, root_table          # 4 KiB aligned, in .data
        li      t1, 1024
        mv      t2, s1
1:      sw      x0, 0(t2)
        addi    t2, t2, 4
        addi    t1, t1, -1
        bnez    t1, 1b

        li      t1, PTE_URWX
        sw      t1, 0(s1)               # root[0]: VA 0..4 MiB -> PA 0..4 MiB

        srli    t0, s1, 12
        li      t1, SATP_SV32
        or      t0, t0, t1
        csrw    satp, t0                # translation on, both TLBs flushed

        # A scratch word, naturally aligned, inside the identity-mapped range.
        la      s2, scratch
        li      t0, 0x12345678
        sw      t0, 0(s2)
        sw      x0, 4(s2)

        # ===============================================================
        # 2. Drop to U-mode and run the untested classes.
        # ===============================================================
        la      s7, back_1
        la      t0, u_code
        csrw    mepc, t0
        li      t0, MSTATUS_MPP
        csrc    mstatus, t0             # MPP = 00 = U
        mret

u_code:
        # Reaching here means a U-mode fetch was translated at all.
        li      s3, 0x0DE1DE1

        # ---- misaligned LOAD from U-mode ------------------------------
        # If this traps, the handler must advance past it or resume it in a way
        # that makes progress. Either is fine; spinning is not. The bounded
        # counter below is what distinguishes them: it is decremented once per
        # arrival, so a non-progressing trap exhausts it instead of hanging.
        addi    t1, s2, 1               # deliberately odd
        lw      s4, 0(t1)

        # ---- misaligned STORE from U-mode -----------------------------
        li      t3, 0x0000AA55
        sw      t3, 0(t1)
        lw      s5, 0(t1)               # read it back through the same path

        # ---- amoadd.w from U-mode -------------------------------------
        li      t0, 100
        sw      t0, 0(s2)
        li      t1, 5
        amoadd.w s6, t1, (s2)           # s6 = old value, memory = 105

        # ---- lr.w / sc.w from U-mode, bounded -------------------------
        li      t4, 64                  # retry budget
        li      t5, 0                   # 0 = never succeeded
2:      lr.w    t0, (s2)
        addi    t0, t0, 1
        sc.w    t6, t0, (s2)
        beqz    t6, 3f
        addi    t4, t4, -1
        bnez    t4, 2b
        j       4f
3:      li      t5, 1                   # sc.w succeeded
4:
        # ---- integer division from U-mode -----------------------------
        # The reason this test grew a division section: a 545 KiB static glibc
        # binary printed one line and hung on the next, and the next line was
        # the first one that formatted a number. say_num() compiles to divu and
        # remu, and every assembly probe that ran correctly contained zero
        # div/rem/mul instructions. 06_muldiv covers them in M-mode; from
        # U-mode with translation on they had never been executed.
        li      t0, 100
        li      t1, 7
        divu    s4, t0, t1              # 14
        remu    s5, t0, t1              # 2

        # Signed, with a negative dividend: different sign-handling path.
        li      t0, -100
        li      t1, 7
        div     t2, t0, t1              # -14, truncating toward zero
        rem     t3, t0, t1              # -2, sign follows the dividend
        la      t4, scratch
        sw      t2, 8(t4)
        sw      t3, 12(t4)

        # Division by zero: the spec says no trap. divu gives all ones, remu
        # gives the dividend. A core that traps or hangs here hangs every libc,
        # because a printf guard can divide by a zero it has not checked yet.
        li      t0, 1234
        li      t1, 0
        divu    a4, t0, t1              # 0xFFFFFFFF
        remu    a5, t0, t1              # 1234
        sw      a4, 16(t4)
        sw      a5, 20(t4)

        # A division immediately followed by a translated load, so the divider's
        # multi-cycle stall overlaps a possible TLB walk. This is the ordering
        # most likely to expose a stall-handshake bug, and it is exactly what
        # compiled code does.
        li      t0, 999
        li      t1, 3
        divu    t2, t0, t1
        lw      t3, 0(t4)
        sw      t2, 24(t4)

        # ---- dividend SMALLER than the divisor -------------------------
        # say_num(3) computes 3/10 and 3%10 - a quotient of zero. Every case
        # tested above has a dividend larger than its divisor, and a restoring
        # divider that decides how many iterations to run from the operands can
        # get the trivial case wrong or fail to terminate at all. This is the
        # exact arithmetic the hardware hung on.
        li      t0, 3
        li      t1, 10
        divu    a4, t0, t1              # 0
        remu    a5, t0, t1              # 3
        sw      a4, 28(t4)
        sw      a5, 32(t4)

        # Zero dividend, for the same reason from the other side.
        li      t0, 0
        li      t1, 10
        divu    a4, t0, t1              # 0
        remu    a5, t0, t1              # 0
        sw      a4, 36(t4)
        sw      a5, 40(t4)

        # Back to M-mode to report. ecall from U is cause 8.
        ecall

back_1:
        CHECK   s3, 0x0DE1DE1, 1        # U-mode code ran, translated

        # The misaligned load read bytes 1..4 of 0x12345678 with byte 4 zero,
        # so little-endian gives 0x00123456. This is checked rather than merely
        # "did not hang" because a trap-and-emulate that returns the wrong
        # value corrupts every memcpy in userspace instead of hanging.
        # cause 4 = load address misaligned. This is the number the kernel's
        # emulator switches on.
        CHECK   s10, 4, 2

        # mtval must hold the misaligned address itself, scratch+1. Without it
        # the emulator does not know which bytes to move.
        la      t0, scratch
        addi    t0, t0, 1
        CHECK_REG s11, t0, 3

        # amoadd.w returns the OLD value.
        # Three misaligned accesses were skipped, then one ecall: four traps.
        # A count higher than this means a trap re-fired without progress,
        # which is the infinite loop a libc would hit.
        CHECK   s9, 4, 4

        # amoadd.w returned the old value, from U-mode, translated.
        CHECK   s6, 100, 5

        # ---- the division results -------------------------------------
        CHECK   s4, 14, 7               # divu 100/7
        CHECK   s5, 2, 8                # remu 100%7
        la      t0, scratch
        lw      t1, 8(t0)
        CHECK   t1, -14, 9              # div -100/7, truncating toward zero
        lw      t1, 12(t0)
        CHECK   t1, -2, 10              # rem -100%7, sign of the dividend
        lw      t1, 16(t0)
        CHECK   t1, -1, 11              # divu by zero = all ones, no trap
        lw      t1, 20(t0)
        CHECK   t1, 1234, 12            # remu by zero = the dividend
        lw      t1, 24(t0)
        CHECK   t1, 333, 13             # divu next to a translated load
        lw      t1, 28(t0)
        CHECK   t1, 0, 14               # 3/10  - quotient zero
        lw      t1, 32(t0)
        CHECK   t1, 3, 15               # 3%10  - remainder is the dividend
        lw      t1, 36(t0)
        CHECK   t1, 0, 16               # 0/10
        lw      t1, 40(t0)
        CHECK   t1, 0, 17               # 0%10

        # sc.w must succeed within the budget. Zero here is the smoking gun for
        # a libc that spins forever in a lock.
        CHECK   t5, 1, 6

        # TEST_END is the pass path: it clears mtvec, sets a0 = 0 and ebreaks.
        # It also defines test_fail, which every CHECK above branches to.
        TEST_END

# -----------------------------------------------------------------------------
# One M-mode handler for everything. It counts, records the cause, and for a
# misaligned access advances mepc past the faulting instruction so the test can
# continue - which is what tells us the trap was precise and reported the right
# instruction. For ecall it returns to the come-home address in s7.
# -----------------------------------------------------------------------------
m_handler:
        addi    s9, s9, 1
        csrr    s8, mcause
        # First trap only: preserve the cause and the faulting address. The
        # kernel's misaligned emulator reads exactly these two, so if either is
        # wrong it cannot fix up the access and userspace cannot make progress.
        bnez    s10, 20f
        mv      s10, s8
        csrr    s11, mtval
20:

        li      t0, 8                   # ecall from U-mode
        beq     s8, t0, h_ecall

        li      t0, 11                  # ecall from M-mode, if it ever happens
        beq     s8, t0, h_ecall

        # Misaligned load (4) or store (6): step over the instruction. All the
        # instructions used here are 4 bytes; this core has no C extension.
        li      t0, 4
        beq     s8, t0, h_step
        li      t0, 6
        beq     s8, t0, h_step

        # Anything else is a real failure, and the cause is worth reporting
        # rather than looping. Come home and let the CHECKs describe it.
        j       h_ecall

h_step:
        csrr    t0, mepc
        addi    t0, t0, 4
        csrw    mepc, t0
        mret

h_ecall:
        csrw    mepc, s7
        # MPP = 11 so mret lands back in M-mode, not U-mode: the CHECKs read
        # CSRs and must run privileged.
        li      t0, MSTATUS_MPP
        csrs    mstatus, t0
        mret

# =========================================================================
        .section .data
        .balign 4096
root_table:
        .space  4096
        .balign 4
scratch:
        .space  64
