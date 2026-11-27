/*
 * Zicsr / Zicntr access helpers.
 *
 * The counters are 64 bits even on RV32 and are read as two halves, so a naive
 * pair of reads can straddle a carry: the low half wraps between the two reads
 * and the result is off by 2^32. The spec's own sample code solves it by reading
 * the high half, then the low half, then the high half again, and retrying if
 * the high half moved. That loop is what read_*64 below implements.
 */
#ifndef CSR_H
#define CSR_H

#include <stdint.h>

#define csr_read(reg) ({                                  \
    uint32_t __v;                                         \
    __asm__ volatile ("csrr %0, " #reg : "=r"(__v));      \
    __v; })

#define csr_write(reg, val) ({                            \
    uint32_t __v = (uint32_t)(val);                       \
    __asm__ volatile ("csrw " #reg ", %0" :: "r"(__v));   \
})

#define csr_set(reg, mask) ({                             \
    uint32_t __v = (uint32_t)(mask);                      \
    __asm__ volatile ("csrs " #reg ", %0" :: "r"(__v));   \
})

#define csr_clear(reg, mask) ({                           \
    uint32_t __v = (uint32_t)(mask);                      \
    __asm__ volatile ("csrc " #reg ", %0" :: "r"(__v));   \
})

/* One macro for all three counters: they differ only in which CSR pair. */
#define DEFINE_READ64(name, lo, hi)                       \
static inline uint64_t name(void)                         \
{                                                         \
    uint32_t h0, l, h1;                                   \
    do {                                                  \
        h0 = csr_read(hi);                                \
        l  = csr_read(lo);                                \
        h1 = csr_read(hi);                                \
    } while (h0 != h1);   /* the low half carried; retry */\
    return ((uint64_t)h1 << 32) | l;                      \
}

DEFINE_READ64(read_cycle64,   cycle,   cycleh)
DEFINE_READ64(read_time64,    time,    timeh)
DEFINE_READ64(read_instret64, instret, instreth)

#endif
