/* Machine-mode trap handler state, shared with the self tests in main.c. */
#ifndef TRAP_H
#define TRAP_H

#include <stdint.h>

extern volatile uint32_t trap_count;
extern volatile uint32_t trap_resume;
extern volatile uint32_t timer_ticks;
extern volatile uint32_t last_cause;
extern volatile uint32_t last_epc;
extern volatile uint32_t last_tval;
extern volatile uint32_t plic_irq_count;
extern volatile uint32_t last_plic_id;
extern volatile uint32_t timer_period_us;
extern volatile int      led_animate;

/* Called from trap_entry in crt0.S; returns the address to resume at. */
uint32_t trap_handler(uint32_t cause, uint32_t epc, uint32_t tval);

#endif
