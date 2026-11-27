# Peripherals and interrupts

The [bus part](../bus/README.md) ends at the slave's Wishbone port. This part
looks inside the slaves that are not memory: the devices that keep time, move
characters, blink lights, read the SD card, and, most importantly, **interrupt**
the processor when something needs attention.

Every device here is a Wishbone slave, reached with ordinary loads and stores
at the addresses in the [memory map](../bus/05-memory-map.md). Several also
drive interrupt wires. Those wires do not use the bus at all; they go to one of
two interrupt controllers, which in turn drive bits of the core's `mip`
register.

| Device | Base | Interrupt output | Goes to |
|--------|------|------------------|---------|
| CLINT | `0x0200_0000` | `mtip` (timer), `msip` (software) | `mip.MTIP` (bit 7), `mip.MSIP` (bit 3) |
| PLIC | `0x0C00_0000` | `eip[0]`, `eip[1]` | `mip.MEIP` (bit 11), `mip.SEIP` (bit 9) |
| UART 16550 | `0x1000_0000` | `int_o` | PLIC source 1 |
| LED PWM (SWIRQ register) | `0x1100_0000` | `swirq[3:0]` | PLIC sources 2 to 5 |
| SD card controller | `0x1200_0000` | `o_int` | PLIC source 6 |
| (none) | | | PLIC source 7 is tied low |

## Chapters

| # | Chapter | What you learn |
|---|---------|----------------|
| 1 | [CLINT: timer and software interrupt](01-clint.md) | `mtime`, `mtimecmp`, `msip`, and why a timer interrupt is cleared by moving the deadline |
| 2 | [PLIC: external interrupts](02-plic.md) | Gateways, priority, enable, threshold, claim and complete, and the two contexts |
| 3 | [UART 16550](03-uart16550.md) | The register map, the baud divisor at 24 MHz, FIFOs, interrupts, and how Linux drives it |
| 4 | [LED PWM and software interrupts](04-led-pwm.md) | The smallest complete device, and a way to fire PLIC interrupts from software |
| 5 | [SD card over SPI](05-sd-card.md) | How the BIOS reads `BOOT.TXT` and the boot files |
| 6 | [The interrupt path, end to end](06-interrupt-path.md) | From a device pin to the first instruction of a trap handler, under bare metal and under Linux |

## Files at a glance

| File | Role |
|------|------|
| `RTL/peripherals/clint/clint_wb.v` | CLINT |
| `RTL/peripherals/plic/plic_wb.v` | PLIC |
| `RTL/peripherals/uart16550/*` | OpenCores 16550 UART (third party, LGPL) and the `uart_wb_slave` wrapper |
| `RTL/peripherals/gpio/led_pwm_wb.v` | LED PWM and SWIRQ |
| `RTL/peripherals/sdcard/*` | ZipCPU `sdspi` SD controller (third party, GPL-3) and the `sdspi_wb` wrapper |
| `RTL/soc/soc_wb.v` | Instances, and the wiring of interrupt sources into the PLIC |
| `firmware/bios/clint.h`, `plic.h`, `uart.c`, `sdcard.c`, `trap.c` | The BIOS drivers, the simplest working software for each device |
