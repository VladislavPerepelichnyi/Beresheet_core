/*
 * Shared scaffolding for the RV32I directed tests.
 *
 * Convention with the simulators (fast_sim, and the SoC testbench):
 *   a0 == 0 at EBREAK  -> PASS
 *   a0 != 0 at EBREAK  -> FAIL, a0 is the id of the check that failed
 *
 * Reserved registers, do not use them as test operands:
 *   a0 (x10)  check id / exit code
 *   t6 (x31)  expected-value scratch inside CHECK
 */

#ifndef TEST_MACROS_H
#define TEST_MACROS_H

#define TEST_ENTRY          \
        .section .text.init;\
        .globl _start;      \
_start:

/* Compare \reg against \expect; on mismatch leave \id in a0 and stop. */
.macro CHECK reg, expect, id
        li      a0, \id
        li      t6, \expect
        bne     \reg, t6, test_fail
.endm

/* Same, but the expected value is already in a register. */
.macro CHECK_REG reg, expect_reg, id
        li      a0, \id
        bne     \reg, \expect_reg, test_fail
.endm

/*
 * Finish the test.
 *
 * mtvec is cleared first, and that is not cosmetic. Traps now vector, so the
 * closing ebreak jumps to whatever mtvec holds. The simulators treat "a trap
 * taken with mtvec == 0" as the end of the run - a jump to a null handler is
 * the one situation from which no forward progress is possible - so a test that
 * left a real address in mtvec would sail off into it instead of stopping.
 * Clearing it here means no individual test has to remember.
 */
#define TEST_END            \
        csrw    mtvec, x0;  \
        li      a0, 0;      \
        ebreak;             \
test_fail:                  \
        csrw    mtvec, x0;  \
        ebreak

#endif
