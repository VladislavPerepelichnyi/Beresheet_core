# 2. From core port to Wishbone master

## The idea: the core already speaks a handshake

The core was designed before the bus. Its two memory ports use a minimal
request/ready protocol:

- the core puts an address (and, for a store, data and byte strobes) on the
  port and raises a request;
- it keeps everything steady and waits;
- the memory raises `ready` for one cycle, with the read data alongside.

That is the Wishbone handshake under different names. So the module that turns
a core port into a Wishbone master, `wb_master_bridge`, is almost only wires.
It adds no clock cycles.

## The two ports

| Port | Signals (core side) | Used for |
|------|---------------------|----------|
| `imem` | `imem_addr`, `imem_req` / `imem_rdata`, `imem_ready` | Instruction fetch. Read only, always a whole word |
| `dmem` | `dmem_addr`, `dmem_wdata`, `dmem_wstrb`, `dmem_we`, `dmem_re`, `dmem_lock` / `dmem_rdata`, `dmem_ready` | Loads, stores, atomics, and page-table walks |

Both carry **physical** addresses: the TLBs inside the core have already
translated them.

Between each core port and its bridge sits a cache (`cache_vipt` in
`RTL/core/cache.v`). The cache speaks the same request/ready protocol on both
of its sides, so from the bridge's point of view it is just another requester.
Setting the `ICACHE` or `DCACHE` parameter of `soc_wb` to 0 removes the cache
and wires the core port straight to the bridge, which is a useful experiment
when a bug might be in either.

## The mapping

| Core side | Wishbone side | Note |
|-----------|---------------|------|
| `re \| we` | `STB_O` | A request is a strobe |
| `re \| we \| lock` | `CYC_O` | CYC also stays up while an atomic holds the bus |
| `lock` | `LOCK_O` | See [chapter 3](03-masters-and-arbiter.md) |
| `{addr[31:2], 2'b00}` | `ADR_O` | Word address; the byte position is in SEL |
| `wdata` | `DAT_O` | Already shifted into the right byte lanes |
| `wstrb` | `SEL_O` | One bit per byte lane, for loads as well as stores |
| `we` | `WE_O` | |
| `DAT_I` (or 0 on error) | `rdata` | |
| `ACK_I \| ERR_I` | `ready` | Either answer ends the wait |

For the instruction port the bridge is instantiated with `wstrb = 1111`,
`we = 0`, `wdata = 0` and `lock = 0`: a fetch is always a single word read.

### Why the master's outputs stay steady

Wishbone rule 1 says the master must hold ADR, DAT, SEL and WE from STB until
ACK. The bridge has no registers, so it relies on whatever drives it:

- without a cache, the core's memory stage stalls (`mem_stall`), which freezes
  the EX/MEM pipeline register that holds the address and data;
- with a cache (the normal build), the cache drives the bridge from its own
  registers (fill address, eviction data, or the latched uncached request) and
  changes them only on `ready`.

## When the answer is ERR

If the address matches no slave, the interconnect answers with ERR
([chapter 4](04-interconnect.md)). The bridge then:

1. ends the wait anyway (`ready = ACK | ERR`), so the core never hangs;
2. returns zero as the read data;
3. sets a sticky flag, `bus_error`, that only reset clears.

The two bridges' flags are ORed into the SoC output `bus_error`. On the Tang
Nano 20K top level that output is not connected to a pin; it exists for the
simulation testbench.

The core does **not** take an access-fault exception on ERR. A load from an
unmapped address returns 0, and a store to one is dropped, without a trap. The
BIOS uses an address in no region (`UNMAPPED = 0x4000_0000` in
`firmware/bios/soc.h`) to check that the bus reports an error instead of
hanging.

## Where this is in the RTL

| What | File | Key signals |
|------|------|-------------|
| The bridge | `RTL/bus/wb_master_bridge.v` | `req`, `wb_stb_o`, `wb_cyc_o`, `wb_lock_o`, `ready`, `bus_error` |
| Two instances, `dbus` and `ibus` | `RTL/soc/soc_wb.v` | `dbus_*`, `ibus_*`, `m0_*`, `m1_*`, `d_bus_error`, `i_bus_error` |
| Caches between core and bridges | `RTL/core/cache.v` (`cache_vipt`) | `mem_addr`, `mem_re`, `mem_we`, `mem_lock`, `mem_ready` |
| Byte-lane shifting and the lock for atomics | `RTL/core/mem_wb.v` | `dmem_wstrb`, `dmem_wdata`, `dmem_lock` |
