/*
 * Illegal instruction, mcause = 2: writing a read-only CSR.
 *
 * `cycle` is at 0xC00, so csr[11:10] = 11 and the CSR is read-only. CSRRW
 * always writes, even with rs1 = x0 - the spec says "A CSRRW with rs1=x0 will
 * attempt to write zero to the destination CSR" - so this must trap.
 *
 * The contrast that matters is in 08_csr: csrrs with a zero mask does NOT write,
 * and so reading the same read-only CSR is perfectly legal. Both behaviours come
 * from the same rule, which is why the check keys off whether the access writes
 * rather than off the opcode.
 */

        .section .text.init
        .globl _start
_start:
        li      t0, 1
        csrw    cycle, x0               # csrrw x0, cycle, x0 -> a write, illegal
        ebreak                          # must not be reached
