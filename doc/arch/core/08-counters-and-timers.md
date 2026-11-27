# 8. Counters and timers

Previous: [7. Caches](07-caches.md) | [Book index](../README.md) | Next: [9. From reset to a shell](09-boot.md)

Software needs to know two different kinds of "how much": how much work the
processor has done (cycles, instructions) and how much real time has passed.
The Zicntr extension provides three read-only counters for that, `cycle`,
`instret` and `time`. This chapter shows where each one comes from.

## 8.1 The three counters

| CSR | Counts | Source | Writable copy |
|---|---|---|---|
| `cycle` / `cycleh` (`0xC00` / `0xC80`) | Clock cycles since reset | `cycle_ctr` in the CSR file | `mcycle` / `mcycleh` (`0xB00` / `0xB80`) |
| `instret` / `instreth` (`0xC02` / `0xC82`) | Instructions retired | `instret_ctr` in the CSR file | `minstret` / `minstreth` (`0xB02` / `0xB82`) |
| `time` / `timeh` (`0xC01` / `0xC81`) | Real time, 1 MHz ticks | The CLINT's `mtime`, wired into the core | none (`mtime` is written through the CLINT's memory map) |

All three are 64 bits wide even on RV32: at 24 MHz a 32-bit cycle counter would
wrap in three minutes. Software reads them in two halves and must cope with a
carry between the two reads; the standard pattern is

```
again:  rdcycleh  t1
        rdcycle   t0
        rdcycleh  t2
        bne       t1, t2, again
```

### cycle

`cycle_ctr` increments on every clock edge. There is no `mcountinhibit`, so it
cannot be stopped; machine mode can write it through `mcycle`/`mcycleh` (one
half at a time). The increment is placed before the CSR write in the same
always block, so a write in the same cycle wins.

### instret

`instret_ctr` increments on `retire_valid`, the one-cycle pulse issued when an
instruction leaves stage 3 ([2.8](02-pipeline.md#28-retirement)). Bubbles do not
count, an instruction held for many cycles by a memory stall counts once, and a
trapping instruction (including `ECALL` and `EBREAK`) never counts, because it
never reaches stage 3.

### time

RISC-V defines the real-time counter `mtime` as a memory-mapped register in the
CLINT, not as a CSR, so that every hart in a multi-hart system sees the same
time. The CLINT divides the 24 MHz clock by 24 to tick `mtime` at exactly
1 MHz, and drives the 64-bit value to the core on the `mtime` input. The `time`
CSR is a read-only *view* of that wire. The device tree tells Linux
`timebase-frequency = <1000000>`. A different system clock would change the
divider (derived from `SOC_CLK_HZ`), not the tick rate. See Part III, [peripherals](../peripherals/README.md), for the CLINT
itself.

## 8.2 Who may read them

The unprivileged names (`cycle`, `time`, `instret`) are readable from every
mode, subject to two enable registers:

| Mode | Access allowed when |
|---|---|
| M | always |
| S | the matching bit is set in `mcounteren` |
| U | the matching bit is set in both `mcounteren` and `scounteren` |

The bits are CY (0), TM (1) and IR (2). A forbidden read is an illegal
instruction. This is what lets the kernel decide whether user programs may
measure time precisely, and why `mcounteren` is mandatory once U-mode exists.
The machine-level names (`mcycle`, `minstret`) are accessible only in M, by the
address encoding.

## 8.3 Timer interrupts

The CLINT also compares `mtime` with `mtimecmp` and drives `irq_timer` (MTIP)
while `mtime >= mtimecmp`. A timer interrupt is cleared by moving `mtimecmp`
into the future; there is nothing to clear in the core. The CLINT's `msip`
register drives `irq_soft` (MSIP) the same way.

Supervisor mode has no timer of its own on this core (no Sstc extension).
Linux programs its next tick with an SBI call; OpenSBI writes `mtimecmp`, takes
the machine timer interrupt when it fires, and passes it on by setting
`mip.STIP`, which the kernel receives as a delegated supervisor timer interrupt
([5.3](05-privilege-and-traps.md#53-interrupt-sources)).

## Where this is in the RTL

| What | File | Names |
|---|---|---|
| Counter registers, increment, writes | `RTL/core/CSR_unit.v` | `cycle_ctr`, `instret_ctr`, `instret`, `mtime` |
| Counter CSR addresses, enable bits | `RTL/core/CSRdefinitions.vh` | `CSR_CYCLE`..`CSR_MINSTRETH`, `CTREN_CY/TM/IR` |
| Access checks | `RTL/core/control_unit.v` | `ctr_is_shared`, `ctr_bit`, `ctr_allowed`, `csr_fault_ctr` |
| Retirement pulse | `RTL/core/riscv_core.v` | `retire_valid` |
| `mtime`, `mtimecmp`, `msip`, prescaler | `RTL/peripherals/clint/clint_wb.v` | `TICK_HZ`, `mtime_o`, `mtip`, `msip` |
| Timebase in the device tree | `firmware/dts/beresheet.dts` | `timebase-frequency` |
