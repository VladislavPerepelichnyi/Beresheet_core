/*
 * 05_hazard_stress - real algorithms rather than isolated checks.
 *
 * Each kernel below mixes long RAW chains, load-use pairs, data-dependent
 * branches and calls in the same inner loop. That combination is what shakes
 * out interactions the directed tests miss: a BTB entry invalidated on the
 * cycle a load is bypassing, a mispredict flush landing on top of a stalled
 * store, a return address forwarded while the loop branch resolves.
 */

#include "test_macros.h"

TEST_ENTRY

        li      sp, 0x3E00

        # ===============================================================
        # 1. Iterative Fibonacci. Three-way rotating RAW chain, 20 deep.
        # ===============================================================
        li      t0, 0                   # fib(n-2)
        li      t1, 1                   # fib(n-1)
        li      t2, 0                   # fib(n)
        li      t3, 0                   # counter
        li      t4, 20
fib_loop:
        add     t2, t0, t1              # every operand one instruction old
        add     t0, t1, x0
        add     t1, t2, x0
        addi    t3, t3, 1
        blt     t3, t4, fib_loop
        CHECK   t2, 10946, 1            # fib(21), 20 iterations in

        # ===============================================================
        # 2. Euclid's GCD. Branch direction depends on a fresh subtraction,
        #    so it mispredicts constantly.
        # ===============================================================
        li      a1, 1071
        li      a2, 462
gcd_loop:
        beq     a2, x0, gcd_done
        # a1, a2 = a2, a1 mod a2, computed by repeated subtraction
        add     t0, a1, x0              # remainder accumulator
mod_loop:
        blt     t0, a2, mod_done        # branch on a value just written
        sub     t0, t0, a2
        j       mod_loop
mod_done:
        add     a1, a2, x0
        add     a2, t0, x0
        j       gcd_loop
gcd_done:
        CHECK   a1, 21, 2               # gcd(1071, 462) = 21

        # ===============================================================
        # 3. Bubble sort over 10 words in memory. Load-use into a compare,
        #    a conditional swap, and two nested loop branches.
        # ===============================================================
        la      s0, sort_buf
        la      s1, sort_src
        li      s2, 0
        li      s3, 10
init_copy:
        slli    t0, s2, 2
        add     t1, s1, t0
        lw      t2, 0(t1)
        add     t3, s0, t0
        sw      t2, 0(t3)
        addi    s2, s2, 1
        blt     s2, s3, init_copy

        li      s4, 0                   # outer index
outer_sort:
        li      s5, 0                   # inner index
        li      t4, 9
        sub     t4, t4, s4              # inner bound = 9 - outer
inner_sort:
        slli    t0, s5, 2
        add     t1, s0, t0
        lw      t2, 0(t1)               # a[j]
        lw      t3, 4(t1)               # a[j+1]
        bge     t3, t2, no_swap         # compare two freshly loaded values
        sw      t3, 0(t1)
        sw      t2, 4(t1)
no_swap:
        addi    s5, s5, 1
        blt     s5, t4, inner_sort
        addi    s4, s4, 1
        li      t5, 9
        blt     s4, t5, outer_sort

        # verify the result is sorted ascending and holds the right values
        lw      t0, 0(s0)
        CHECK   t0, 1, 3
        lw      t0, 4(s0)
        CHECK   t0, 5, 4
        lw      t0, 16(s0)
        CHECK   t0, 33, 5
        lw      t0, 36(s0)
        CHECK   t0, 99, 6

        # a full ordering pass, comparing each pair as it is loaded
        li      s5, 0
        li      t4, 9
verify_sorted:
        slli    t0, s5, 2
        add     t1, s0, t0
        lw      t2, 0(t1)
        lw      t3, 4(t1)
        blt     t3, t2, sort_bad        # out of order
        addi    s5, s5, 1
        blt     s5, t4, verify_sorted
        j       sort_ok
sort_bad:
        CHECK   x0, 1, 7
sort_ok:

        # ===============================================================
        # 4. Recursive factorial. Deep call nesting, ra spilled to the stack
        #    and reloaded straight into the return.
        # ===============================================================
        li      a1, 8
        jal     ra, fact
        CHECK   a1, 40320, 8            # 8!

        # ===============================================================
        # 5. Bitwise population count. Long shift-and-mask RAW chain with a
        #    data-dependent branch every iteration.
        # ===============================================================
        li      a2, 0xDEADBEEF
        li      a3, 0                   # count
        li      a4, 0                   # bit index
        li      a5, 32
popcount_loop:
        srl     t0, a2, a4              # shift by a fresh index
        andi    t0, t0, 1
        beq     t0, x0, pc_skip         # branch on the masked bit
        addi    a3, a3, 1
pc_skip:
        addi    a4, a4, 1
        blt     a4, a5, popcount_loop
        CHECK   a3, 24, 9               # popcount(0xDEADBEEF) = 24

        # ===============================================================
        # 6. Checksum with a rotate. Every instruction depends on the last.
        # ===============================================================
        la      s6, sort_src
        li      s7, 0                   # accumulator
        li      s8, 0                   # index
        li      s9, 10
csum_loop:
        slli    t0, s8, 2
        add     t1, s6, t0
        lw      t2, 0(t1)
        add     s7, s7, t2              # accumulate
        slli    t3, s7, 1               # rotate left by 1
        srli    t4, s7, 31
        or      s7, t3, t4
        xor     s7, s7, t2
        addi    s8, s8, 1
        blt     s8, s9, csum_loop
        CHECK   s7, 0x000153EB, 10

        # ===============================================================
        # 7. Binary search over the sorted buffer. The branch direction is
        #    unpredictable, and the midpoint feeds the load address.
        # ===============================================================
        li      a1, 33                  # key
        jal     ra, bsearch
        CHECK   a1, 4, 11               # index of 33 in the sorted array

        li      a1, 7                   # key that is not present
        jal     ra, bsearch
        CHECK   a1, -1, 12

        # ===============================================================
        # 8. Call inside a doubly nested loop. Return-address prediction and
        #    two loop branches all competing for BTB entries.
        # ===============================================================
        li      s0, 0                   # outer
        li      s1, 0                   # total
        li      s2, 6
stress_outer:
        li      s3, 0                   # inner
        li      s4, 5
stress_inner:
        add     a1, s0, s3
        jal     ra, leaf_square         # a1 = a1 * a1 by shift-add
        add     s1, s1, a1
        addi    s3, s3, 1
        blt     s3, s4, stress_inner
        addi    s0, s0, 1
        blt     s0, s2, stress_outer
        CHECK   s1, 755, 13

TEST_END

# -------------------------------------------------------------------------
# Subroutines
# -------------------------------------------------------------------------

# a1 = a1!  (recursive, so ra and a1 both go through the stack)
fact:
        addi    sp, sp, -8
        sw      ra, 0(sp)
        sw      a1, 4(sp)
        li      t0, 2
        blt     a1, t0, fact_base
        addi    a1, a1, -1
        jal     ra, fact                # recurse
        lw      t1, 4(sp)               # reload n
        add     t2, x0, x0              # product accumulator
        add     t3, x0, a1              # multiplicand = (n-1)!
        add     t4, x0, t1              # counter = n
fact_mul:                               # t2 = t3 * t4 by repeated addition
        beq     t4, x0, fact_mul_done
        add     t2, t2, t3
        addi    t4, t4, -1
        j       fact_mul
fact_mul_done:
        add     a1, x0, t2
        j       fact_ret
fact_base:
        li      a1, 1
fact_ret:
        lw      ra, 0(sp)               # load-use into the return
        addi    sp, sp, 8
        ret

# a1 = a1 * a1, using shift-and-add so the RAW chain is long
leaf_square:
        add     t0, x0, a1              # multiplicand
        add     t1, x0, a1              # multiplier
        li      t2, 0                   # product
sq_loop:
        beq     t1, x0, sq_done
        andi    t3, t1, 1
        beq     t3, x0, sq_skip
        add     t2, t2, t0
sq_skip:
        slli    t0, t0, 1
        srli    t1, t1, 1
        j       sq_loop
sq_done:
        add     a1, x0, t2
        ret

# Binary search sort_buf[0..9] for a1; returns the index in a1, or -1
bsearch:
        la      t0, sort_buf
        li      t1, 0                   # low
        li      t2, 9                   # high
bs_loop:
        blt     t2, t1, bs_notfound
        add     t3, t1, t2
        srli    t3, t3, 1               # midpoint, fresh RAW into the address
        slli    t4, t3, 2
        add     t4, t0, t4
        lw      t5, 0(t4)               # load-use into the comparisons below
        beq     t5, a1, bs_found
        blt     t5, a1, bs_higher
        addi    t2, t3, -1              # search the lower half
        j       bs_loop
bs_higher:
        addi    t1, t3, 1               # search the upper half
        j       bs_loop
bs_found:
        add     a1, x0, t3
        ret
bs_notfound:
        li      a1, -1
        ret

# -------------------------------------------------------------------------
# Data
# -------------------------------------------------------------------------
        .section .rodata
        .align  2
sort_src:
        .word   42, 17, 99, 5, 33, 1, 68, 23, 77, 51

        .section .bss
        .align  4
sort_buf:
        .space  64
