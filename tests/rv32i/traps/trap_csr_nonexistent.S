/*
 * Illegal instruction, mcause = 2: access to a CSR that does not exist.
 *
 * pmpcfg0 is the interesting choice here rather than some arbitrary unused
 * address. PMP is deliberately not implemented (see the progress report), and
 * this is precisely how OpenSBI discovers that: it installs a trap handler and
 * *executes* a pmpcfg0 access, reading the fault as "no PMP". Answering with a
 * read-only zero instead would tell it PMP exists with zero regions, which is a
 * different and wrong statement.
 *
 * This test used to read medeleg, which was absent while the hart was M-mode
 * only. S-mode made it mandatory, so the test moved rather than the rule.
 */

        .section .text.init
        .globl _start
_start:
        li      t0, 1
        csrr    t1, 0x3A0               # pmpcfg0, deliberately not implemented
        ebreak                          # must not be reached
