#ifndef UART_H
#define UART_H

#include <stdint.h>

void uart_init(void);
void uart_putc(char c);
void uart_puts(const char *s);
void uart_flush(void);
int  uart_getc_nb(void);              /* -1 when nothing is waiting */
void uart_puthex(uint32_t v, int digits);
void uart_putdec(uint32_t v);

#endif
