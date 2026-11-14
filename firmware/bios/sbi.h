/*
 * Supervisor Binary Interface calls, from the S-mode side.
 *
 * An SBI call is an ECALL executed in S-mode. That raises cause 9,
 * "environment call from S-mode", which the firmware running in M-mode catches
 * and services. It is the whole reason cause 8 and cause 9 are distinct
 * numbers: if every ecall reported the same cause, machine mode could not tell
 * a kernel's request from a user program's.
 *
 * The register convention is fixed by the SBI specification:
 *
 *   a7  extension ID          a6  function ID
 *   a0..a5  arguments         a0  error code on return
 *                             a1  value on return
 */
#ifndef SBI_H
#define SBI_H

#include <stdint.h>

#define SBI_EXT_BASE        0x10u
#define SBI_BASE_GET_SPEC   0u
#define SBI_BASE_GET_IMPL   1u
#define SBI_BASE_GET_MVENDORID 4u

/* Debug console, so a payload can print without touching the UART itself. */
#define SBI_EXT_DBCN        0x4442434Eu
#define SBI_DBCN_WRITE_BYTE 2u

struct sbiret { long error; long value; };

static inline struct sbiret sbi_ecall(unsigned long ext, unsigned long fid,
                                      unsigned long arg0, unsigned long arg1,
                                      unsigned long arg2)
{
    struct sbiret ret;
    register unsigned long r_a0 __asm__("a0") = arg0;
    register unsigned long r_a1 __asm__("a1") = arg1;
    register unsigned long r_a2 __asm__("a2") = arg2;
    register unsigned long r_a6 __asm__("a6") = fid;
    register unsigned long r_a7 __asm__("a7") = ext;

    __asm__ volatile ("ecall"
                      : "+r"(r_a0), "+r"(r_a1)
                      : "r"(r_a2), "r"(r_a6), "r"(r_a7)
                      : "memory");

    ret.error = (long)r_a0;
    ret.value = (long)r_a1;
    return ret;
}

#endif
