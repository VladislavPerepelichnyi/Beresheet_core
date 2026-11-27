# 4. Atomics (the A extension)

Previous: [3. Multiply and divide](03-m-extension.md) | [Book index](../README.md) | Next: [5. Privilege, CSRs and traps](05-privilege-and-traps.md)

Operating systems need a few memory operations that cannot be interrupted
half-way: taking a lock, incrementing a shared counter, swapping a pointer.
The A extension provides two families of them, and Linux uses both:

- **LR/SC** (load-reserved / store-conditional): `LR.W` loads a word and places
  a *reservation* on its address; a later `SC.W` to the same address stores
  only if the reservation is still intact, and writes 0 to `rd` on success or
  non-zero on failure. Software retries in a loop.
- **AMOs** (atomic memory operations): `AMOSWAP`, `AMOADD`, `AMOXOR`, `AMOAND`,
  `AMOOR`, `AMOMIN`, `AMOMAX`, `AMOMINU`, `AMOMAXU`. Each reads a word, combines
  it with `rs2`, writes the result back, and returns the *old* value in `rd`,
  as one indivisible operation.

Only the word (`.W`) forms exist on RV32. All of them address memory with `rs1`
alone (no offset), which is why the decoder selects the zero immediate
`IMM_Z` ([1.2](01-isa-and-formats.md#12-the-six-encodings)).

## 4.1 Where atomics are executed

An atomic is a read-modify-write of memory, so it has to be sequenced next to
the memory port, in stage 3 (`mem_wb`). Stage 2 only decodes it, computes the
address (`rs1 + 0`), translates it, and checks alignment.

The sequencing uses a pattern you have already seen: a multi-cycle operation
with the rest of the pipeline frozen around it. Here the freeze is free:
`mem_stall` already stops every stage while stage 3 is busy, and everything
that must stay out of the way (trap entry, interrupts, the M unit) already
waits for `mem_stall` to fall.

## 4.2 The reservation

There is one reservation register: a valid bit and a word address
(`resv_valid`, `resv_addr` = address bits 31:2). The *reservation set* is
therefore exactly one aligned word, the smallest the specification allows.

| Event | Effect on the reservation |
|---|---|
| `LR.W` completes | Set: valid, address = this word |
| `SC.W` completes, success or failure | Cleared |
| Any store or AMO write to the reserved word | Cleared |
| A trap is taken | Cleared |

The last two are not required on a single-hart machine (only *another* hart's
store must break a reservation, and the specification leaves context switches
to software), but each costs almost nothing and removes a class of hard-to-find
bugs, such as a preempted LR/SC sequence resuming into a successful SC.

## 4.3 The sequencer

The sequencer has two phases, `AM_ARM` and `AM_WRITE`. `LR.W` does not use it:
it is an ordinary load that also sets the reservation.

| Instruction | `AM_ARM` | `AM_WRITE` | `rd` receives |
|---|---|---|---|
| `SC.W` | No bus access. Compare the reservation with this word; register the verdict in `sc_go_q` | If `sc_go_q`: write the word, finish on `ready`. Otherwise finish at once, with no bus access at all | 0 on success, 1 on failure |
| AMO | Read the word with `dmem_lock = 1`. On `ready`: latch the old value in `amo_old` and the new value in `amo_wdata` | Write `amo_wdata` with `dmem_lock = 0`; finish on `ready` | The old value, `amo_old` |

For the whole sequence `mem_stall` stays high, so the read's acknowledge does
not release the pipeline with the write still to do.

The two-phase shape is there for **timing**, not correctness. An earlier
version checked the reservation and issued the SC's write in the same cycle,
which put a 30-bit comparator in front of the bus write enable and through the
whole bus path. Registering the verdict costs one cycle on a rare instruction
that already sits inside a retry loop. For the same reason the AMO result is
computed from the read data *as it arrives* and registered, rather than
computed later from `amo_old`.

The AMO operations themselves are a small multiplexer on `amo_funct5`:
`swap` returns `rs2`, `add`/`xor`/`and`/`or` combine, and the four min/max
variants compare signed or unsigned.

### Indivisibility: the bus lock

What makes the read and write of an AMO *one* operation rather than two
consecutive ones is that nothing else can reach memory in between. Through the
data cache, a cacheable AMO hits (or is filled into) the cache and both halves
happen inside it; the only other bus master is instruction fetch, which never
writes. For an *uncached* address (a device register), the read and write go
out on the bus as two transfers, and `dmem_lock` asks the bridge and arbiter to
keep the bus granted to the data port in between (Wishbone `LOCK`, see Part II,
[the bus](../bus/README.md)). The lock is raised for the read and dropped for
the write: on the last transfer the master must release it, or the arbiter
would keep the bus for a master that no longer wants it.

## 4.4 Ordering bits `aq` and `rl`

Bits 26 and 25 of an atomic request acquire and release ordering. They are
accepted and ignored. A single in-order hart that performs one memory access at
a time, with no store buffer, already provides every ordering those bits can
ask for. They must not raise an illegal instruction, because that is how real
code is compiled: `amoswap.w.aq` is what a lock acquire looks like.

## 4.5 Exceptions

- **Alignment.** All atomics are word accesses. A misaligned `LR.W` reports a
  *load* address misaligned (cause 4). A misaligned `SC.W` or AMO reports a
  *store/AMO* address misaligned (cause 6), because the privileged
  specification classifies an AMO as a store for that purpose. (The decoder
  raises `mem_we` for SC and uses `amo_is_rmw` for AMOs to get this right.)
- **Page faults.** Translation happens in stage 2 like any load or store
  ([chapter 6](06-virtual-memory.md)). `LR.W` is checked as a load and `SC.W` as
  a store. AMOs are currently translated as *loads*; see
  [chapter 10](10-limitations.md#103-known-issues) for why that is a known issue.

## Where this is in the RTL

| What | File | Names |
|---|---|---|
| `funct5` codes and the note on `aq`/`rl` | `RTL/core/definitions.vh` | `F5_LR`, `F5_SC`, `F5_AMO*` |
| Decode, legality, alignment cause | `RTL/core/control_unit.v` | `OPC_AMO` case, `amo_is_rmw`, `store_misaligned` |
| Reservation, sequencer, AMO ALU, lock | `RTL/core/mem_wb.v` | `resv_valid`, `resv_addr`, `am_state`, `AM_ARM`, `AM_WRITE`, `sc_go_q`, `amo_old`, `amo_wdata`, `amo_result`, `dmem_lock` |
| Lock passed to the bus only for uncached transfers | `RTL/core/cache.v` | `mem_lock`, `unc_lock` |
| Debug observation pins | `RTL/core/riscv_core.v` | `dbg_amo_read`, `dbg_amo_write`, `dbg_resv_valid` |
| Test | `tests/rv32i/12_atomics.S` | |
