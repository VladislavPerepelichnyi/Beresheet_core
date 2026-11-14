/*
 * PLIC driver. Memory mapped, per the RISC-V PLIC specification.
 *
 * The PLIC exists so the core does not have to know how many devices there are.
 * Every device interrupt in the system lands here; the PLIC picks one and
 * presents a single wire to the hart. Three mechanisms do that, and keeping them
 * apart is most of understanding the device:
 *
 *   gateway      one request per assertion, and no further request from that
 *                source until software says it is finished. This is what makes a
 *                level-held line - which a device holds until serviced - usable
 *                as an interrupt instead of a livelock.
 *   arbitration  among sources that are pending and enabled for this context,
 *                the highest priority wins; equal priorities go to the lowest
 *                ID. If the winner's priority is above the context's threshold,
 *                the external interrupt pin is asserted.
 *   claim/complete  a *read* of the claim register returns the winning ID and
 *                clears its pending bit; a *write* of that ID back releases the
 *                gateway.
 *
 * The claim's read side effect is the crux of the handler. It is what lets the
 * handler return while the device is still asserting: pending is clear, so the
 * pin drops, so the hart is not immediately re-interrupted - and yet the request
 * is not lost, because the gateway stays shut until the completion.
 *
 * A "context" is one privilege mode on one hart. This SoC has two: context 0 is
 * hart 0 in M-mode, which is the one wired up; context 1 is hart 0 in S-mode,
 * present in the register file and connected to nothing until S-mode exists.
 *
 * Only the base address is per-platform, and on a real system it comes from the
 * device tree. The offsets are fixed by the specification, which is what makes
 * one driver work everywhere.
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

#define PLIC_CTX_M0     0u          /* hart 0, machine mode */
#define PLIC_CTX_S0     1u          /* hart 0, supervisor mode - not wired yet */

/* Which source each device sits on. Must agree with RTL/bus/wb_defines.vh. */
#define PLIC_SRC_UART   1u
#define PLIC_SRC_SW(n)  (2u + (n))  /* the GPIO block's SWIRQ bits, 0..3 */
#define PLIC_SW_LINES   4u

#define PLIC_MAX_PRIO   7u

static inline void plic_set_priority(unsigned id, uint32_t prio)
{
    mmio_w32(PLIC_PRIORITY(id), prio);
}

/* Priority 0 is not a low priority - it disables the source outright. */
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

/*
 * Sources whose priority is *at or below* the threshold are not reported to
 * this context. Zero therefore lets everything with a non-zero priority
 * through, which is the usual setting.
 */
static inline void plic_set_threshold(unsigned ctx, uint32_t t)
{
    mmio_w32(PLIC_THRESHOLD(ctx), t);
}

/* Read: returns the winning source ID and clears its pending bit. 0 = none. */
static inline uint32_t plic_claim(unsigned ctx)
{
    return mmio_r32(PLIC_CLAIM(ctx));
}

/* Write: releases that source's gateway so it can request again. */
static inline void plic_complete(unsigned ctx, uint32_t id)
{
    mmio_w32(PLIC_CLAIM(ctx), id);
}

/* Software-driven interrupt lines in the GPIO block, for testing the path. */
static inline void plic_swirq_set(uint32_t mask)
{
    mmio_w32(GPIO_SWIRQ, mask);
}

static inline uint32_t plic_swirq_get(void)
{
    return mmio_r32(GPIO_SWIRQ);
}

#endif
