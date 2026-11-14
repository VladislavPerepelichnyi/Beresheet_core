#!/usr/bin/env python3
"""
Print the boot memory map and refuse a layout that overlaps.

Written after placing the device tree 0x50000 above OpenSBI and then finding
OpenSBI was 0x82670 long. Three blobs at hand-chosen addresses in 8 MB of RAM
is exactly the arithmetic a person gets wrong and a machine does not, and the
symptom would have been a kernel that started and then died somewhere in libfdt
with no indication that its device tree had been overwritten.
"""
import os
import sys

SDRAM_BASE = 0x8000_0000
SDRAM_SIZE = 8 * 1024 * 1024

def main():
    blobs = []
    for arg in sys.argv[1:]:
        name, addr, path = arg.split(":", 2)
        size = os.path.getsize(path)
        blobs.append((name, int(addr, 16), size, path))

    blobs.sort(key=lambda b: b[1])
    print("Memory map for this boot:")
    errors = []
    prev = None
    for name, addr, size, _ in blobs:
        end = addr + size
        gap = "" if prev is None else f"  (gap {addr - prev[1]:,} after {prev[0]})"
        print(f"  {name:<8} 0x{addr:08X} .. 0x{end:08X}  {size:>9,} bytes{gap}")
        if addr < SDRAM_BASE or end > SDRAM_BASE + SDRAM_SIZE:
            errors.append(f"{name} falls outside SDRAM")
        if prev and addr < prev[1]:
            errors.append(f"{name} overlaps {prev[0]}")
        prev = (name, end)

    free = SDRAM_BASE + SDRAM_SIZE - prev[1]
    print(f"  {'free':<8} 0x{prev[1]:08X} .. 0x{SDRAM_BASE + SDRAM_SIZE:08X}"
          f"  {free:>9,} bytes for Linux to run in")

    # Linux on RV32 maps its own text with Sv32 megapages, so setup_vm requires
    # the load address to be 4 MiB aligned. It is a BUG_ON, not a warning.
    for name, addr, _, _ in blobs:
        if name == "kernel" and addr % (4 * 1024 * 1024):
            errors.append(f"kernel at 0x{addr:08X} is not 4 MiB aligned "
                          "(RV32 setup_vm requires it)")

    if errors:
        print()
        for e in errors:
            print(f"  BOOT MAP ERROR: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
