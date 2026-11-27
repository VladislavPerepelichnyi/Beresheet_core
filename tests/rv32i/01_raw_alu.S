/*
 * 01_raw_alu - back-to-back RAW dependency chains through every RV32I ALU op.
 *
 * Every instruction consumes the result the previous instruction produced, so
 * each pair is a distance-1 RAW hazard and has to be caught by the register
 * file's write-through bypass. No independent instruction is ever inserted to
 * give the pipeline slack.
 */

#include "test_macros.h"

TEST_ENTRY

        # ---------------------------------------------------------------
        # Chain 1: immediate arithmetic, 8 links, every result feeds the next
        # ---------------------------------------------------------------
        li      t0, 0                   # t0 = 0
        addi    t0, t0, 100             # 100
        addi    t0, t0, -30             # 70
        addi    t0, t0, 5               # 75
        addi    t0, t0, -75             # 0
        addi    t0, t0, 2047            # 2047   (max positive I-immediate)
        addi    t0, t0, -2048           # -1     (max negative I-immediate)
        addi    t0, t0, 1               # 0
        addi    t0, t0, 42              # 42
        CHECK   t0, 42, 1

        # ---------------------------------------------------------------
        # Chain 2: logic ops, alternating operand position
        # ---------------------------------------------------------------
        li      t1, 0x0F0F0F0F
        xori    t1, t1, -1              # 0xF0F0F0F0
        ori     t1, t1, 0x00F           # 0xF0F0F0FF
        andi    t1, t1, 0x7FF           # 0x000000FF
        xori    t1, t1, 0x0F0           # 0x0000000F
        CHECK   t1, 0x0000000F, 2

        # ---------------------------------------------------------------
        # Chain 3: shifts, immediate form. Each shift uses the previous result
        # ---------------------------------------------------------------
        li      t2, 1
        slli    t2, t2, 31              # 0x80000000
        srli    t2, t2, 28              # 0x00000008
        slli    t2, t2, 4               # 0x00000080
        srai    t2, t2, 3               # 0x00000010
        CHECK   t2, 0x00000010, 3

        # arithmetic shift must replicate the sign bit
        li      t3, -256                # 0xFFFFFF00
        srai    t3, t3, 4               # 0xFFFFFFF0
        srai    t3, t3, 28              # 0xFFFFFFFF
        CHECK   t3, -1, 4

        # logical shift must not
        li      t4, -256
        srli    t4, t4, 4               # 0x0FFFFFF0
        CHECK   t4, 0x0FFFFFF0, 5

        # ---------------------------------------------------------------
        # Chain 4: register-register ops where BOTH sources are freshly written
        # ---------------------------------------------------------------
        li      s0, 17
        li      s1, 5
        add     s2, s0, s1              # 22   (rs1 and rs2 both 1-2 back)
        sub     s3, s2, s1              # 17
        add     s4, s3, s2              # 39
        sub     s5, s4, s3              # 22
        and     s6, s4, s5              # 39 & 22 = 6
        or      s7, s6, s5              # 6 | 22 = 22
        xor     s8, s7, s6              # 22 ^ 6 = 16
        add     s9, s8, s7              # 16 + 22 = 38
        CHECK   s2, 22, 6
        CHECK   s3, 17, 7
        CHECK   s4, 39, 8
        CHECK   s5, 22, 9
        CHECK   s6, 6,  10
        CHECK   s7, 22, 11
        CHECK   s8, 16, 12
        CHECK   s9, 38, 13

        # ---------------------------------------------------------------
        # Chain 5: register shifts, shift amount itself a fresh RAW result
        # ---------------------------------------------------------------
        li      t0, 4
        li      t1, 1
        sll     t1, t1, t0              # 16, shift amount 1 back
        add     t0, t0, t0              # 8
        srl     t1, t1, t0              # 16 >> 8 = 0
        addi    t1, t1, 1               # 1
        sll     t1, t1, t0              # 1 << 8 = 256
        CHECK   t1, 256, 14

        # only the low 5 bits of a register shift amount count
        li      t2, 1
        li      t3, 33                  # 33 & 31 = 1
        sll     t2, t2, t3              # 2, not 0
        CHECK   t2, 2, 15

        # ---------------------------------------------------------------
        # Chain 6: signed vs unsigned comparison, results feeding each other
        # ---------------------------------------------------------------
        li      a1, -1
        li      a2, 1
        slt     a3, a1, a2              # -1 <  1 signed   -> 1
        sltu    a4, a1, a2              # huge < 1 unsigned -> 0
        add     a5, a3, a4              # 1
        slti    a6, a5, 2               # 1 < 2 -> 1
        sltiu   a7, a6, 1               # 1 < 1 -> 0
        add     a1, a6, a7              # 1
        CHECK   a3, 1, 16
        CHECK   a4, 0, 17
        CHECK   a5, 1, 18
        CHECK   a6, 1, 19
        CHECK   a7, 0, 20
        CHECK   a1, 1, 21

        # ---------------------------------------------------------------
        # Chain 7: LUI / AUIPC. LUI has no rs1 field, AUIPC needs the PC.
        # ---------------------------------------------------------------
        lui     t0, 0x12345             # 0x12345000
        addi    t0, t0, 0x678           # 0x12345678
        CHECK   t0, 0x12345678, 22

        lui     t1, 0xFFFFF             # 0xFFFFF000
        srli    t1, t1, 12              # 0x000FFFFF
        CHECK   t1, 0x000FFFFF, 23

        # AUIPC with a zero offset must yield the address of the AUIPC itself
auipc_here:
        auipc   t2, 0
        la      t3, auipc_here
        CHECK_REG t2, t3, 24

        # ---------------------------------------------------------------
        # Chain 8: x0 stays zero no matter what is written to it
        # ---------------------------------------------------------------
        li      t0, 0x5A5A
        add     x0, t0, t0
        addi    x0, x0, 1234
        CHECK   x0, 0, 25
        add     t1, x0, t0              # reading x0 right after writing it
        CHECK   t1, 0x5A5A, 26

        # ---------------------------------------------------------------
        # Chain 9: 20-deep accumulate, one long unbroken RAW chain
        # ---------------------------------------------------------------
        li      t0, 0
        addi    t0, t0, 1
        addi    t0, t0, 2
        addi    t0, t0, 3
        addi    t0, t0, 4
        addi    t0, t0, 5
        addi    t0, t0, 6
        addi    t0, t0, 7
        addi    t0, t0, 8
        addi    t0, t0, 9
        addi    t0, t0, 10
        addi    t0, t0, 11
        addi    t0, t0, 12
        addi    t0, t0, 13
        addi    t0, t0, 14
        addi    t0, t0, 15
        addi    t0, t0, 16
        addi    t0, t0, 17
        addi    t0, t0, 18
        addi    t0, t0, 19
        addi    t0, t0, 20
        CHECK   t0, 210, 27

        # ---------------------------------------------------------------
        # Chain 10: overflow wraps around, no trap in RV32I
        # ---------------------------------------------------------------
        li      t1, 0x7FFFFFFF
        addi    t1, t1, 1               # wraps to 0x80000000
        CHECK   t1, 0x80000000, 28
        sub     t1, t1, t1              # 0
        CHECK   t1, 0, 29

TEST_END
