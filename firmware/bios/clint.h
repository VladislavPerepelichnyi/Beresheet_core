/*
 * CLINT driver, register layout per the ACLINT specification.
 *
 * The timer interrupt (mip.MTIP) is a comparison, not a latch: it is asserted
 * while mtime >= mtimecmp, and the only way to clear it is to move mtimecmp
 * forward. mtime ticks at 1 MHz, so the timer works in microseconds.
 */
#ifndef CLINT_H
#define CLINT_H

#include <stdint.h>
#include "soc.h"

#define CLINT_MSIP      (CLINT_BASE + 0x0000u)
#define CLINT_MTIMECMP  (CLINT_BASE + 0x4000u)
#define CLINT_MTIME     (CLINT_BASE + 0xBFF8u)

/* 64-bit read as two words: retry if the high word changed in between. */
static inline uint64_t clint_mtime(void)
{
    uint32_t h0, l, h1;
    do {
        h0 = mmio_r32(CLINT_MTIME + 4u);
        l  = mmio_r32(CLINT_MTIME);
        h1 = mmio_r32(CLINT_MTIME + 4u);
    } while (h0 != h1);
    return ((uint64_t)h1 << 32) | l;
}

/*
 * The high word goes to all-ones first, so that no intermediate value of the
 * 64-bit comparator lies in the past and fires a spurious interrupt.
 */
static inline void clint_set_timecmp(uint64_t v)
{
    mmio_w32(CLINT_MTIMECMP + 4u, 0xFFFFFFFFu);
    mmio_w32(CLINT_MTIMECMP,      (uint32_t)v);
    mmio_w32(CLINT_MTIMECMP + 4u, (uint32_t)(v >> 32));
}

/* Schedule the next timer interrupt `us` microseconds from now. */
static inline void clint_next_tick(uint32_t us)
{
    clint_set_timecmp(clint_mtime() + us);
}

static inline void clint_set_soft(int on)
{
    mmio_w32(CLINT_MSIP, on ? 1u : 0u);
}

#endif
