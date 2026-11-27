# 10. Limitations and known issues

Previous: [9. From reset to a shell](09-boot.md) | [Book index](../README.md)

Beresheet is a teaching core that boots Linux, not a product. This chapter
lists, in one place, what it does not implement, where it takes a permitted
shortcut, and the issues known at the time of writing. Each item says where in
the RTL to look.

## 10.1 Not implemented

| Feature | Consequence |
|---|---|
| More than one hart | No multiprocessor support; `mhartid` is always 0. Several simplifications (FENCE as a no-op, a one-word reservation set, ignoring `aq`/`rl`) depend on this |
| C extension (compressed instructions) | Every instruction is 32 bits; a jump or taken branch to an address that is not a multiple of 4 traps with cause 0 |
| F, D (floating point), V (vector) | `mstatus.FS`/`VS`/`SD` read as zero; floating-point instructions are illegal. Linux is built without FPU support |
| PMP (physical memory protection) | No `pmpcfg`/`pmpaddr` CSRs; accessing them is illegal. Machine mode cannot fence off memory from S and U |
| Access-fault exceptions (causes 1, 5, 7) | An access to an unmapped address completes with read data 0 and sets a sticky `bus_error` flag in the bus bridge; it does not trap |
| Vectored `mtvec`/`stvec` | MODE is forced to Direct; all traps enter at the base address |
| Sstc (`stimecmp`) | The supervisor timer is delivered by OpenSBI through `mip.STIP` |
| Hardware A/D-bit updates | The hardware never writes a PTE; A = 0, or a store with D = 0, page-faults and software sets the bit |
| Hardware performance counters, `mcountinhibit` | Only `cycle`, `time` and `instret` exist; `cycle` always counts |
| Big-endian modes | `mstatush` and the UBE/SBE/MBE bits are read-only zero |
| Debug module / JTAG | Only observation pins (`dbg_*`, `retire_*`) for simulation and LEDs |

## 10.2 Permitted simplifications

These are allowed by the specifications, but worth knowing because they cost
performance or differ from what a larger core would do:

- **WFI is a no-op** ([5.7](05-privilege-and-traps.md#57-wfi)); idle loops spin.
- **FENCE, FENCE.TSO and PAUSE are no-ops** ([1.1](01-isa-and-formats.md#11-what-is-implemented)).
  Note that the decoder accepts every `funct3` of the `MISC-MEM` opcode other
  than `001` (FENCE.I) as a no-op, including encodings the specification
  reserves.
- **SFENCE.VMA flushes everything**, ignoring its address and ASID operands;
  the TLBs ignore the G bit ([6.7](06-virtual-memory.md#67-sfencevma-and-satp-writes)).
- **FENCE.I writes back and invalidates the whole data cache** and invalidates
  the whole instruction cache ([7.7](07-caches.md#77-fencei-making-stores-visible-to-fetch)).
- **Physical addresses are 32 bits.** A PTE pointing above 4 GiB page-faults.
- **No return-address stack and no direction predictor**: `JALR` returns are
  predicted from the BTB's last target.
- **No load-use interlock.** Correct, but it leaves the load-to-ALU-to-DTLB
  path as the critical timing path, which limits the clock and the TLB sizes
  ([2.5](02-pipeline.md#25-data-hazards-the-write-through-bypass),
  [6.3](06-virtual-memory.md#63-the-tlb)).
- **Two-cycle cache hits** limit throughput to at most one instruction every
  two cycles ([2.7](02-pipeline.md#27-what-this-means-for-performance)).

## 10.3 Known issues

These were found while writing this book, by reading the RTL. They are listed
so that a reader is not surprised by them; none of them prevents the current
Linux boot.

### AMOs are translated as loads

The data MMU's `req_write` input is driven by the decoder's `mem_we`, which is
set for stores and `SC.W` but not for the AMOs (an AMO's first bus access is a
read, so the decoder raises `mem_re` only). As a result an AMO is
permission-checked as a load:

- an AMO to a page with R = 1 and W = 0 is allowed, and its write half then
  modifies a read-only page. Copy-on-write pages after `fork()` are mapped
  exactly like that, so an AMO from user space to such a page would write the
  shared physical page instead of faulting;
- the D bit is not required, so an AMO can dirty a page without the kernel
  being told;
- a page fault on an AMO reports cause 13 (load) instead of 15 (store/AMO),
  which the privileged specification requires.

The alignment check already treats AMOs correctly (`amo_is_rmw` in
`control_unit.v`); driving `dmmu.req_write` with `ctl_mem_we | amo_is_rmw` (or an
equivalent signal from the decoder) would fix all three points. Look at
`RTL/core/riscv_core.v`, instance `dmmu`, and `RTL/core/MMU.v`, `access_allowed`
and `pf_cause`.

### The BIOS hands off without FENCE.I

`boot_handoff` in `firmware/bios/boot.c` jumps to OpenSBI right after copying
the boot set into SDRAM through the write-back data cache. Up to 4 KB of the
most recently written data may still be dirty in the data cache, and
instruction-cache misses read SDRAM directly. Today this is harmless in
practice: the last file loaded is OpenSBI, and its tail is data, which is read
through the (coherent) data cache. A `fence.i` before the jump would make the
handoff correct regardless of file order or size.

### Stale-operand page walks

While a load in stage 3 is waiting for memory, a load or store behind it in
stage 2 may present an address computed from a stale register value to the
DTLB, which can start a walk for the wrong page. This is harmless: the walk
loses the data port to the older access, it is abandoned as soon as the address
changes, and a fault is only ever reported for the page actually requested. It
does slightly inflate the miss counters and can evict a useful TLB entry.
