/*
 * CLINT driver. Memory mapped, per the ACLINT specification.
 *
 * The register offsets are fixed by that spec, which is what makes the same
 * driver work on any RISC-V machine; only the base address is per-platform, and
 * on a real system it comes from the device tree.
 *
 * The timer's contract is worth stating plainly, because it is the one thing
 * everybody gets wrong once: mtip is a *comparison*, not a latch. It is asserted
 * for as long as mtime >= mtimecmp. There is no "acknowledge" and no bit to
 * clear - the only way to make the interrupt go away is to move mtimecmp
 * forward. A handler that forgets re-enters immediately and the machine appears
 * to hang inside its own timer.
 */
#ifndef CLINT_H
#define CLINT_H

#include <stdint.h>
#include "soc.h"

#define CLINT_MSIP      (CLINT_BASE + 0x0000u)
#define CLINT_MTIMECMP  (CLINT_BASE + 0x4000u)
#define CLINT_MTIME     (CLINT_BASE + 0xBFF8u)

/*
 * mtime is 64 bits read as two words, so the same read-high / read-low /
 * re-read-high dance the counters need applies here.
 */
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
 * Write the high word first, to all-ones, before touching the low word. That
 * ordering matters: mtimecmp is compared as a whole 64-bit value, so if the low
 * word were written first it could momentarily hold a value already in the past
 * and fire a spurious interrupt between the two stores.
 */
static inline void clint_set_timecmp(uint64_t v)
{
    mmio_w32(CLINT_MTIMECMP + 4u, 0xFFFFFFFFu);
    mmio_w32(CLINT_MTIMECMP,      (uint32_t)v);
    mmio_w32(CLINT_MTIMECMP + 4u, (uint32_t)(v >> 32));
}

/* Schedule the next tick relative to now. */
static inline void clint_next_tick(uint32_t us)
{
    clint_set_timecmp(clint_mtime() + us);
}

static inline void clint_set_soft(int on)
{
    mmio_w32(CLINT_MSIP, on ? 1u : 0u);
}

#endif
