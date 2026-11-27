/*
 * Zicsr / Zicntr access helpers.
 *
 * On RV32 the 64-bit counters are read as two halves. read_*64 reads high, low,
 * high and retries if the high half changed, so a carry between the two reads
 * cannot produce a value off by 2^32.
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
