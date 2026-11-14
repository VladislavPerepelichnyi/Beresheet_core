/*
 * LED brightness. Our own MMIO device - one 32-bit register per channel, each
 * holding an 8-bit duty value. The PWM itself is in hardware, so software only
 * has to update brightness at a rate the eye notices rather than at the
 * switching frequency.
 */
#ifndef LEDS_H
#define LEDS_H

#include <stdint.h>
#include "soc.h"

#define LED_COUNT 6

static inline void led_set(unsigned ch, uint8_t duty)
{
    if (ch < LED_COUNT)
        mmio_w32(LED_BASE + 4u * ch, duty);
}

static inline uint8_t led_get(unsigned ch)
{
    return (ch < LED_COUNT) ? (uint8_t)mmio_r32(LED_BASE + 4u * ch) : 0u;
}

#endif
