/*
 * Instruction address misaligned, mcause = 0.
 * JALR clears bit 0 of its target but not bit 1, so a target with bit 1 set
 * must be reported by the jump itself.
 */

        .section .text.init
        .globl _start
_start:
        la      t0, target
        addi    t0, t0, 2               # target + 2, still misaligned after masking
        jalr    x0, 0(t0)
        ebreak                          # must not be reached
target:
        nop
        ebreak
