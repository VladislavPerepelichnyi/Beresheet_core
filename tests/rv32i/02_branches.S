/*
 * 02_branches - all six conditional branches plus heavy control-hazard traffic.
 *
 * The pipeline predicts in Fetch from the BTB and resolves in Decode/Execute,
 * so every branch here is deliberately arranged to stress that loop:
 *   * both polarities of every funct3, so a comparator that collapses to BEQ
 *     is caught immediately;
 *   * branches whose operands were written by the immediately preceding
 *     instruction, combining a RAW hazard with a control hazard;
 *   * backward branches taken many times, which trains a BTB entry and then
 *     invalidates it on the final fall-through;
 *   * forward branches that alias onto the same BTB index.
 */

#include "test_macros.h"

TEST_ENTRY

        # ---------------------------------------------------------------
        # BEQ / BNE, both directions
        # ---------------------------------------------------------------
        li      t0, 7
        li      t1, 7
        beq     t0, t1, 1f
        CHECK   x0, 1, 1                # must not be reached
1:      bne     t0, t1, 2f
        j       3f
2:      CHECK   x0, 1, 2                # must not be reached
3:
        li      t1, 8
        bne     t0, t1, 4f
        CHECK   x0, 1, 3
4:      beq     t0, t1, 5f
        j       6f
5:      CHECK   x0, 1, 4
6:

        # ---------------------------------------------------------------
        # BLT / BGE, signed. The classic trap is comparing as unsigned.
        # ---------------------------------------------------------------
        li      t0, -5
        li      t1, 3
        blt     t0, t1, 7f              # -5 < 3 signed -> taken
        CHECK   x0, 1, 5
7:      bge     t0, t1, 8f              # not taken
        j       9f
8:      CHECK   x0, 1, 6
9:      bge     t1, t0, 10f             # 3 >= -5 -> taken
        CHECK   x0, 1, 7
10:     blt     t1, t0, 11f             # not taken
        j       12f
11:     CHECK   x0, 1, 8
12:
        # equal operands: BGE taken, BLT not
        bge     t0, t0, 13f
        CHECK   x0, 1, 9
13:     blt     t0, t0, 14f
        j       15f
14:     CHECK   x0, 1, 10
15:

        # ---------------------------------------------------------------
        # BLTU / BGEU, unsigned. -1 must read as 0xFFFFFFFF here.
        # ---------------------------------------------------------------
        li      t0, -1                  # 0xFFFFFFFF
        li      t1, 1
        bltu    t1, t0, 16f             # 1 < huge -> taken
        CHECK   x0, 1, 11
16:     bltu    t0, t1, 17f             # not taken
        j       18f
17:     CHECK   x0, 1, 12
18:     bgeu    t0, t1, 19f             # huge >= 1 -> taken
        CHECK   x0, 1, 13
19:     bgeu    t1, t0, 20f             # not taken
        j       21f
20:     CHECK   x0, 1, 14
21:
        # the same pair signed goes the other way, proving the two are distinct
        blt     t0, t1, 22f             # -1 < 1 signed -> taken
        CHECK   x0, 1, 15
22:

        # ---------------------------------------------------------------
        # Branch on a value produced by the instruction right before it
        # ---------------------------------------------------------------
        li      t2, 10
        li      t3, 4
        sub     t4, t2, t3              # 6
        li      t5, 6
        beq     t4, t5, 23f             # operand written 2 instructions back
        CHECK   x0, 1, 16
23:
        addi    t4, t4, 1               # 7, written immediately before the branch
        beq     t4, t5, 24f             # must NOT be taken
        j       25f
24:     CHECK   x0, 1, 17
25:
        addi    t5, t5, 1               # 7, rs2 written immediately before
        beq     t4, t5, 26f             # must be taken
        CHECK   x0, 1, 18
26:

        # ---------------------------------------------------------------
        # Backward loop: trains the BTB, then falls through once at the end
        # ---------------------------------------------------------------
        li      s0, 0                   # counter
        li      s1, 0                   # accumulator
        li      s2, 20                  # trip count
loop1:
        addi    s1, s1, 3               # RAW into the next add
        addi    s0, s0, 1               # RAW into the branch below
        blt     s0, s2, loop1
        CHECK   s0, 20, 19
        CHECK   s1, 60, 20

        # ---------------------------------------------------------------
        # Nested loops. The inner backward branch is taken 5x per outer pass,
        # so the outer branch's BTB entry has to survive the inner traffic.
        # ---------------------------------------------------------------
        li      s3, 0                   # outer counter
        li      s4, 0                   # total iterations
        li      t1, 5                   # inner trip count
        li      t2, 4                   # outer trip count
loop_outer:
        li      s5, 0                   # inner counter
loop_inner:
        addi    s4, s4, 1
        addi    s5, s5, 1
        blt     s5, t1, loop_inner      # 5 inner iterations
        addi    s3, s3, 1
        blt     s3, t2, loop_outer      # 4 outer iterations
        CHECK   s3, 4,  21
        CHECK   s4, 20, 22

        # ---------------------------------------------------------------
        # Alternating outcome. The same branch flips taken / not-taken every
        # pass, so a BTB entry is allocated and invalidated repeatedly.
        # ---------------------------------------------------------------
        li      s6, 0                   # loop counter
        li      s7, 0                   # count of even iterations
        li      t1, 16                  # trip count
alt_loop:
        andi    t0, s6, 1
        bne     t0, x0, alt_odd         # flips each pass
        addi    s7, s7, 1
alt_odd:
        addi    s6, s6, 1
        blt     s6, t1, alt_loop
        CHECK   s6, 16, 23
        CHECK   s7, 8,  24

        # ---------------------------------------------------------------
        # Branch chain: several branches back to back with no filler, each
        # depending on the comparison just made
        # ---------------------------------------------------------------
        li      a1, 5
        li      a2, 5
        li      a3, 0
        beq     a1, a2, c1
        j       cfail
c1:     bne     a1, x0, c2
        j       cfail
c2:     bge     a1, a2, c3
        j       cfail
c3:     bltu    x0, a1, c4
        j       cfail
c4:     addi    a3, a3, 1
        blt     a3, a1, c5              # 1 < 5 -> taken
        j       cfail
c5:     bge     a3, a1, cfail           # not taken
        j       cdone
cfail:  CHECK   x0, 1, 25
cdone:

        # ---------------------------------------------------------------
        # Long forward branch, exercising a large B-type immediate
        # ---------------------------------------------------------------
        li      t0, 1
        beq     t0, t0, far_target
        CHECK   x0, 1, 26
        .rept 300
        nop
        .endr
far_target:
        CHECK   t0, 1, 27

TEST_END
