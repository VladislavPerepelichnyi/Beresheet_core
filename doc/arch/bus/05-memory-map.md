# 5. The memory map

## The idea: every thing has an address

On a RISC-V machine there are no special I/O instructions. A device register
is read with `lw` and written with `sw`, exactly like memory; the address
alone decides whether the access lands in RAM, in the UART or in the timer.
The list of who owns which addresses is the **memory map**. Hardware (the
interconnect) and software (the BIOS, OpenSBI, Linux) must agree on it, or
nothing works.

![Physical address space, decoded on ADR[31:24]](figures/memory-map.svg)

## The map

| Base | Region byte | Device | Size used | Cached | Notes |
|------|-------------|--------|-----------|--------|-------|
| `0x0000_0000` | `0x00` | Boot RAM | 32 KB | yes | Block RAM holding the BIOS. The reset vector is address 0 |
| `0x0200_0000` | `0x02` | CLINT | 64 KB (`0x0000`–`0xBFFF`) | no | Timer and software interrupt, ACLINT layout |
| `0x0C00_0000` | `0x0C` | PLIC | 4 MB (`0x00_0000`–`0x3F_FFFF`) | no | External interrupt controller |
| `0x1000_0000` | `0x10` | UART 16550 | 32 B | no | Registers at base + 0 to base + 7 |
| `0x1100_0000` | `0x11` | LED PWM | 64 B | no | 6 duty registers, SWIRQ at +0x20 |
| `0x1200_0000` | `0x12` | SD card (SPI) | 16 B | no | Four 32-bit controller registers |
| `0x1300_0000`–`0x16FF_FFFF` | `0x13`–`0x16` | reserved | | | Ethernet, HDMI, USB, PCIe slots; not built, answer ERR |
| `0x8000_0000` | `0x80` | SDRAM | 8 MB | yes | Main memory: kernel, OpenSBI, user programs |
| anything else | | none | | | The error slave answers ERR |

"Cached" means the address lies in one of the two cacheable windows of the
I-cache and D-cache (`CACHEABLE_BASE/SIZE` and `CACHEABLE2_BASE/SIZE` in the
`cache_vipt` instances). The rule is **memory versus device**, not fast versus
slow: block RAM is right next to the core and answers in two cycles, but it is
still memory, and leaving it uncached made the BIOS slower than having no cache
at all. Devices are never cached, because a device register can change on its
own (`mtime`), or because reading it has a side effect (the UART receive
buffer, the PLIC claim register).

Executable means code can run from there: the fetch path reaches any address,
but only the two memories hold code in practice. Fetching from a device region
would return register contents as instructions.

### Aliasing

Each region spans 16 MB, but the slaves decode only what they need:

| Slave | Address bits it looks at | Repeats every |
|-------|--------------------------|---------------|
| Boot RAM | `ADR[14:2]` | 32 KB |
| CLINT | `ADR[15:0]` | 64 KB |
| PLIC | `ADR[23:0]` | (no repeat inside its region) |
| UART | `ADR[4:0]` and SEL | 32 B |
| LED PWM | `ADR[5:2]` | 64 B |
| SD card | `ADR[3:2]` | 16 B |
| SDRAM | `ADR[22:0]` | 8 MB (so `0x8080_0000` reads `0x8000_0000`) |

The alias addresses are not cached (the cacheable windows are exactly 32 KB
and 8 MB), so do not use them; they exist only because full decoding would
cost logic for no benefit.

## Fixed offsets, free bases

Two kinds of numbers appear in the map, and they have different owners.

- **Base addresses** are the SoC designer's choice. Beresheet uses the
  conventional RISC-V values (CLINT at `0x0200_0000`, PLIC at `0x0C00_0000`,
  UART at `0x1000_0000`, RAM at `0x8000_0000`), which are also what QEMU's
  `virt` machine uses, so they look familiar.
- **Offsets inside the CLINT and PLIC** are fixed by their specifications
  (ACLINT and the RISC-V PLIC spec). OpenSBI's and Linux's drivers depend on
  them, so they cannot be changed. The same holds for the 16550 register
  order.

## Where software learns the map

| Consumer | Source of the addresses |
|----------|-------------------------|
| The RTL | `RTL/bus/wb_defines.vh` (`REGION_*`, `SDRAM_BASE_ADDR`, `BOOT_RAM_BYTES`, `SDRAM_BYTES`) |
| The BIOS | `firmware/bios/soc.h` (`CLINT_BASE`, `PLIC_BASE`, `UART_BASE`, `LED_BASE`, `SD_BASE`, `SDRAM_BASE`) |
| OpenSBI and Linux | The device tree, `firmware/dts/beresheet.dts` |

The BIOS has the addresses compiled in. OpenSBI and Linux have none compiled
in: they read them from the device tree that the BIOS passes in register `a1`.
That is why the base addresses were free to choose. All three lists must agree;
nothing checks it automatically.

The device tree describes the CLINT, PLIC, UART and LED block and the memory.
It deliberately does not list the boot RAM or the SD card controller: Linux has
no use for the first and no driver for the second.

## How Linux uses the 8 MB

The device tree tells Linux about only **7 MB** of SDRAM. The last megabyte
holds OpenSBI, which must stay resident (it services the kernel's SBI calls,
such as setting the next timer interrupt), and Linux must never allocate over it.

| Address | Contents |
|---------|----------|
| `0x8000_0000` | Kernel `Image`. RV32 Linux maps its text with 4 MB megapages, so the kernel must start on a 4 MB boundary; with 8 MB there are two such slots, and only the first is large enough |
| `0x8040_0000` | initramfs (the root file system) |
| `0x806F_0000` | Device tree blob |
| `0x8070_0000` | OpenSBI (outside the `memory` node, invisible to Linux) |
| `0x8080_0000` | End of SDRAM |

The BIOS loads these files from the SD card into SDRAM before handing over to
OpenSBI. The file `BOOT.TXT` on the card says which file goes where
([SD card chapter](../peripherals/05-sd-card.md)).

## Where this is in the RTL

| What | File | Key names |
|------|------|-----------|
| Region constants and sizes | `RTL/bus/wb_defines.vh` | `REGION_*`, `BOOT_BASE_ADDR`, `SDRAM_BASE_ADDR` |
| Decoder | `RTL/bus/wb_intercon.v` | `sel_*` |
| Cacheable windows | `RTL/soc/soc_wb.v` (cache instances), `RTL/core/cache.v` | `CACHEABLE_BASE`, `CACHEABLE_SIZE`, `CACHEABLE2_*`, `in_win1`, `in_win2` |
| BIOS copy of the map | `firmware/bios/soc.h` | `*_BASE` |
| Device tree | `firmware/dts/beresheet.dts` | `reg` properties, `memory@80000000` |
