/*
 * 04_loadstore - every RV32I load and store width, with load-use hazards.
 *
 * Focus areas:
 *   * byte strobes: a SB must leave the other three bytes of the word alone,
 *     which a memory that writes whole words silently breaks;
 *   * sign extension: LB / LH extend, LBU / LHU do not;
 *   * load-use RAW: the loaded value is consumed by the very next instruction,
 *     which in this pipeline has to come back through the register-file bypass;
 *   * store-to-load forwarding through memory: a store followed immediately by
 *     a load of the same address.
 */

#include "test_macros.h"

TEST_ENTRY

        la      s0, scratch             # base pointer for the whole test

        # ---------------------------------------------------------------
        # SW / LW round trip, load-use on the very next instruction
        # ---------------------------------------------------------------
        li      t0, 0x12345678
        sw      t0, 0(s0)
        lw      t1, 0(s0)
        addi    t1, t1, 0               # load-use, distance 1
        CHECK   t1, 0x12345678, 1

        # negative and positive offsets off the same base
        li      t0, 0x0BADF00D
        sw      t0, 16(s0)
        addi    s1, s0, 32
        lw      t2, -16(s1)             # same word, reached from above
        CHECK   t2, 0x0BADF00D, 2

        # ---------------------------------------------------------------
        # Byte stores must not disturb neighbouring bytes
        # ---------------------------------------------------------------
        li      t0, -1
        sw      t0, 4(s0)               # word = 0xFFFFFFFF
        li      t1, 0x00
        sb      t1, 4(s0)               # clear byte 0 only
        lw      t2, 4(s0)
        CHECK   t2, 0xFFFFFF00, 3

        li      t1, 0x11
        sb      t1, 5(s0)               # byte 1
        li      t1, 0x22
        sb      t1, 6(s0)               # byte 2
        li      t1, 0x33
        sb      t1, 7(s0)               # byte 3
        lw      t2, 4(s0)
        CHECK   t2, 0x33221100, 4

        # ---------------------------------------------------------------
        # Halfword stores, both lanes
        # ---------------------------------------------------------------
        li      t0, -1
        sw      t0, 8(s0)
        li      t1, 0xBEEF
        sh      t1, 8(s0)               # low half
        lw      t2, 8(s0)
        CHECK   t2, 0xFFFFBEEF, 5

        li      t1, 0xDEAD
        sh      t1, 10(s0)              # high half
        lw      t2, 8(s0)
        CHECK   t2, 0xDEADBEEF, 6

        # ---------------------------------------------------------------
        # Sign extension on loads. Word at scratch+8 is 0xDEADBEEF.
        # ---------------------------------------------------------------
        lb      t3, 8(s0)               # 0xEF -> -17
        CHECK   t3, -17, 7
        lbu     t3, 8(s0)               # 0xEF -> 239
        CHECK   t3, 0xEF, 8
        lb      t3, 9(s0)               # 0xBE -> -66
        CHECK   t3, -66, 9
        lbu     t3, 10(s0)              # 0xAD
        CHECK   t3, 0xAD, 10
        lb      t3, 11(s0)              # 0xDE -> -34
        CHECK   t3, -34, 11

        lh      t4, 8(s0)               # 0xBEEF -> sign extended
        CHECK   t4, 0xFFFFBEEF, 12
        lhu     t4, 8(s0)               # 0xBEEF -> zero extended
        CHECK   t4, 0x0000BEEF, 13
        lh      t4, 10(s0)              # 0xDEAD -> sign extended
        CHECK   t4, 0xFFFFDEAD, 14
        lhu     t4, 10(s0)
        CHECK   t4, 0x0000DEAD, 15

        # a positive byte must not be sign extended into something negative
        li      t0, 0x7F
        sb      t0, 12(s0)
        lb      t1, 12(s0)
        CHECK   t1, 0x7F, 16

        # ---------------------------------------------------------------
        # Load feeding an address calculation: pointer chasing
        # ---------------------------------------------------------------
        la      t0, ptr_chain
        lw      t1, 0(t0)               # -> node1
        lw      t2, 0(t1)               # load-use straight into the address
        lw      t3, 0(t2)               # and again
        CHECK   t3, 0xC0DE, 17

        # ---------------------------------------------------------------
        # Load feeding a branch condition immediately
        # ---------------------------------------------------------------
        li      t0, 5
        sw      t0, 20(s0)
        li      t1, 5
        lw      t2, 20(s0)
        beq     t2, t1, ls_br_ok        # branch on a value loaded 1 back
        CHECK   x0, 1, 18
ls_br_ok:

        # ---------------------------------------------------------------
        # Array sum: load, accumulate, branch, all in a tight loop
        # ---------------------------------------------------------------
        la      a1, array               # pointer
        li      a2, 0                   # sum
        li      a3, 0                   # index
        li      a4, 8                   # element count
sum_loop:
        lw      a5, 0(a1)               # load
        add     a2, a2, a5              # load-use, distance 1
        addi    a1, a1, 4               # advance pointer
        addi    a3, a3, 1
        blt     a3, a4, sum_loop
        CHECK   a2, 36, 19              # 1+2+3+4+5+6+7+8

        # ---------------------------------------------------------------
        # Copy the array backwards into scratch, then verify it
        # ---------------------------------------------------------------
        la      a1, array
        addi    a2, s0, 64              # destination
        li      a3, 0
        li      a4, 8
copy_loop:
        slli    a5, a3, 2               # source offset
        add     a6, a1, a5
        lw      a7, 0(a6)               # load-use into the store below
        li      t0, 7
        sub     t0, t0, a3              # reversed index
        slli    t0, t0, 2
        add     t0, a2, t0
        sw      a7, 0(t0)
        addi    a3, a3, 1
        blt     a3, a4, copy_loop

        lw      t1, 64(s0)              # first destination word = last source
        CHECK   t1, 8, 20
        lw      t1, 92(s0)              # last destination word = first source
        CHECK   t1, 1, 21

        # ---------------------------------------------------------------
        # Byte-wise string length, a load-use plus branch on every iteration
        # ---------------------------------------------------------------
        la      s2, message
        li      s3, 0                   # length
strlen_loop:
        add     t0, s2, s3
        lbu     t1, 0(t0)               # load-use into the branch below
        beq     t1, x0, strlen_done
        addi    s3, s3, 1
        j       strlen_loop
strlen_done:
        CHECK   s3, 13, 22              # "Hello, RISC-V" is 13 characters

        # ---------------------------------------------------------------
        # Read-modify-write in place, 16 times over the same word
        # ---------------------------------------------------------------
        li      t0, 0
        sw      t0, 100(s0)
        li      s4, 0
        li      s5, 16
rmw_loop:
        lw      t1, 100(s0)
        addi    t1, t1, 3               # load-use
        sw      t1, 100(s0)             # store the value just computed
        addi    s4, s4, 1
        blt     s4, s5, rmw_loop
        lw      t2, 100(s0)
        CHECK   t2, 48, 23              # 16 * 3

TEST_END

# -------------------------------------------------------------------------
# Data
# -------------------------------------------------------------------------
        .section .rodata
        .align  2
array:
        .word   1, 2, 3, 4, 5, 6, 7, 8

ptr_chain:
        .word   node1
node1:
        .word   node2
node2:
        .word   0xC0DE

message:
        .asciz  "Hello, RISC-V"

        .section .bss
        .align  4
scratch:
        .space  256
