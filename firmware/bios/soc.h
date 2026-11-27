/*
 * SoC memory map and register definitions.
 *
 * Must agree with RTL/bus/wb_defines.vh. These addresses are ours to choose:
 * once OpenSBI and Linux are in the picture they learn the layout from the
 * device tree, so nothing here is dictated by the software stack.
 */
#ifndef SOC_H
#define SOC_H

#include <stdint.h>

#define BOOT_BASE   0x00000000u
#define BOOT_SIZE   (32u * 1024u)

/*
 * The CLINT's base is ours to choose - software normally learns it from the
 * device tree - but the register offsets *inside* it are fixed by the ACLINT
 * spec, and those are what every existing driver depends on.
 */
#define CLINT_BASE  0x02000000u

/*
 * Same story as the CLINT: the base is a convention, the offsets inside are
 * specified. See plic.h.
 */
#define PLIC_BASE   0x0C000000u

#define UART_BASE   0x10000000u

/* Our own device. See RTL/peripherals/gpio/led_pwm_wb.v. */
#define LED_BASE    0x11000000u

/*
 * Software-triggered interrupt lines, in the GPIO block rather than in a device
 * of their own. Each bit drives a PLIC source directly, which is how the whole
 * interrupt path can be checked without waiting for a device to misbehave.
 */
#define GPIO_SWIRQ  (LED_BASE + 0x20u)

/*
 * Read-only bring-up word. Reads 0 when nothing has gone wrong; 0xF1F1xxxx
 * means the cache flush watchdog fired and the low half says what the flush
 * sequencer was waiting for. See the watchdog in RTL/soc/soc_wb.v.
 */
#define GPIO_DBG    (LED_BASE + 0x30u)

/* SD card in SPI mode. Four registers; see sdcard.c. */
#define SD_BASE     0x12000000u

#define SDRAM_BASE  0x80000000u
#define SDRAM_SIZE  (8u * 1024u * 1024u)

/*
 * Scratch area for tests that write SDRAM but must not disturb an image loaded
 * there. 4 MB in, which is clear of anything a next-stage firmware occupies:
 * OpenSBI's footprint ends around +0x84000 and its device tree sits at +0x100000.
 *
 * This matters more than it looks. The first handoff attempt corrupted OpenSBI
 * before jumping to it, because the memory test that runs earlier writes
 * patterns across the whole region - including the text and data of the thing
 * about to be executed. It then spun in OpenSBI's wait-for-boot-hart loop, which
 * looks like a broken atomic rather than a clobbered image.
 */
#define SDRAM_SCRATCH (SDRAM_BASE + 0x00400000u)

/* An address in no region at all, used to prove the bus reports an error
 * instead of hanging. */
#define UNMAPPED    0x40000000u

/*
 * The bus clock, and the BIOS's only source for the UART divisor and every
 * millisecond delay. It comes from the Makefile (-DCPU_HZ=...) so that it
 * follows CLK18 automatically; the default here is only for a hand compile.
 *
 * Getting this wrong does not fail loudly. The BIOS computes
 * divisor = CPU_HZ / (16 * BAUD), so a stale 24 MHz on an 18 MHz board picks
 * divisor 39 instead of 29 and transmits at 28846 baud - a garbled console
 * that looks like a dead board rather than a wrong constant.
 */
#ifndef CPU_HZ
#define CPU_HZ      24000000u
#endif

/*
 * Baud rate. Overridable from the build, because simulation transmits at the
 * real bit rate: 400 characters at 38400 baud is 113 ms of simulated time,
 * which dwarfs everything else in the run. The simulation build therefore uses
 * a divisor of 1 - 1.5 Mbaud at a 24 MHz clock - and the hardware build uses
 * 38400. That number moved with the clock: at 27 MHz a divisor of 1 was
 * 1.6875 Mbaud, and asking for it at 24 MHz computes a divisor of zero.
 */
#ifndef BAUD
#define BAUD        38400u
#endif

/*
 * How long to wait before the first output. On hardware this covers the gap
 * between programming the FPGA and a terminal attaching (see uart.c and the
 * `monitor` target). In simulation it must be zero: four million spin
 * iterations dwarf the entire run.
 */
#ifndef STARTUP_DELAY_MS
#define STARTUP_DELAY_MS 1500u
#endif

/*
 * 16550 registers, byte addressed. The UART core is in 32-bit mode, where the
 * register index's low bits come from the byte lane the access selects, so a
 * plain byte access at UART_BASE + N reaches register N.
 */
#define UART_RBR    0u   /* read: received byte                 */
#define UART_THR    0u   /* write: byte to transmit             */
#define UART_DLL    0u   /* divisor low, when DLAB = 1          */
#define UART_IER    1u
#define UART_DLM    1u   /* divisor high, when DLAB = 1         */
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

#define IER_RX_RDY  0x01u   /* interrupt when a byte arrives     */
#define IER_THR_E   0x02u   /* interrupt when the transmitter is free */

#define MCR_LOOPBACK 0x10u  /* tie TX back to RX inside the UART */

#define LSR_RX_RDY  0x01u   /* a byte is waiting                 */
#define LSR_THR_E   0x20u   /* transmit holding register empty   */
#define LSR_TX_IDLE 0x40u   /* transmitter completely drained    */

static inline void     mmio_w8 (uint32_t a, uint8_t v)  { *(volatile uint8_t  *)a = v; }
static inline uint8_t  mmio_r8 (uint32_t a)             { return *(volatile uint8_t  *)a; }
static inline void     mmio_w32(uint32_t a, uint32_t v) { *(volatile uint32_t *)a = v; }
static inline uint32_t mmio_r32(uint32_t a)             { return *(volatile uint32_t *)a; }

#endif
