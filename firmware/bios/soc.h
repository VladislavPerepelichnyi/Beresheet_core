/*
 * SoC memory map, build-time parameters and 16550 register definitions.
 *
 * The addresses must agree with RTL/bus/wb_defines.vh. Linux and OpenSBI learn
 * them from the device tree; only the BIOS has them compiled in.
 */
#ifndef SOC_H
#define SOC_H

#include <stdint.h>

#define BOOT_BASE   0x00000000u
#define BOOT_SIZE   (32u * 1024u)

/* Base addresses are platform choices; the register offsets inside the CLINT
 * and the PLIC are fixed by their specifications (see clint.h and plic.h). */
#define CLINT_BASE  0x02000000u
#define PLIC_BASE   0x0C000000u
#define UART_BASE   0x10000000u

/* LED PWM block, RTL/peripherals/gpio/led_pwm_wb.v. */
#define LED_BASE    0x11000000u

/* Software-driven interrupt lines in the LED block. Each bit feeds one PLIC
 * source, so the interrupt path can be tested without a real device. */
#define GPIO_SWIRQ  (LED_BASE + 0x20u)

/* SD card controller in SPI mode; see sdcard.c. */
#define SD_BASE     0x12000000u

#define SDRAM_BASE  0x80000000u
#define SDRAM_SIZE  (8u * 1024u * 1024u)

/*
 * Scratch area for the SDRAM self tests (atomics, Zifencei, Sv32): the start of
 * the second 4 MiB megapage, which the MMU test aliases as a whole. Those tests
 * are compiled out of BOOT_ENTRY builds, where SDRAM holds preloaded images.
 */
#define SDRAM_SCRATCH (SDRAM_BASE + 0x00400000u)

/* An address no slave decodes, used to check that the bus terminates the access
 * instead of hanging. */
#define UNMAPPED    0x40000000u

/*
 * Build-time parameters. The Makefile passes all of them; the defaults match
 * the hardware build and exist for a hand compile.
 */

/* Bus clock in Hz. Sets the UART divisor, the SD clock and the startup delay,
 * so it must match the bitstream or the console is garbled. */
#ifndef CPU_HZ
#define CPU_HZ      24000000u
#endif

/* Console baud rate. Simulation uses 1500000 (divisor 1 at 24 MHz) because the
 * testbench decodes the serial line at the real bit rate. */
#ifndef BAUD
#define BAUD        38400u
#endif

/* Delay before the first output, so a terminal opened right after programming
 * the FPGA sees the whole log. Zero in simulation. */
#ifndef STARTUP_DELAY_MS
#define STARTUP_DELAY_MS 1500u
#endif

/* SDRAM test stride in words: 1 tests every word, larger values sample. */
#ifndef MEMTEST_STRIDE
#define MEMTEST_STRIDE 1u
#endif

/* 16550 registers. The UART is byte addressed: register N is at UART_BASE + N. */
#define UART_RBR    0u   /* read: received byte              */
#define UART_THR    0u   /* write: byte to transmit          */
#define UART_DLL    0u   /* divisor low, when DLAB = 1       */
#define UART_IER    1u
#define UART_DLM    1u   /* divisor high, when DLAB = 1      */
#define UART_IIR    2u
#define UART_FCR    2u
#define UART_LCR    3u
#define UART_MCR    4u
#define UART_LSR    5u
#define UART_MSR    6u
#define UART_SCR    7u

#define LCR_8N1     0x03u   /* 8 data bits, no parity, 1 stop bit */
#define LCR_DLAB    0x80u   /* divisor latch access              */

#define FCR_ENABLE  0x01u
#define FCR_CLR_RX  0x02u
#define FCR_CLR_TX  0x04u

#define IER_RX_RDY  0x01u   /* interrupt when a byte arrives          */
#define IER_THR_E   0x02u   /* interrupt when the transmitter is free */

#define MCR_LOOPBACK 0x10u  /* tie TX back to RX inside the UART */

#define LSR_RX_RDY  0x01u   /* a byte is waiting               */
#define LSR_THR_E   0x20u   /* transmit holding register empty */
#define LSR_TX_IDLE 0x40u   /* transmitter completely drained  */

static inline void     mmio_w8 (uint32_t a, uint8_t v)  { *(volatile uint8_t  *)a = v; }
static inline uint8_t  mmio_r8 (uint32_t a)             { return *(volatile uint8_t  *)a; }
static inline void     mmio_w32(uint32_t a, uint32_t v) { *(volatile uint32_t *)a = v; }
static inline uint32_t mmio_r32(uint32_t a)             { return *(volatile uint32_t *)a; }

#endif
