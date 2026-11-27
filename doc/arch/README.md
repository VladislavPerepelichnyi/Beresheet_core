# Beresheet: architecture of a small RISC-V computer

This is the architecture book for Beresheet, a hand-written RV32IMA processor and
Wishbone system-on-chip that boots Linux 6.9 on a Tang Nano 20K FPGA board (Gowin
GW2AR-18, 24 MHz, 8 MB SDRAM). It is written for students who already know
digital logic (gates, flip-flops, finite-state machines, a little Verilog) and
want to see how a real processor that runs a real operating system is put
together.

The book has three parts. Read Part I first: the bus and the peripherals are
easier to follow once you know what the core asks of them.

## Part I: The processor core

| Chapter | Topic |
|---|---|
| [0. Overview](core/00-overview.md) | What "RV32IMA Zicsr Zicntr Zifencei, M/S/U, Sv32" means; the block diagram |
| [1. Instructions and formats](core/01-isa-and-formats.md) | The instruction set, the six encodings, decoding and immediate generation |
| [2. The three-stage pipeline](core/02-pipeline.md) | Fetch, Decode/Execute, Memory/Writeback; branch prediction; hazards, stalls and flushes |
| [3. Multiply and divide (M)](core/03-m-extension.md) | The multiplier, the divider, and how a multi-cycle unit holds the pipeline |
| [4. Atomics (A)](core/04-a-extension.md) | LR/SC reservations and the AMO read-modify-write sequencer |
| [5. Privilege, CSRs and traps](core/05-privilege-and-traps.md) | M/S/U modes, the CSR file, exceptions, interrupts, delegation, MRET/SRET |
| [6. Virtual memory (Sv32)](core/06-virtual-memory.md) | Page tables, the page walker, the TLBs, permission checks and page faults |
| [7. Caches](core/07-caches.md) | The 4 KB instruction and data caches, pseudo-LRU, write-back, FENCE.I |
| [8. Counters and timers](core/08-counters-and-timers.md) | cycle, time, instret, and where time comes from |
| [9. From reset to a shell](core/09-boot.md) | BIOS, OpenSBI, Linux and BusyBox, seen from the core |
| [10. Limitations and known issues](core/10-limitations.md) | What the core does not do, and what to watch out for |

The part has its own contents page: [core/README.md](core/README.md).

## Part II: The Wishbone bus

How the two cache ports become bus masters, how the arbiter and the address
decoder work, and what a transfer looks like on the wires:
[bus/README.md](bus/README.md).

## Part III: Peripherals

The boot RAM, SDRAM controller, CLINT, PLIC, UART, SD-card interface and LED
block: [peripherals/README.md](peripherals/README.md).

## Background reading

The book does not re-derive textbook material. Where a section builds on the
basics, it points to:

- S. L. Harris and D. M. Harris, *Digital Design and Computer Architecture,
  RISC-V Edition*, Morgan Kaufmann, 2021. Chapter 6 (architecture: the RISC-V
  instruction set and its encodings), chapter 7 (microarchitecture: single-cycle,
  multicycle and pipelined processors, hazards), chapter 8 (memory systems:
  caches and virtual memory). Cited below as "Harris & Harris".
- *The RISC-V Instruction Set Manual, Volume I: Unprivileged ISA* and *Volume II:
  Privileged Architecture*, RISC-V International. Cited as "the unprivileged
  specification" and "the privileged specification".

## Conventions

- Signal and module names are written in `code` and match the Verilog exactly,
  so you can search for them.
- Addresses are written `0x8000_0000`, with an underscore every four hex digits.
- Every chapter ends with a table that says where the described logic lives in
  the RTL.
- All diagrams are drawn in draw.io. The editable sources are in
  `schematics/core/*.drawio`; the exported SVGs (which also embed the source, so
  they open in draw.io directly) are in `core/figures/`.
