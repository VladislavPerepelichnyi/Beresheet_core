#!/usr/bin/env python3
"""
Print the SDRAM boot map and reject a layout that cannot boot.

Checks that every image lies inside SDRAM, that no two overlap, and that the
kernel is 4 MiB aligned (RV32 setup_vm maps kernel text with Sv32 megapages and
BUG()s on anything else).

Usage:  check_boot_map.py <name>:<hex address>:<file> ...
"""
import os
import sys

SDRAM_BASE = 0x8000_0000
SDRAM_SIZE = 8 * 1024 * 1024
KERNEL_ALIGN = 4 * 1024 * 1024


def check(blobs, out=sys.stdout):
    """Print the map for [(name, address, size)]; return True if it is valid."""
    blobs = sorted(blobs, key=lambda b: b[1])
    errors = []
    prev = None
    print("Boot memory map:", file=out)
    for name, addr, size in blobs:
        end = addr + size
        gap = "" if prev is None else f"  (gap {addr - prev[1]:,} after {prev[0]})"
        print(f"  {name:<8} 0x{addr:08X} .. 0x{end:08X}  {size:>9,} bytes{gap}", file=out)
        if addr < SDRAM_BASE or end > SDRAM_BASE + SDRAM_SIZE:
            errors.append(f"{name} falls outside SDRAM")
        if prev and addr < prev[1]:
            errors.append(f"{name} overlaps {prev[0]}")
        if name == "kernel" and addr % KERNEL_ALIGN:
            errors.append(f"kernel at 0x{addr:08X} is not 4 MiB aligned")
        prev = (name, end)

    top = SDRAM_BASE + SDRAM_SIZE
    if prev and prev[1] < top:
        print(f"  {'free':<8} 0x{prev[1]:08X} .. 0x{top:08X}  {top - prev[1]:>9,} bytes", file=out)
    for e in errors:
        print(f"  BOOT MAP ERROR: {e}", file=out)
    return not errors


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    blobs = []
    for arg in sys.argv[1:]:
        name, addr, path = arg.split(":", 2)
        blobs.append((name, int(addr, 16), os.path.getsize(path)))
    sys.exit(0 if check(blobs) else 1)


if __name__ == "__main__":
    main()
