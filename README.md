# Beresheet

**Beresheet** is a RISC-V processor core and a small system-on-chip (SoC) built around it. It is
written in Verilog and runs on a low-cost FPGA board. It is complete enough to boot
**Linux 6.9** and give you an interactive BusyBox shell, both in simulation and on the real
board.

```
custom-riscv:/ # uname -a
Linux custom-riscv 6.9.0 #15 Wed Nov  4 21:40:37 IST 2026 riscv32 GNU/Linux
```

> **Status:** working, but not yet polished for teaching. The RTL is commented.
> The build system, tests and documentation still need cleanup (see [Known gaps](#known-gaps)).

---

## The processor core

| | |
|---|---|
| ISA | **RV32IMA**, plus Zicsr, Zicntr and Zifencei |
| Privilege modes | Machine, Supervisor, User |
| Virtual memory | **Sv32**: a hardware page-table walker, separate instruction and data TLBs, and SUM/MXR permission checks |
| Pipeline | 3 stages: Fetch → Decode/Execute → Memory/Writeback, with forwarding and a branch target buffer |
| Caches | I-cache and D-cache, each 4 KB, 4-way, 64-byte lines, virtually indexed/physically tagged (VIPT), pseudo-LRU replacement. The D-cache is write-back and write-allocate |
| M extension | Multi-cycle multiplier and divider |
| A extension | LR/SC and all AMO instructions |
| Traps | Precise exceptions, interrupt delegation (`medeleg`/`mideleg`), timer, software and external interrupts |

All core sources are in `RTL/core/`. `riscv_core.v` is the top level of the core.

## The SoC

The core is a Wishbone master. A shared Wishbone B4 (classic) interconnect connects it to
these devices:

| Address | Device | Purpose |
|---|---|---|
| `0x0000_0000` | Boot RAM (32 KB) | BIOS, preloaded into the bitstream |
| `0x0200_0000` | CLINT | `mtime`/`mtimecmp` timer and software interrupt (ACLINT layout) |
| `0x0C00_0000` | PLIC | External interrupt controller, M- and S-mode contexts |
| `0x1000_0000` | UART 16550 | Console, 38400 8N1 on the board |
| `0x1100_0000` | LED PWM | The board's six LEDs |
| `0x1200_0000` | SD card (SPI) | The boot medium |
| `0x8000_0000` | SDRAM, 8 MB | Main memory |

**Boot flow:**

1. The BIOS (`firmware/bios/`, bare-metal C) runs a memory test.
2. It reads `BOOT.TXT` from a FAT32 SD card and loads the Linux `Image`, the initramfs, the
   device tree and OpenSBI into SDRAM.
3. It jumps to OpenSBI in M-mode.
4. OpenSBI starts Linux in S-mode.
5. Linux runs BusyBox in U-mode.

## The platform

- **Board:** Sipeed **Tang Nano 20K**, with a Gowin GW2AR-18 FPGA and 8 MB of SDRAM in the same
  package.
- **Clock:** 24 MHz system clock, from the 27 MHz crystal through the on-chip PLL.
- **Resources used:** about 60% of the logic (12.3 k of 20.7 k) and 42% of the registers.
- **Console:** the board's USB serial port (`/dev/ttyUSB1`, 38400 baud).
- **Simulation:** the same SoC runs cycle-accurately in Verilator, with behavioural models of
  the SDRAM and the SD card. The full Linux boot works in simulation, which is where most
  debugging happened.

## Prerequisites

The project was developed on Ubuntu 24.04. The versions below are the ones it was tested with.

| Tool | Version | Used for |
|---|---|---|
| GNU Make, Python 3, git | any recent | Build system and helper scripts |
| [Verilator](https://verilator.org) | 5.020 | All simulation and lint |
| GTKWave | any | Viewing waveforms (optional) |
| `riscv64-unknown-elf-gcc` | 13.2 | Tests and BIOS (`apt install gcc-riscv64-unknown-elf`) |
| Device-tree compiler `dtc` | 1.7 | Device tree |
| [Buildroot](https://buildroot.org) | 2026.02 | RV32 musl toolchain, Linux 6.9 and BusyBox (config in `firmware/linux/`) |
| [OpenSBI](https://github.com/riscv-software-src/opensbi) | upstream, cloned by `make opensbi` | M-mode firmware |
| [Gowin EDA](https://www.gowinsemi.com) | 1.9.11 Education | Synthesis and place-and-route (only needed for the board) |
| [openFPGALoader](https://github.com/trabucayre/openFPGALoader) | 0.12 | Programming the board |
| `tio` or `minicom` | any | Interactive serial console |

**Note:** the Gowin and Buildroot locations are set in the `Makefile`, as `GOWIN_HOME` and
`BUILDROOT`. Their defaults are paths under `~/Electronics_tools/`. Override them on the
command line, for example `make fpga GOWIN_HOME=/opt/gowin/IDE`.

## Quick start

```sh
make help              # all targets
make test              # core regression: ISA, traps, CSR, MMU, atomics, interrupts
make soc               # whole SoC in simulation, with the BIOS on the simulated UART
make linux-sim         # boot Linux in simulation (slow: hours of wall-clock time)

make fpga && make prog # build the bitstream and load it onto the board
make sdcard            # stage the boot files for a FAT32 SD card
tio -b 38400 /dev/ttyUSB1
```

Every generated file goes under `build/`.

## Repository layout

```
RTL/core/          the processor: pipeline, CSRs, MMU, caches, mul/div
RTL/bus/           Wishbone interconnect, arbiter, core-to-bus bridge, boot RAM
RTL/soc/           soc_wb.v: the SoC top level
RTL/peripherals/   CLINT, PLIC, UART, SD card, SDRAM, LED PWM
RTL/fpga/          Tang Nano 20K top level, pin constraints, timing constraints, PLL, Gowin build script
RTL/sim/           testbenches, SDRAM and SD-card models, unit tests
tests/rv32i/       assembly test suite (20 functional tests and 6 trap tests)
firmware/bios/     bare-metal BIOS: UART, memory test, SD/FAT32 loader, trap handler
firmware/dts/      device trees
firmware/linux/    kernel config, Buildroot defconfig, BusyBox fragment, initramfs files
scripts/           image builders, boot-map checker, mutation testers, profiling
```

## What is original and what is borrowed

### Developed from scratch for this project

- **The whole processor core** (`RTL/core/`): pipeline, hazard and forwarding logic, decoder,
  ALU, branch unit, multiplier and divider, CSR unit and trap logic, atomics, the Sv32 MMU and
  TLBs, and the instruction and data caches.
- **The Wishbone fabric** (`RTL/bus/`) and the **SoC integration** (`RTL/soc/`).
- **CLINT** and **LED PWM** peripherals.
- **The Wishbone wrappers** around the borrowed SD-card and SDRAM controllers (`sdspi_wb.v`,
  `sdram_wb.v`). These include converting classic Wishbone to pipelined Wishbone and the SDRAM
  refresh timer.
- **The simulation environment:** every testbench, the SDRAM and SD-card behavioural models,
  the assembly test suite and the mutation-testing scripts.
- **The BIOS** (`firmware/bios/`): start-up code, UART driver, memory test, SD-card driver,
  FAT32 reader, boot loader and trap handler.
- **The device trees** and the **Linux, Buildroot and BusyBox configuration** for this SoC.
- The **Tang Nano 20K top level**, the constraints and the build scripts.

### Borrowed or adapted

| Component | Origin | License | What changed |
|---|---|---|---|
| UART 16550 (`RTL/peripherals/uart16550/`) | OpenCores `uart16550` | LGPL-2.1 | One define (`LITLE_ENDIAN`) so the registers sit at the right addresses for a little-endian CPU. See the README in that folder. |
| SD-card SPI controller (`RTL/peripherals/sdcard/` except `sdspi_wb.v`) | [ZipCPU/sdspi](https://github.com/ZipCPU/sdspi), Dan Gisselquist | **GPL-3.0** | Unmodified. A small `nettype_restore.v` shim was added for the Gowin tools. |
| SDRAM controller (`sdram_core.v`) | [nand2mario/sdram-tang-nano-20k](https://github.com/nand2mario/sdram-tang-nano-20k) (used in NESTang) | Apache-2.0 | The write port was widened from 8 bits to 32 bits with a byte mask, so one store takes 1 transaction instead of 4. All SDRAM timing is unchanged. |
| PLIC (`plic_wb.v`) | Derived from an existing AXI4-Lite PLIC | *(to be credited)* | Rewritten for Wishbone. Changes: claim/complete handling, read-only pending bits, parameterised decode, and gateway behaviour corrected to the specification. |
| PLL wrapper (`gowin_rpll.v`) | Generated by Gowin's IP tool. The divider and phase values come from nand2mario's design | Gowin | None |
| OpenSBI, Linux, BusyBox, Buildroot | Upstream projects, fetched at build time and not stored in this repository | BSD-2 / GPL-2.0 | Configuration only |

**Licensing note:** the project's own code is MIT (see `LICENSE`). The third-party files keep
their original licenses, which are given in each file's header. The SD-card controller is
GPL-3.0, so a bitstream that includes it is covered by the GPL.

## Known gaps

- Comments in some files point to an original copy of the third-party code (for example
  `RTL/perepherical_reference/`), or to `doc/` and `drafts/` folders, so the changes can be
  checked with a diff. None of these folders is in this repository.
- Makefile messages and some file headers still use the old working name, `custom_riscv`.
- Tool paths are set for one specific machine, and OpenSBI is not pinned to a fixed version.
- Timing: the design meets 24 MHz but not the stricter 27 MHz constraint in the SDC file.
- One known race in the arbiter between the ITLB and DTLB page-table walkers remains
  unresolved.
