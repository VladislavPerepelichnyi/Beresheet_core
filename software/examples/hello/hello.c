/*
 * Minimal bare-metal program: print over the 16550 UART and exit.
 *
 *   make compile-bin SRC=software/examples/hello/hello.c
 *   make sim  BIN=build/bin/hello.elf
 *
 *   make compile-bin SRC=software/examples/hello/hello.c LINK=sdram
 *   make qemu BIN=build/bin/hello.elf
 *
 * CPU_HZ and BAUD are passed in by the Makefile.
 */

#include <stdint.h>

#define UART_BASE   0x10000000u
#define UART_THR    0u                  /* transmit holding (DLAB = 0) */
#define UART_DLL    0u                  /* divisor low      (DLAB = 1) */
#define UART_DLM    1u                  /* divisor high     (DLAB = 1) */
#define UART_FCR    2u
#define UART_LCR    3u
#define UART_LSR    5u
#define LSR_THRE    0x20u

static inline void reg_write(uint32_t off, uint8_t v)
{
    *(volatile uint8_t *)(UART_BASE + off) = v;
}

static inline uint8_t reg_read(uint32_t off)
{
    return *(volatile uint8_t *)(UART_BASE + off);
}

static void uart_init(void)
{
    uint32_t div = (CPU_HZ + 8u * BAUD) / (16u * BAUD);

    reg_write(UART_LCR, 0x80);          /* DLAB: expose the divisor */
    reg_write(UART_DLL, div & 0xFF);
    reg_write(UART_DLM, (div >> 8) & 0xFF);
    reg_write(UART_LCR, 0x03);          /* 8N1 */
    reg_write(UART_FCR, 0x07);          /* enable and clear the FIFOs */
}

static void uart_putc(char c)
{
    while (!(reg_read(UART_LSR) & LSR_THRE))
        ;
    reg_write(UART_THR, (uint8_t)c);
}

static void uart_puts(const char *s)
{
    for (; *s; s++) {
        if (*s == '\n')
            uart_putc('\r');
        uart_putc(*s);
    }
}

static void uart_puthex(uint32_t v)
{
    for (int i = 28; i >= 0; i -= 4)
        uart_putc("0123456789abcdef"[(v >> i) & 0xF]);
}

/* Wait until the last character has left the shift register. */
static void uart_flush(void)
{
    while (!(reg_read(UART_LSR) & 0x40))
        ;
}

int main(void)
{
    uint32_t misa;

    __asm__ volatile ("csrr %0, misa" : "=r"(misa));

    uart_init();
    uart_puts("Hello from Beresheet!\n");
    uart_puts("misa = 0x");
    uart_puthex(misa);
    uart_puts("\n");
    uart_flush();
    return 0;
}
