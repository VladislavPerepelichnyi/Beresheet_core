/*
 * Illegal instruction, mcause = 2.
 *
 * Two encodings that must be rejected on RV32IM:
 *   LD  - a valid opcode (LOAD) with funct3 = 011, which only exists on RV64.
 *   OP with funct7 = 0000010, a reserved value: 0000000 and 0100000 are the
 *   base ISA and 0000001 is RV32M, so this one has no meaning.
 *
 * The first one traps, so the second is unreachable; it is kept as a second
 * case to switch to by swapping the two lines.
 */

        .section .text.init
        .globl _start
_start:
        li      t0, 1
        la      t1, buf
        .word   0x00033283              # ld x5, 0(x6)  -> RV64 only
        .word   0x042081b3              # op funct7=0000010 -> reserved
        ebreak                          # must not be reached

        .section .bss
        .align  4
buf:    .space  16
