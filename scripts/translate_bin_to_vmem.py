#!/usr/bin/env python3
"""
Convert a program into a word-oriented $readmemh image (.vmem).

The output has one 32-bit little-endian word per line, in hex, starting at the
memory's base address. This is the format RTL/bus/wb_ram.v loads, both in
simulation and as the initial contents of the FPGA block RAM.

objcopy -O verilog is not used because its '@' records carry byte addresses,
while $readmemh treats them as word indices for a 32-bit memory.

Input may be an ELF file or a raw binary:
  ELF  the PT_LOAD segments are placed at their physical addresses relative to
       --base (default: the lowest segment address); anything outside
       [base, base + size) is an error.
  raw  the bytes are taken to start at --base (default 0).

With --size the image is padded with zeroes to the full memory size, so that
$readmemh is the only initialiser the memory needs.

Usage:
  translate_bin_to_vmem.py <in.elf|in.bin> <out.vmem> [--size BYTES] [--base ADDR]
"""

import argparse
import struct
import sys

PT_LOAD = 1


def is_elf(data):
    return data[:4] == b"\x7fELF"


def elf_segments(data):
    """(paddr, bytes) for every loadable segment with file contents.

    Only 32-bit little-endian RISC-V ELF files are accepted, which is what the
    toolchain produces for this core.
    """
    if data[4] != 1 or data[5] != 1:
        raise ValueError("not a 32-bit little-endian ELF")
    (e_type, e_machine, _, e_entry, e_phoff, _, _, _, e_phentsize,
     e_phnum) = struct.unpack_from("<HHIIIIIHHH", data, 16)
    if e_machine != 243:
        raise ValueError("not a RISC-V ELF")
    segs = []
    for i in range(e_phnum):
        (p_type, p_offset, _, p_paddr, p_filesz,
         p_memsz) = struct.unpack_from("<IIIIII", data, e_phoff + i * e_phentsize)
        if p_type == PT_LOAD and p_filesz > 0:
            segs.append((p_paddr, data[p_offset:p_offset + p_filesz]))
    return segs, e_entry


def elf_entry(data):
    return elf_segments(data)[1]


def flatten(segs, base, size=None):
    """Lay segments out in one byte array starting at base."""
    if not segs:
        raise ValueError("no loadable contents")
    end = max(a + len(b) for a, b in segs)
    for a, b in segs:
        if a < base or (size is not None and a + len(b) > base + size):
            raise ValueError(
                f"segment 0x{a:08x}..0x{a + len(b):08x} is outside "
                f"0x{base:08x}..0x{base + (size or 0):08x}")
    image = bytearray(end - base)
    for a, b in segs:
        image[a - base:a - base + len(b)] = b
    return bytes(image)


def load(path, base=None, size=None):
    """The memory image for a file, as bytes starting at base."""
    with open(path, "rb") as f:
        data = f.read()
    if is_elf(data):
        segs = elf_segments(data)[0]
        if base is None and segs:
            base = min(a for a, _ in segs)
        return flatten(segs, base, size)
    return data


def write_vmem(data, path, size=None, source=""):
    """Write bytes as one little-endian 32-bit word per line."""
    payload = len(data)
    if size is not None and payload > size:
        raise ValueError(f"image is {payload} bytes, memory holds {size}")
    if len(data) % 4:
        data += b"\x00" * (4 - len(data) % 4)
    if size is not None:
        data += b"\x00" * (size - len(data))
    with open(path, "w") as f:
        f.write(f"// {source}: {payload} bytes in {len(data) // 4} words\n")
        for i in range(0, len(data), 4):
            f.write(f"{int.from_bytes(data[i:i + 4], 'little'):08X}\n")
    return payload


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("input")
    ap.add_argument("output")
    ap.add_argument("--size", type=lambda s: int(s, 0),
                    help="memory size in bytes; pads the image and checks it fits")
    ap.add_argument("--base", type=lambda s: int(s, 0),
                    help="address of the first word")
    args = ap.parse_args()

    try:
        data = load(args.input, args.base, args.size)
        n = write_vmem(data, args.output, args.size, args.input)
    except (OSError, ValueError) as e:
        sys.exit(f"translate_bin_to_vmem: {args.input}: {e}")

    fill = f", {100 * n // args.size}% of {args.size}" if args.size else ""
    print(f"translate_bin_to_vmem: {args.output} ({n} bytes{fill})")


if __name__ == "__main__":
    main()
