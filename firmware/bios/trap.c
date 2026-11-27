/*
 * Machine-mode trap handler.
 *
 * trap_entry in crt0.S saves the caller-saved registers and calls
 * trap_handler() with mcause, mepc and mtval; the value returned becomes the
 * new mepc before mret. Interrupts resume at mepc. Exceptions are expected:
 * the self tests raise them on purpose and check the recorded cause, so the
 * handler records it and steps over the faulting instruction.
 */
#include "soc.h"
#include "clint.h"
#include "leds.h"
#include "plic.h"
#include "trap.h"

/* Recorded for the self tests to inspect. */
volatile uint32_t trap_count;
volatile uint32_t timer_ticks;
volatile uint32_t last_cause;
volatile uint32_t last_epc;
volatile uint32_t last_tval;
volatile uint32_t plic_irq_count;
volatile uint32_t last_plic_id;

/*
 * If non-zero, the next exception resumes here instead of at mepc + 4, and in
 * M-mode. Needed where mepc + 4 is unreachable: after an instruction page
 * fault, the next instruction is in the same unmapped page. One-shot.
 */
volatile uint32_t trap_resume;

/* Timer tick period, and whether the tick drives the LED animation. */
volatile uint32_t timer_period_us = 10000u;   /* 100 Hz */
volatile int      led_animate;

/*
 * One step of the LED animation: a phase-shifted triangle wave per channel,
 * squared so the brightness sweep looks even to the eye. Channel 0 is left
 * alone (see leds.h).
 */
static void led_step(void)
{
    static uint32_t phase;
    unsigned ch;

    phase = (phase + 4u) & 0xFFu;

    for (ch = 1; ch < LED_COUNT; ch++) {
        uint32_t p = (phase + ch * (256u / (LED_COUNT - 1))) & 0xFFu;
        uint32_t level = (p < 128u) ? (p * 2u) : ((255u - p) * 2u);
        led_set(ch, (uint8_t)((level * level) >> 8));
    }
}

/*
 * External interrupt: claim, silence the device, complete.
 *
 * The claim clears the source's pending bit, so the PLIC drops the interrupt
 * even while the device still holds its line. The device is silenced before
 * the completion so that the re-armed gateway does not see the line still
 * asserted. A claim of 0 is a spurious interrupt and must not be completed.
 */
static void plic_service(void)
{
    uint32_t id = plic_claim(PLIC_CTX_M0);

    if (id == 0u)
        return;

    plic_irq_count++;
    last_plic_id = id;

    if (id == PLIC_SRC_UART) {
        /* The BIOS polls the UART; an interrupt only comes from the self test,
         * and masking it in the device is what drops the level. */
        mmio_w8(UART_BASE + UART_IER, 0u);
    }
    else if (id >= PLIC_SRC_SW(0) && id < PLIC_SRC_SW(PLIC_SW_LINES)) {
        plic_swirq_set(plic_swirq_get() & ~(1u << (id - PLIC_SRC_SW(0))));
    }

    plic_complete(PLIC_CTX_M0, id);
}

uint32_t trap_handler(uint32_t cause, uint32_t epc, uint32_t tval)
{
    trap_count++;
    last_cause = cause;
    last_epc   = epc;
    last_tval  = tval;

    if (cause & 0x80000000u) {
        /* Interrupt: mepc is the instruction that has not run yet. */
        switch (cause & 0x1Fu) {
        case 7:                             /* machine timer */
            timer_ticks++;
            if (led_animate)
                led_step();
            /* mtip stays asserted until mtimecmp moves past mtime. */
            clint_next_tick(timer_period_us);
            break;

        case 3:                             /* machine software */
            clint_set_soft(0);
            break;

        case 11:                            /* machine external, via the PLIC */
            plic_service();
            break;

        default:
            break;
        }
        return epc;
    }

    /* Exception: resume where a test asked to, in M-mode. */
    if (trap_resume) {
        uint32_t resume = trap_resume;
        trap_resume = 0;
        __asm__ volatile ("csrs mstatus, %0" :: "r"(3u << 11));   /* MPP = M */
        return resume;
    }

    /* Otherwise skip the faulting instruction (no C extension: always 4 bytes). */
    return epc + 4u;
}
