/*
 * Load address misaligned, mcause = 4.
 * LW from an address whose low two bits are non-zero.
 */

        .section .text.init
        .globl _start
_start:
        la      t0, buf
        addi    t0, t0, 2               # deliberately unaligned
        lw      t1, 0(t0)
        ebreak                          # must not be reached

        .section .bss
        .align  4
buf:    .space  16
