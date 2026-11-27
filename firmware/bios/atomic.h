/*
 * RV32A atomics as inline assembly.
 *
 * Written out rather than using the __atomic builtins so that the self test
 * exercises exactly these instructions; the compiler is free to lower a
 * single-threaded builtin to a plain load and store.
 */
#ifndef ATOMIC_H
#define ATOMIC_H

#include <stdint.h>

static inline uint32_t amo_add(volatile uint32_t *p, uint32_t v)
{
    uint32_t old;
    __asm__ volatile ("amoadd.w %0, %2, (%1)"
                      : "=r"(old) : "r"(p), "r"(v) : "memory");
    return old;
}

static inline uint32_t amo_swap(volatile uint32_t *p, uint32_t v)
{
    uint32_t old;
    __asm__ volatile ("amoswap.w %0, %2, (%1)"
                      : "=r"(old) : "r"(p), "r"(v) : "memory");
    return old;
}

static inline uint32_t amo_or(volatile uint32_t *p, uint32_t v)
{
    uint32_t old;
    __asm__ volatile ("amoor.w %0, %2, (%1)"
                      : "=r"(old) : "r"(p), "r"(v) : "memory");
    return old;
}

static inline uint32_t amo_and(volatile uint32_t *p, uint32_t v)
{
    uint32_t old;
    __asm__ volatile ("amoand.w %0, %2, (%1)"
                      : "=r"(old) : "r"(p), "r"(v) : "memory");
    return old;
}

static inline uint32_t amo_maxu(volatile uint32_t *p, uint32_t v)
{
    uint32_t old;
    __asm__ volatile ("amomaxu.w %0, %2, (%1)"
                      : "=r"(old) : "r"(p), "r"(v) : "memory");
    return old;
}

static inline uint32_t lr_w(volatile uint32_t *p)
{
    uint32_t v;
    __asm__ volatile ("lr.w %0, (%1)" : "=r"(v) : "r"(p) : "memory");
    return v;
}

/* 0 on success, non-zero if the reservation was lost. */
static inline uint32_t sc_w(volatile uint32_t *p, uint32_t v)
{
    uint32_t r;
    __asm__ volatile ("sc.w %0, %2, (%1)"
                      : "=r"(r) : "r"(p), "r"(v) : "memory");
    return r;
}

/*
 * Compare-and-swap from LR/SC, as in the ISA manual's example. Returns 1 if it
 * swapped. SC may fail spuriously, hence the retry loop.
 */
static inline int cas(volatile uint32_t *p, uint32_t expect, uint32_t desired)
{
    for (;;) {
        if (lr_w(p) != expect)
            return 0;
        if (sc_w(p, desired) == 0)
            return 1;
    }
}

/* A test-and-set spinlock, the canonical use of amoswap. */
static inline void lock_acquire(volatile uint32_t *lock)
{
    while (amo_swap(lock, 1u) != 0u)
        ;
}

static inline void lock_release(volatile uint32_t *lock)
{
    __asm__ volatile ("amoswap.w x0, x0, (%0)" :: "r"(lock) : "memory");
}

#endif
