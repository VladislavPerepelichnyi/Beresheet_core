/*
 * Division in user mode on real hardware, with no libc anywhere near it.
 *
 * The board printed one line from a glibc binary and hung. The next thing that
 * binary did was format a number, which compiles to divu/remu, and no assembly
 * probe that ran correctly contained a single div, rem or mul. That made
 * division the suspect.
 *
 * Simulation disagrees. Division is correct in M-mode, in U-mode with
 * translation on, with a zero divisor, with a dividend smaller than the
 * divisor, adjacent to a translated load, and - as of 18_div_irq - with timer
 * interrupts landing inside the multi-cycle operation. 768 divisions, every
 * result checked, interrupts verified to have fired.
 *
 * So either division works on hardware too and the suspect is wrong, or
 * simulation is missing something only silicon has. This settles which, without
 * a C library in the picture.
 *
 * Every message ends in a newline. The probe this replaces printed
 * "PROBE 1b kmsg fd = " with no newline, which is a partial line on a console
 * and easy to miss - so "it hung at the division" was an inference from source
 * order, not something anyone actually saw. Nothing here is ambiguous.
 */
    .section .rodata
mA: .ascii "DIV A: user mode, about to divide\n"
    .equ lA, . - mA
mB: .ascii "DIV B: divu 1000/7 done\n"
    .equ lB, . - mB
mC: .ascii "DIV C: remu done\n"
    .equ lC, . - mC
mD: .ascii "DIV D: mul done\n"
    .equ lD, . - mD
mE: .ascii "DIV E: q*d+r == 1000, arithmetic is correct\n"
    .equ lE, . - mE
mEbad:
    .ascii "DIV E: WRONG RESULT - division is broken on hardware\n"
    .equ lEbad, . - mEbad
mF: .ascii "DIV F: 4096 divisions with divisors 1..8\n"
    .equ lF, . - mF
mG: .ascii "DIV G: all 4096 correct\n"
    .equ lG, . - mG
mGbad:
    .ascii "DIV G: a division in the loop returned a WRONG RESULT\n"
    .equ lGbad, . - mGbad
mH: .ascii "DIV H: small dividend 3/10, as say_num does\n"
    .equ lH, . - mH
mI: .ascii "DIV I: done. division works in user mode on this board.\n"
    .equ lI, . - mI
kp: .asciz "/dev/kmsg"

    .section .text
    .globl _start
    .macro say a, l
    blt     s0, zero, 9f
    mv      a0, s0
    lla     a1, \a
    li      a2, \l
    li      a7, 64
    ecall
9:
    .endm

_start:
    li      a0, -100
    lla     a1, kp
    li      a2, 1
    li      a3, 0
    li      a7, 56
    ecall
    mv      s0, a0

    say     mA, lA

    /* One division at a time, announced before and after, so a hang names the
     * exact instruction rather than a region. */
    li      s2, 1000
    li      s3, 7
    divu    s4, s2, s3
    say     mB, lB
    remu    s5, s2, s3
    say     mC, lC
    mul     s6, s4, s3
    say     mD, lD
    add     s6, s6, s5
    li      s7, 1000
    bne     s6, s7, 1f
    say     mE, lE
    j       2f
1:  say     mEbad, lEbad
2:

    /* Then at volume, because a fault that needs an interrupt to land inside
     * the divider is a race and one attempt proves little. */
    say     mF, lF
    li      s1, 4096
    li      s3, 1
    li      s8, 0                       /* 0 = no error seen */
3:
    li      s2, 1000
    divu    s4, s2, s3
    remu    s5, s2, s3
    mul     s6, s4, s3
    add     s6, s6, s5
    li      s7, 1000
    beq     s6, s7, 4f
    li      s8, 1
4:
    addi    s3, s3, 1
    li      s7, 9
    bne     s3, s7, 5f
    li      s3, 1
5:
    addi    s1, s1, -1
    bnez    s1, 3b

    bnez    s8, 6f
    say     mG, lG
    j       7f
6:  say     mGbad, lGbad
7:

    /* The exact operands say_num(3) uses. */
    say     mH, lH
    li      s2, 3
    li      s3, 10
    divu    s4, s2, s3
    remu    s5, s2, s3

    say     mI, lI

    li      a0, 0
    li      a7, 93
    ecall
hang:
    j       hang
