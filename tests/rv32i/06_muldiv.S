/*
 * 06_muldiv - the RV32M extension.
 *
 * Encodings and semantics follow the Unprivileged ISA manual: the funct3 table
 * on page 587, and Table 11 in section 12 for the division special cases.
 *
 * Beyond plain arithmetic this test leans on the fact that every M instruction
 * stalls the pipeline for several cycles, which makes it the natural place to
 * check that the freeze does not corrupt anything around it:
 *   * back-to-back M instructions, so the unit must return to idle cleanly;
 *   * an M result consumed by the very next instruction, which has to arrive
 *     through the register-file bypass on the cycle the stall releases;
 *   * an M result feeding a branch condition and a load address;
 *   * a store immediately before an M instruction, to prove the bubble pushed
 *     into Mem/Writeback does not replay it.
 */

#include "test_macros.h"

TEST_ENTRY

        la      s0, scratch

        # ===============================================================
        # MUL - low 32 bits. Signedness is irrelevant here.
        # ===============================================================
        li      t0, 6
        li      t1, 7
        mul     t2, t0, t1
        CHECK   t2, 42, 1

        li      t0, -6
        li      t1, 7
        mul     t2, t0, t1
        CHECK   t2, -42, 2

        li      t0, -6
        li      t1, -7
        mul     t2, t0, t1
        CHECK   t2, 42, 3

        # low 32 bits wrap, no trap
        li      t0, 0x10000
        li      t1, 0x10000
        mul     t2, t0, t1              # 2**32 -> 0
        CHECK   t2, 0, 4

        li      t0, 0x7FFFFFFF
        li      t1, 2
        mul     t2, t0, t1              # 0xFFFFFFFE
        CHECK   t2, 0xFFFFFFFE, 5

        # multiply by zero and by one
        li      t0, 0x12345678
        mul     t2, t0, x0
        CHECK   t2, 0, 6
        li      t1, 1
        mul     t2, t0, t1
        CHECK   t2, 0x12345678, 7

        # ===============================================================
        # MULH / MULHU / MULHSU - upper 32 bits of the 64-bit product
        # ===============================================================
        # 0x10000 * 0x10000 = 2**32 -> high word 1
        li      t0, 0x10000
        li      t1, 0x10000
        mulh    t2, t0, t1
        CHECK   t2, 1, 8
        mulhu   t2, t0, t1
        CHECK   t2, 1, 9

        # -1 * -1 = 1 : high word 0 signed, but 0xFFFFFFFE unsigned
        li      t0, -1
        li      t1, -1
        mulh    t2, t0, t1
        CHECK   t2, 0, 10
        mulhu   t2, t0, t1              # 0xFFFFFFFF^2 = 0xFFFFFFFE00000001
        CHECK   t2, 0xFFFFFFFE, 11

        # -1 * 1 = -1 : high word is the sign extension
        li      t0, -1
        li      t1, 1
        mulh    t2, t0, t1
        CHECK   t2, -1, 12
        mulhu   t2, t0, t1              # 0xFFFFFFFF * 1, high word 0
        CHECK   t2, 0, 13

        # MULHSU: rs1 signed, rs2 unsigned. -1 * 0xFFFFFFFF = -4294967295,
        # which is 0xFFFFFFFF_00000001 -> high word 0xFFFFFFFF.
        li      t0, -1
        li      t1, -1                  # read as 0xFFFFFFFF
        mulhsu  t2, t0, t1
        CHECK   t2, 0xFFFFFFFF, 14

        # and the same operands through the other two variants, to prove the
        # three are actually distinct
        mulh    t3, t0, t1              # signed * signed = 1 -> high 0
        CHECK   t3, 0, 15
        mulhu   t4, t0, t1
        CHECK   t4, 0xFFFFFFFE, 16

        # most-negative times itself: 2**62 -> high word 0x40000000
        li      t0, 0x80000000
        mulh    t2, t0, t0
        CHECK   t2, 0x40000000, 17
        mulhu   t2, t0, t0              # 2**31 * 2**31 = 2**62, same high word
        CHECK   t2, 0x40000000, 18

        # 0x80000000 signed is -2**31; times 0x80000000 unsigned = -2**62
        mulhsu  t2, t0, t0              # 0xC0000000_00000000 -> high 0xC0000000
        CHECK   t2, 0xC0000000, 19

        # ===============================================================
        # DIV / DIVU - rounding towards zero
        # ===============================================================
        li      t0, 100
        li      t1, 7
        div     t2, t0, t1
        CHECK   t2, 14, 20              # 100/7 = 14.28 -> 14
        divu    t2, t0, t1
        CHECK   t2, 14, 21

        li      t0, -100
        li      t1, 7
        div     t2, t0, t1
        CHECK   t2, -14, 22             # towards zero, not towards -inf

        li      t0, 100
        li      t1, -7
        div     t2, t0, t1
        CHECK   t2, -14, 23

        li      t0, -100
        li      t1, -7
        div     t2, t0, t1
        CHECK   t2, 14, 24

        # unsigned reads -100 as a huge value
        li      t0, -100
        li      t1, 7
        divu    t2, t0, t1              # 0xFFFFFF9C / 7 = 613566742
        CHECK   t2, 613566742, 25

        # exact division, and division by one
        li      t0, 144
        li      t1, 12
        div     t2, t0, t1
        CHECK   t2, 12, 26
        li      t1, 1
        div     t2, t0, t1
        CHECK   t2, 144, 27

        # divisor larger than dividend
        li      t0, 5
        li      t1, 100
        div     t2, t0, t1
        CHECK   t2, 0, 28

        # ===============================================================
        # REM / REMU - a non-zero remainder takes the sign of the dividend
        # ===============================================================
        li      t0, 100
        li      t1, 7
        rem     t2, t0, t1
        CHECK   t2, 2, 29
        remu    t2, t0, t1
        CHECK   t2, 2, 30

        li      t0, -100
        li      t1, 7
        rem     t2, t0, t1
        CHECK   t2, -2, 31              # sign of the dividend

        li      t0, 100
        li      t1, -7
        rem     t2, t0, t1
        CHECK   t2, 2, 32               # dividend positive, so remainder is too

        li      t0, -100
        li      t1, -7
        rem     t2, t0, t1
        CHECK   t2, -2, 33

        li      t0, -100
        li      t1, 7
        remu    t2, t0, t1              # 0xFFFFFF9C mod 7 = 2
        CHECK   t2, 2, 34

        # exact division leaves no remainder
        li      t0, 144
        li      t1, 12
        rem     t2, t0, t1
        CHECK   t2, 0, 35

        # ===============================================================
        # Table 11: division by zero. Quotient all ones, remainder = dividend.
        # ===============================================================
        li      t0, 42
        div     t2, t0, x0
        CHECK   t2, -1, 36
        divu    t2, t0, x0
        CHECK   t2, 0xFFFFFFFF, 37
        rem     t2, t0, x0
        CHECK   t2, 42, 38
        remu    t2, t0, x0
        CHECK   t2, 42, 39

        # zero divided by zero behaves the same way
        div     t2, x0, x0
        CHECK   t2, -1, 40
        rem     t2, x0, x0
        CHECK   t2, 0, 41

        # negative dividend over zero
        li      t0, -7
        div     t2, t0, x0
        CHECK   t2, -1, 42
        rem     t2, t0, x0
        CHECK   t2, -7, 43

        # ===============================================================
        # Table 11: signed overflow, -2**31 / -1. Quotient is the dividend,
        # remainder is zero. Unsigned overflow cannot happen.
        # ===============================================================
        li      t0, 0x80000000
        li      t1, -1
        div     t2, t0, t1
        CHECK   t2, 0x80000000, 44
        rem     t2, t0, t1
        CHECK   t2, 0, 45

        # the unsigned reading of the same bits is an ordinary division
        divu    t2, t0, t1              # 2**31 / (2**32-1) = 0
        CHECK   t2, 0, 46
        remu    t2, t0, t1              # remainder is the dividend
        CHECK   t2, 0x80000000, 47

        # ===============================================================
        # Pipeline behaviour around the multi-cycle stall
        # ===============================================================
        # back-to-back M instructions, each consuming the previous result
        li      t0, 3
        mul     t1, t0, t0              # 9
        mul     t2, t1, t1              # 81
        mul     t3, t2, t2              # 6561
        div     t4, t3, t0              # 2187
        rem     t5, t3, t0              # 0
        CHECK   t1, 9,    48
        CHECK   t2, 81,   49
        CHECK   t3, 6561, 50
        CHECK   t4, 2187, 51
        CHECK   t5, 0,    52

        # an M result feeding a branch on the very next instruction
        li      t0, 12
        li      t1, 4
        div     t2, t0, t1              # 3
        li      t3, 3
        beq     t2, t3, md_br_ok
        CHECK   x0, 1, 53
md_br_ok:

        # an M result used as an address on the very next instruction
        li      t0, 0x5AA5
        sw      t0, 16(s0)
        li      t1, 4
        li      t2, 4
        mul     t3, t1, t2              # 16
        add     t4, s0, t3              # address, one instruction later
        lw      t5, 0(t4)
        CHECK   t5, 0x5AA5, 54

        # a store immediately before an M instruction: the bubble pushed into
        # Mem/Writeback must not replay it
        li      t0, 1
        sw      t0, 20(s0)              # store 1
        li      t1, 6
        mul     t2, t1, t1              # 36, stalls right after the store
        lw      t3, 20(s0)
        CHECK   t3, 1, 55               # still 1, not stored twice
        CHECK   t2, 36, 56

        # writing to x0 must still be discarded even from the M unit
        li      t0, 99
        mul     x0, t0, t0
        CHECK   x0, 0, 57

        # ===============================================================
        # A real kernel: multiply-accumulate over an array, then a modular
        # reduction. Every iteration has an M instruction inside a loop with a
        # load-use and a data-dependent branch.
        # ===============================================================
        la      a1, values
        li      a2, 0                   # accumulator
        li      a3, 0                   # index
        li      a4, 8                   # count
mac_loop:
        lw      a5, 0(a1)
        mul     a6, a5, a5              # square, stalls
        add     a2, a2, a6              # accumulate the fresh result
        addi    a1, a1, 4
        addi    a3, a3, 1
        blt     a3, a4, mac_loop
        CHECK   a2, 8572, 58            # sum of squares of the table

        # modular reduction of the accumulator
        li      a7, 1000
        rem     t0, a2, a7
        CHECK   t0, 572, 59
        div     t1, a2, a7
        CHECK   t1, 8, 60

        # ===============================================================
        # Iterative factorial using MUL, so the result depends on a chain of
        # stalls that each have to release cleanly.
        # ===============================================================
        li      s1, 1                   # product
        li      s2, 1                   # counter
        li      s3, 10
fact_loop:
        mul     s1, s1, s2
        addi    s2, s2, 1
        bge     s3, s2, fact_loop
        CHECK   s1, 3628800, 61         # 10!

        # and back down again by division
        li      s4, 10
unfact_loop:
        div     s1, s1, s4              # divide by 10, 9, ... 1
        addi    s4, s4, -1
        bne     s4, x0, unfact_loop
        CHECK   s1, 1, 62

TEST_END

# -------------------------------------------------------------------------
        .section .rodata
        .align  2
values:
        .word   12, 30, 7, 45, 21, 60, 33, 18

        .section .bss
        .align  4
scratch:
        .space  128
