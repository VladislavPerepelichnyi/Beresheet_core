/*
 * Polled 16550 driver.
 *
 * Polled, not interrupt driven, because the core has no trap mechanism yet -
 * that arrives with Zicsr at roadmap step 6. Every wait here is a spin on a
 * status bit, which is exactly what a boot ROM wants anyway: no state, no
 * handlers, works before anything else is initialised.
 */
#include "soc.h"
#include "uart.h"

void uart_init(void)
{
    /*
     * Baud divisor. The 16550 divides the bus clock by 16 to make its bit
     * clock, so divisor = f_clk / (16 * baud).
     *
     * At 27 MHz and 38400 baud that is 43.95, so 44, giving 38352 baud - an
     * error of -0.13%. Worth noting why 38400 rather than 115200: at 27 MHz
     * the divisor for 115200 would be 14.65, and rounding to 15 gives -2.3%
     * error, close enough to the limit that a marginal link would be the first
     * thing to suspect when the board says nothing. 38400 removes that doubt,
     * and the serial link is the only debug channel we have.
     */
    const uint32_t divisor = CPU_HZ / (16u * BAUD);

    mmio_w8(UART_BASE + UART_LCR, LCR_DLAB);          /* expose the divisor  */
    mmio_w8(UART_BASE + UART_DLL, divisor & 0xFFu);
    mmio_w8(UART_BASE + UART_DLM, (divisor >> 8) & 0xFFu);
    mmio_w8(UART_BASE + UART_LCR, LCR_8N1);           /* 8N1, hide divisor   */
    mmio_w8(UART_BASE + UART_FCR, FCR_ENABLE | FCR_CLR_RX | FCR_CLR_TX);
    mmio_w8(UART_BASE + UART_IER, 0x00u);             /* no interrupts       */
}

void uart_putc(char c)
{
    while (!(mmio_r8(UART_BASE + UART_LSR) & LSR_THR_E))
        ;
    mmio_w8(UART_BASE + UART_THR, (uint8_t)c);
}

void uart_puts(const char *s)
{
    while (*s) {
        if (*s == '\n')
            uart_putc('\r');        /* terminals want CR LF */
        uart_putc(*s++);
    }
}

void uart_flush(void)
{
    while (!(mmio_r8(UART_BASE + UART_LSR) & LSR_TX_IDLE))
        ;
}

int uart_getc_nb(void)
{
    if (mmio_r8(UART_BASE + UART_LSR) & LSR_RX_RDY)
        return (int)mmio_r8(UART_BASE + UART_RBR);
    return -1;
}

void uart_puthex(uint32_t v, int digits)
{
    static const char hex[] = "0123456789ABCDEF";
    int i;
    for (i = digits - 1; i >= 0; i--)
        uart_putc(hex[(v >> (i * 4)) & 0xFu]);
}

void uart_putdec(uint32_t v)
{
    char buf[11];
    int n = 0;

    if (v == 0) {
        uart_putc('0');
        return;
    }
    while (v > 0) {
        buf[n++] = (char)('0' + (v % 10u));   /* uses RV32M divide */
        v /= 10u;
    }
    while (n-- > 0)
        uart_putc(buf[n]);
}
