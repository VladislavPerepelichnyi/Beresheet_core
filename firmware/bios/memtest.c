/*
 * SDRAM test. Four passes, address faults first so that a wiring fault is not
 * reported as a data mismatch:
 *
 *   1. walking ones      each address line on its own; a stuck or swapped line
 *                        makes one location alias onto another
 *   2. address in word   each word holds its own address, catching aliasing
 *                        anywhere, not just at power-of-two offsets
 *   3. data patterns     all zeros, all ones, alternating bits and nibbles, for
 *                        stuck and coupled data bits
 *   4. byte strobes      byte and halfword stores must leave the other lanes of
 *                        the word unchanged
 *
 * All accesses are volatile, so every store and load reaches the bus.
 */
#include "soc.h"
#include "uart.h"
#include "memtest.h"

#define WORDS (SDRAM_SIZE / 4u)

static void fail(const char *what, uint32_t addr, uint32_t expect, uint32_t got)
{
    uart_puts("\n  FAIL ");
    uart_puts(what);
    uart_puts(" at 0x");
    uart_puthex(addr, 8);
    uart_puts(": expected 0x");
    uart_puthex(expect, 8);
    uart_puts(" got 0x");
    uart_puthex(got, 8);
    uart_puts("\n");
}

/* Pass 1: walking ones over the address lines. */
static int test_addr_lines(void)
{
    volatile uint32_t *base = (volatile uint32_t *)SDRAM_BASE;
    uint32_t off, got;
    int errors = 0;

    /* Seed every power-of-two offset with a distinct value. */
    base[0] = 0xA5A5F00Du;
    for (off = 1u; off < WORDS; off <<= 1)
        base[off] = off;

    /* Offset 0 must still hold its seed: if it changed, some address line is
     * stuck and a later write landed on top of it. */
    got = base[0];
    if (got != 0xA5A5F00Du) {
        fail("address line stuck", SDRAM_BASE, 0xA5A5F00Du, got);
        errors++;
    }

    for (off = 1u; off < WORDS; off <<= 1) {
        got = base[off];
        if (got != off) {
            fail("address line", SDRAM_BASE + off * 4u, off, got);
            if (++errors > 8)
                return errors;
        }
    }
    return errors;
}

/* Pass 2: write each word's own address, then read it all back. `stride`
 * words apart: 1 on hardware, larger in simulation. */
static int test_addr_in_addr(uint32_t stride)
{
    volatile uint32_t *base = (volatile uint32_t *)SDRAM_BASE;
    uint32_t i, got;
    int errors = 0;

    for (i = 0; i < WORDS; i += stride)
        base[i] = SDRAM_BASE + i * 4u;

    for (i = 0; i < WORDS; i += stride) {
        got = base[i];
        if (got != SDRAM_BASE + i * 4u) {
            fail("address in address", SDRAM_BASE + i * 4u,
                 SDRAM_BASE + i * 4u, got);
            if (++errors > 8)
                return errors;
        }
    }
    return errors;
}

/* Pass 3: fill with a pattern, verify, for each of several patterns. */
static int test_patterns(uint32_t stride)
{
    static const uint32_t pat[] = {
        0x00000000u, 0xFFFFFFFFu, 0xAAAAAAAAu, 0x55555555u, 0x0F0F0F0Fu
    };
    volatile uint32_t *base = (volatile uint32_t *)SDRAM_BASE;
    uint32_t i, p, got;
    int errors = 0;

    for (p = 0; p < sizeof(pat) / sizeof(pat[0]); p++) {
        for (i = 0; i < WORDS; i += stride)
            base[i] = pat[p];

        for (i = 0; i < WORDS; i += stride) {
            got = base[i];
            if (got != pat[p]) {
                fail("pattern", SDRAM_BASE + i * 4u, pat[p], got);
                if (++errors > 8)
                    return errors;
            }
        }
        uart_putc('.');
    }
    return errors;
}

/*
 * Pass 4: byte and halfword stores must not disturb neighbouring bytes. A
 * controller that ignored the byte mask would pass 1 to 3 and fail only here.
 */
static int test_byte_strobes(void)
{
    volatile uint32_t *w = (volatile uint32_t *)SDRAM_BASE;
    volatile uint8_t  *b = (volatile uint8_t  *)SDRAM_BASE;
    volatile uint16_t *h = (volatile uint16_t *)SDRAM_BASE;
    uint32_t got;
    int errors = 0;

    /* Byte lanes, one at a time, into a known word. */
    w[0] = 0xFFFFFFFFu;
    b[0] = 0x11u;
    got = w[0];
    if (got != 0xFFFFFF11u) { fail("sb lane 0", SDRAM_BASE, 0xFFFFFF11u, got); errors++; }

    b[1] = 0x22u;
    got = w[0];
    if (got != 0xFFFF2211u) { fail("sb lane 1", SDRAM_BASE, 0xFFFF2211u, got); errors++; }

    b[2] = 0x33u;
    got = w[0];
    if (got != 0xFF332211u) { fail("sb lane 2", SDRAM_BASE, 0xFF332211u, got); errors++; }

    b[3] = 0x44u;
    got = w[0];
    if (got != 0x44332211u) { fail("sb lane 3", SDRAM_BASE, 0x44332211u, got); errors++; }

    /* Halfwords, both lanes. */
    w[1] = 0x00000000u;
    h[2] = 0xBEEFu;                     /* halfword index 2 == word 1, low half */
    got = w[1];
    if (got != 0x0000BEEFu) { fail("sh low",  SDRAM_BASE + 4u, 0x0000BEEFu, got); errors++; }

    h[3] = 0xDEADu;
    got = w[1];
    if (got != 0xDEADBEEFu) { fail("sh high", SDRAM_BASE + 4u, 0xDEADBEEFu, got); errors++; }

    /* Sub-word reads must extend correctly out of SDRAM too. */
    if (b[4] != 0xEFu) { fail("lb", SDRAM_BASE + 4u, 0xEFu, b[4]); errors++; }
    if (h[3] != 0xDEADu) { fail("lh", SDRAM_BASE + 6u, 0xDEADu, h[3]); errors++; }

    return errors;
}

int memtest_run(uint32_t stride)
{
    int errors = 0;

    uart_puts("  [1/4] address lines      ");
    errors += test_addr_lines();
    uart_puts(errors ? "FAILED\n" : "ok\n");

    uart_puts("  [2/4] address in address ");
    errors += test_addr_in_addr(stride);
    uart_puts(errors ? "FAILED\n" : "ok\n");

    uart_puts("  [3/4] data patterns      ");
    errors += test_patterns(stride);
    uart_puts(errors ? " FAILED\n" : " ok\n");

    uart_puts("  [4/4] byte strobes       ");
    errors += test_byte_strobes();
    uart_puts(errors ? "FAILED\n" : "ok\n");

    return errors;
}
