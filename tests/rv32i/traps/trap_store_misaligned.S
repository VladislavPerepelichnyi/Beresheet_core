/*
 * Store address misaligned, mcause = 6.
 * SH to an odd address.
 */

        .section .text.init
        .globl _start
_start:
        la      t0, buf
        addi    t0, t0, 1               # odd address
        li      t1, 0xABCD
        sh      t1, 0(t0)
        ebreak                          # must not be reached

        .section .bss
        .align  4
buf:    .space  16
