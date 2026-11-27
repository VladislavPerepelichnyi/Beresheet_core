`ifndef WB_DEFINES_VH
`define WB_DEFINES_VH

// =============================================================================
// Wishbone bus parameters and the SoC memory map.
//
// The bus is Wishbone B4 "classic standard" single read/write (spec 3.2): one
// STB per transfer, terminated by ACK or ERR; no block cycles, tags or
// pipelining. Addresses are byte addresses with bits 1:0 always zero; byte
// lanes are selected by SEL.
//
// Build-time configuration comes from soc_config.vh, which the build generates
// into a directory on the include path:
//
//   `define SOC_CLK_HZ <hz>    system clock in Hz (required)
//   `define BOARD_<NAME>       target board, e.g. BOARD_TANGNANO20K
//   `define INCL_PER_<NAME>    optional peripheral, zero or more (see soc_wb.v)
// =============================================================================
`include "soc_config.vh"

`define WB_DATA_WIDTH 32
`define WB_ADDR_WIDTH 32
`define WB_SEL_WIDTH  4

// ---------------------------------------------------------------------------
// Memory map, decoded on addr[31:24] (16 MB regions).
//
//   0x0000_0000  boot RAM, 32 KB      reset vector
//   0x0200_0000  CLINT                ACLINT register layout
//   0x0C00_0000  PLIC                 RISC-V PLIC register layout
//   0x1000_0000  UART 16550
//   0x1100_0000  LED PWM and SWIRQ
//   0x1200_0000  SD card, SPI mode
//   0x1300_0000  Ethernet             reserved, INCL_PER_ETHERNET
//   0x1400_0000  HDMI                 reserved, INCL_PER_HDMI
//   0x1500_0000  USB                  reserved, INCL_PER_USB
//   0x1600_0000  PCIe                 reserved, INCL_PER_PCIE
//   0x8000_0000  SDRAM, 8 MB
//
// Base addresses reach software through the device tree; the register offsets
// inside the CLINT and PLIC are fixed by their specifications. Any address
// outside an implemented region is answered with ERR.
// ---------------------------------------------------------------------------
`define REGION_SEL(a) (a[31:24])

`define REGION_BOOT     8'h00
`define REGION_CLINT    8'h02
`define REGION_PLIC     8'h0C
`define REGION_UART     8'h10
`define REGION_LED      8'h11
`define REGION_SD       8'h12
`define REGION_ETHERNET 8'h13
`define REGION_HDMI     8'h14
`define REGION_USB      8'h15
`define REGION_PCIE     8'h16
`define REGION_SDRAM    8'h80

`define BOOT_BASE_ADDR  32'h0000_0000
`define SDRAM_BASE_ADDR 32'h8000_0000

// Implemented size of each memory and device
`define BOOT_RAM_BYTES  32768     // block RAM
`define SDRAM_BYTES     8388608   // GW2AR-18 in-package 64 Mbit SDRAM
`define LED_CHANNELS    6

// PLIC geometry. Source 0 does not exist, so 8 sources give 7 usable lines.
// Context 0 is hart 0 M-mode, context 1 is hart 0 S-mode.
`define PLIC_SRCS       8
`define PLIC_CTXS       2
`define PLIC_MAX_PRIO   7

// PLIC source numbers; the device tree must use the same assignment.
`define PLIC_SRC_UART   1
`define PLIC_SRC_SW0    2         // first of PLIC_SW_LINES lines driven by SWIRQ
`define PLIC_SW_LINES   4
`define PLIC_SRC_SD     6

`endif
