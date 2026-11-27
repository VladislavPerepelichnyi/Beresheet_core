/*
 * PLIC driver, register layout per the RISC-V PLIC specification.
 *
 *   gateway         forwards one request per source and accepts no further
 *                   request from it until software completes the previous one
 *   arbitration     the highest-priority pending, enabled source wins (ties go
 *                   to the lowest ID); the context's interrupt is asserted if
 *                   that priority exceeds the context's threshold
 *   claim/complete  reading the claim register returns the winning ID and
 *                   clears its pending bit; writing the ID back completes it
 *
 * A context is one privilege mode on one hart: context 0 is hart 0 M-mode (used
 * by the BIOS), context 1 is hart 0 S-mode (used by Linux).
 */
#ifndef PLIC_H
#define PLIC_H

#include <stdint.h>
#include "soc.h"

#define PLIC_PRIORITY(id)   (PLIC_BASE + 0x000000u + 4u * (id))
#define PLIC_PENDING        (PLIC_BASE + 0x001000u)
#define PLIC_ENABLE(ctx)    (PLIC_BASE + 0x002000u + 0x80u * (ctx))
#define PLIC_THRESHOLD(ctx) (PLIC_BASE + 0x200000u + 0x1000u * (ctx))
#define PLIC_CLAIM(ctx)     (PLIC_BASE + 0x200004u + 0x1000u * (ctx))

#define PLIC_CTX_M0     0u          /* hart 0, machine mode    */
#define PLIC_CTX_S0     1u          /* hart 0, supervisor mode */

/* Source numbers. Must agree with RTL/bus/wb_defines.vh. */
#define PLIC_SRC_UART   1u
#define PLIC_SRC_SW(n)  (2u + (n))  /* GPIO_SWIRQ bit n, n = 0..3 */
#define PLIC_SW_LINES   4u

#define PLIC_MAX_PRIO   7u

static inline void plic_set_priority(unsigned id, uint32_t prio)
{
    mmio_w32(PLIC_PRIORITY(id), prio);
}

/* Priority 0 disables a source. */
static inline void plic_disable_source(unsigned id)
{
    mmio_w32(PLIC_PRIORITY(id), 0u);
}

static inline uint32_t plic_pending(void)
{
    return mmio_r32(PLIC_PENDING);
}

static inline void plic_enable(unsigned ctx, unsigned id, int on)
{
    uint32_t m = mmio_r32(PLIC_ENABLE(ctx));
    if (on) m |= (1u << id);
    else    m &= ~(1u << id);
    mmio_w32(PLIC_ENABLE(ctx), m);
}

/* Only sources with priority strictly greater than the threshold interrupt. */
static inline void plic_set_threshold(unsigned ctx, uint32_t t)
{
    mmio_w32(PLIC_THRESHOLD(ctx), t);
}

/* Returns the winning source ID and clears its pending bit; 0 means none. */
static inline uint32_t plic_claim(unsigned ctx)
{
    return mmio_r32(PLIC_CLAIM(ctx));
}

/* Completes a claimed source, so its gateway accepts the next request. */
static inline void plic_complete(unsigned ctx, uint32_t id)
{
    mmio_w32(PLIC_CLAIM(ctx), id);
}

static inline void plic_swirq_set(uint32_t mask)
{
    mmio_w32(GPIO_SWIRQ, mask);
}

static inline uint32_t plic_swirq_get(void)
{
    return mmio_r32(GPIO_SWIRQ);
}

#endif
