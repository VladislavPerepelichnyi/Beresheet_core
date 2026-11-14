/*
 * Trap handling for the BIOS.
 *
 * The handler is split in two on purpose. trap_entry in crt0.S is the part that
 * has to be assembly - it saves the registers C is allowed to clobber, because
 * an interrupt can arrive between any two instructions and the interrupted code
 * has no idea it happened. trap_handler below is the part that can be C.
 *
 * What the hardware already did before we got here:
 *   mepc   <- the interrupted or faulting instruction
 *   mcause <- why
 *   mtval  <- the useful detail
 *   MPIE   <- MIE, then MIE <- 0     interrupts off, so this cannot re-enter
 *
 * What software must do:
 *   decide whether to re-execute or skip, by adjusting mepc
 *   for a timer interrupt, move mtimecmp forward or it fires again immediately
 *   mret, which restores MIE from MPIE and jumps to mepc
 */
#include "soc.h"
#include "uart.h"
#include "csr.h"
#include "clint.h"
#include "leds.h"
#include "plic.h"
#include "trap.h"

/* Observable state, so main() and the LED animation can see what happened. */
volatile uint32_t trap_count;

/*
 * Where to resume after the next exception, instead of stepping over it.
 *
 * Stepping over a fault only works when the *next* instruction is reachable,
 * and for a page fault it often is not: an instruction page fault means the
 * whole page could not be fetched, so mepc + 4 is in the same unmapped page and
 * the machine faults again forever. The MMU selftest needs to trap from places
 * like that and get back, so it parks a return address here.
 *
 * Self-clearing, and it also forces MPP to M - the trap may have come from
 * S-mode, and the point is to return to the M-mode code that set it up.
 */
volatile uint32_t trap_resume;
volatile uint32_t timer_ticks;
volatile uint32_t last_cause;
volatile uint32_t last_epc;
volatile uint32_t last_tval;

/* External interrupts, so the PLIC self test can see what the handler saw. */
volatile uint32_t plic_irq_count;
volatile uint32_t last_plic_id;

/* Set by main() before enabling interrupts. */
volatile uint32_t timer_period_us = 10000u;   /* 100 Hz */
volatile int      led_animate;

static const char *cause_name(uint32_t cause)
{
    if (cause & 0x80000000u) {
        switch (cause & 0x1Fu) {
        case 3:  return "machine software interrupt";
        case 7:  return "machine timer interrupt";
        case 11: return "machine external interrupt";
        default: return "unknown interrupt";
        }
    }
    switch (cause) {
    case 0:  return "instruction address misaligned";
    case 2:  return "illegal instruction";
    case 3:  return "breakpoint";
    case 4:  return "load address misaligned";
    case 6:  return "store address misaligned";
    case 11: return "environment call from M-mode";
    default: return "unknown exception";
    }
}

void trap_report(void)
{
    uart_puts("  cause : 0x");
    uart_puthex(last_cause, 8);
    uart_puts("  ");
    uart_puts(cause_name(last_cause));
    uart_puts("\n  mepc  : 0x");
    uart_puthex(last_epc, 8);
    uart_puts("   mtval : 0x");
    uart_puthex(last_tval, 8);
    uart_puts("\n");
}

/*
 * Advance the LED animation one step.
 *
 * Five channels, each a triangle wave with a phase offset, so the brightness
 * chases along the row. All of it is integer arithmetic - the point is that the
 * interrupt only runs 100 times a second, and the hardware PWM does the fast
 * work.
 */
static void led_step(void)
{
    static uint32_t phase;
    unsigned ch;

    phase = (phase + 4u) & 0xFFu;

    for (ch = 1; ch < LED_COUNT; ch++) {
        /* Spread the five software channels evenly around the cycle. */
        uint32_t p = (phase + ch * (256u / (LED_COUNT - 1))) & 0xFFu;
        /* Triangle: rise over the first half, fall over the second. */
        uint32_t level = (p < 128u) ? (p * 2u) : ((255u - p) * 2u);
        /*
         * Square it. Perceived brightness is roughly the square root of
         * power, so a linear duty ramp looks like it spends most of its time
         * bright. Squaring first makes the sweep look even.
         */
        led_set(ch, (uint8_t)((level * level) >> 8));
    }
}

/*
 * External interrupt: ask the PLIC who it was, quieten them, tell the PLIC we
 * are done.
 *
 * The claim is what makes returning from here safe. It clears the source's
 * pending bit, so the PLIC stops asserting the pin and the hart is not
 * re-interrupted the instant MIE comes back on - even though the device may
 * still be holding its line high. The request is not lost: the gateway stays
 * shut until the completion below.
 *
 * Quietening comes before completing. Completing first re-arms the gateway
 * against a line that is still asserted, and it then has to wait for the fall,
 * which works but leaves the timing up to the device. This order leaves nothing
 * outstanding.
 *
 * A claim of 0 means nothing was pending after all - a spurious interrupt, which
 * is legal and must not be completed.
 */
static void plic_service(void)
{
    uint32_t id = plic_claim(PLIC_CTX_M0);

    if (id == 0u)
        return;

    plic_irq_count++;
    last_plic_id = id;

    if (id == PLIC_SRC_UART) {
        /*
         * Nothing here consumes UART interrupts in anger; the BIOS polls. So
         * silence the source by masking it in the device, which is the only way
         * to make a level-triggered "transmitter is free" interrupt go away.
         */
        mmio_w8(UART_BASE + UART_IER, 0u);
    }
    else if (id >= PLIC_SRC_SW(0) && id < PLIC_SRC_SW(PLIC_SW_LINES)) {
        plic_swirq_set(plic_swirq_get() & ~(1u << (id - PLIC_SRC_SW(0))));
    }

    plic_complete(PLIC_CTX_M0, id);
}

/*
 * Called from trap_entry with the registers already saved.
 * Returns the address to resume at, which trap_entry writes back to mepc.
 */
uint32_t trap_handler(uint32_t cause, uint32_t epc, uint32_t tval)
{
    trap_count++;
    last_cause = cause;
    last_epc   = epc;
    last_tval  = tval;

    if (cause & 0x80000000u) {
        /*
         * Interrupt. mepc already points at the instruction that has not run,
         * so resume exactly there - adding 4 here would silently skip it.
         */
        switch (cause & 0x1Fu) {
        case 7:                             /* timer */
            timer_ticks++;
            if (led_animate)
                led_step();
            /* Re-arm, or this fires again on the very next cycle. */
            clint_next_tick(timer_period_us);
            break;

        case 3:                             /* software */
            clint_set_soft(0);              /* a latch: clear it at the source */
            break;

        case 11:                            /* external, via the PLIC */
            plic_service();
            break;

        default:
            break;
        }
        return epc;
    }

    /*
     * Exception. mepc points at the faulting instruction, so returning without
     * advancing would re-execute the fault forever. Every cause the BIOS can
     * raise is one to step over; a real OS would decide per cause - a page
     * fault fixes the mapping and re-executes.
     *
     * All instructions are 4 bytes: no compressed extension.
     */
    if (trap_resume) {
        uint32_t resume = trap_resume;
        trap_resume = 0;
        /* MPP = M, so MRET comes back to machine mode however we got here. */
        __asm__ volatile ("csrs mstatus, %0" :: "r"(3u << 11));
        return resume;
    }

    return epc + 4u;
}
