#!/usr/bin/env python3
"""
Turn a program into what the SoC simulation or QEMU needs to run it.

A program is one of:
  ELF       linked for boot RAM (0x0000_0000) or SDRAM (0x8000_0000)
  raw .bin  loaded at --bin-addr (default 0, the reset vector)
  BOOT.TXT  the boot descriptor the BIOS reads from the SD card: one
            "<role> <file> <address>" line per image, roles sbi, kernel,
            dtb and load. Files are relative to the descriptor.

Subcommands:
  defines BOOT.TXT
      C defines that make a BIOS (or the QEMU boot shim) hand off to the
      images in the descriptor the way the SD boot path does: OpenSBI
      fw_dynamic entered in M-mode, kernel next in S-mode, device tree in a1.

  sim --out DIR [--baud N] BIN
      Write .vmem images into DIR and print the tb_soc plusargs that load
      them. For an ELF or binary this is the boot RAM image (+hex), plus an
      SDRAM image when the program is linked there; the boot RAM then holds a
      three-instruction stub that jumps to the entry point. For a BOOT.TXT it is
      the SDRAM images only; the caller supplies a BIOS built with `defines`.
      With --baud the device tree is rewritten for that console speed, since
      OpenSBI and Linux reprogram the UART from it.

  qemu --out DIR [--shim ELF] BIN
      Print the QEMU arguments that load the program. An ELF is loaded at its
      link address and started at its entry point. A BOOT.TXT is loaded image
      by image at the descriptor's addresses, with the device tree adjusted for
      the virt machine, and started through --shim.
"""

import argparse
import os
import re
import shutil
import subprocess
import sys

sys.dont_write_bytecode = True                          # keep scripts/ clean
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_boot_map                                   # noqa: E402
import translate_bin_to_vmem as vmem                    # noqa: E402

BOOT_BASE, BOOT_SIZE = 0x0000_0000, 32 * 1024
SDRAM_BASE, SDRAM_SIZE = 0x8000_0000, 8 * 1024 * 1024
SDRAM_SLOTS = 4                                         # +sdram0..3 in tb_soc
ROLES = ("sbi", "kernel", "dtb", "load")


def die(msg):
    sys.exit(f"run_image: {msg}")


def is_descriptor(path):
    return path.lower().endswith(".txt")


# -----------------------------------------------------------------------------
# BOOT.TXT
# -----------------------------------------------------------------------------
def parse_descriptor(path):
    """[(role, file path, address)] in file order."""
    entries = []
    base = os.path.dirname(os.path.abspath(path))
    with open(path) as f:
        for n, line in enumerate(f, 1):
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            parts = line.split()
            if len(parts) != 3 or parts[0] not in ROLES:
                die(f"{path}:{n}: expected '<{'|'.join(ROLES)}> <file> <address>'")
            role, name, addr = parts
            entries.append((role, os.path.join(base, name), int(addr, 16)))
    for role in ("sbi", "kernel", "dtb"):
        if sum(1 for e in entries if e[0] == role) != 1:
            die(f"{path}: needs exactly one '{role}' entry")
    for _, p, _ in entries:
        if not os.path.isfile(p):
            die(f"{path}: {p} does not exist")
    return entries


def address_of(entries, role):
    return next(a for r, _, a in entries if r == role)


def check_map(entries):
    blobs = [(r if r != "load" else "initrd", a, os.path.getsize(p))
             for r, p, a in entries]
    if not check_boot_map.check(blobs, out=sys.stderr):
        die("the images overlap or fall outside SDRAM")


def fdt(cmd, *args):
    subprocess.run([cmd, *args], check=True)


def patch_dtb(src, dst, baud=None, qemu=False):
    """Copy a device tree, adjusted for where it will run."""
    shutil.copyfile(src, dst)
    if baud:
        # Both the UART node and the console= argument carry the speed; OpenSBI
        # reads the first and Linux the second.
        fdt("fdtput", "-t", "i", dst, "/soc/serial@10000000", "current-speed", str(baud))
        args = subprocess.run(["fdtget", dst, "/chosen", "bootargs"],
                              check=True, capture_output=True, text=True).stdout.strip()
        args = re.sub(r"console=ttyS0,\d+", f"console=ttyS0,{baud}", args)
        fdt("fdtput", "-t", "s", dst, "/chosen", "bootargs", args)
    if qemu:
        # The virt machine differs from the SoC in three values: its CLINT
        # counts at 10 MHz, its UART is PLIC source 10, and its PLIC has 95
        # sources. Everything else - addresses and register layouts - matches.
        fdt("fdtput", "-t", "i", dst, "/cpus", "timebase-frequency", "10000000")
        fdt("fdtput", "-t", "i", dst, "/soc/serial@10000000", "interrupts", "10")
        fdt("fdtput", "-t", "i", dst, "/soc/plic@c000000", "riscv,ndev", "95")


# -----------------------------------------------------------------------------
# ELF and raw binaries
# -----------------------------------------------------------------------------
def program_regions(path, bin_addr):
    """(boot RAM bytes or None, SDRAM (addr, bytes) or None, entry)."""
    with open(path, "rb") as f:
        data = f.read()
    if vmem.is_elf(data):
        segs, entry = vmem.elf_segments(data)
    else:
        segs, entry = [(bin_addr, data)], bin_addr

    boot = [s for s in segs if BOOT_BASE <= s[0] < BOOT_BASE + BOOT_SIZE]
    sdram = [s for s in segs if SDRAM_BASE <= s[0] < SDRAM_BASE + SDRAM_SIZE]
    if len(boot) + len(sdram) != len(segs):
        die(f"{path}: has contents outside boot RAM and SDRAM")
    try:
        boot_img = vmem.flatten(boot, BOOT_BASE, BOOT_SIZE) if boot else None
        if sdram:
            lo = min(a for a, _ in sdram)
            sdram_img = (lo, vmem.flatten(sdram, lo, SDRAM_BASE + SDRAM_SIZE - lo))
        else:
            sdram_img = None
    except ValueError as e:
        die(f"{path}: {e}")
    return boot_img, sdram_img, entry


def jump_stub(target):
    """lui t0, %hi(target); addi t0, t0, %lo(target); jalr x0, 0(t0)"""
    lo = target & 0xFFF
    hi = (target + 0x800) >> 12 & 0xFFFFF
    lui = (hi << 12) | (5 << 7) | 0x37
    addi = (lo << 20) | (5 << 15) | (5 << 7) | 0x13
    jalr = (5 << 15) | 0x67
    return b"".join(w.to_bytes(4, "little") for w in (lui, addi, jalr))


# -----------------------------------------------------------------------------
# Subcommands
# -----------------------------------------------------------------------------
def cmd_defines(args):
    entries = parse_descriptor(args.bin)
    print(f"-DBOOT_ENTRY=0x{address_of(entries, 'sbi'):08x}u "
          f"-DBOOT_DTB=0x{address_of(entries, 'dtb'):08x}u "
          f"-DBOOT_NEXT_ADDR=0x{address_of(entries, 'kernel'):08x}u "
          f"-DBOOT_NEXT_MODE=1u")


def cmd_sim(args):
    os.makedirs(args.out, exist_ok=True)
    plus = []

    def sdram(slot, data, addr, name):
        out = os.path.join(args.out, f"{name}.vmem")
        vmem.write_vmem(data, out, source=name)
        plus.extend([f"+sdram{slot}={out}", f"+sdram{slot}_at={addr:08x}"])

    if is_descriptor(args.bin):
        entries = parse_descriptor(args.bin)
        if len(entries) > SDRAM_SLOTS:
            die(f"{args.bin}: the testbench preloads at most {SDRAM_SLOTS} images")
        check_map(entries)
        for slot, (role, path, addr) in enumerate(entries):
            if role == "dtb" and args.baud:
                patched = os.path.join(args.out, "sim.dtb")
                patch_dtb(path, patched, baud=args.baud)
                path = patched
            with open(path, "rb") as f:
                sdram(slot, f.read(), addr, role)
    else:
        boot, sdram_img, entry = program_regions(args.bin, args.bin_addr)
        if boot is None:
            boot = jump_stub(entry)
        if sdram_img:
            sdram(0, sdram_img[1], sdram_img[0], "sdram")
        out = os.path.join(args.out, "boot.vmem")
        vmem.write_vmem(boot, out, BOOT_SIZE, args.bin)
        plus.insert(0, f"+hex={out}")
    print(" ".join(plus))


def cmd_qemu(args):
    os.makedirs(args.out, exist_ok=True)
    if is_descriptor(args.bin):
        if not args.shim:
            die("a BOOT.TXT needs --shim")
        entries = parse_descriptor(args.bin)
        check_map(entries)
        out = []
        for role, path, addr in entries:
            if role == "dtb":
                patched = os.path.join(args.out, "qemu.dtb")
                patch_dtb(path, patched, qemu=True)
                path = patched
            out.append(f"-device loader,file={path},addr=0x{addr:08x},force-raw=on")
        out.append(f"-device loader,file={args.shim},cpu-num=0")
        print(" ".join(out))
        return

    with open(args.bin, "rb") as f:
        data = f.read()
    if not vmem.is_elf(data):
        die(f"{args.bin}: QEMU needs an ELF (a raw binary carries no load address)")
    segs, _ = vmem.elf_segments(data)
    if any(not SDRAM_BASE <= a < SDRAM_BASE + SDRAM_SIZE for a, _ in segs):
        die(f"{args.bin}: is linked outside SDRAM. The virt machine has no RAM "
            "at 0x0, so link the program at 0x80000000 (make compile-bin LINK=sdram).")
    print(f"-device loader,file={args.bin},cpu-num=0")


def main():
    ap = argparse.ArgumentParser(
        description="Prepare a program for the SoC simulation or QEMU.")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("defines")
    p.add_argument("bin")
    p.set_defaults(fn=cmd_defines)

    p = sub.add_parser("sim")
    p.add_argument("--out", required=True)
    p.add_argument("--baud", type=int)
    p.add_argument("--bin-addr", type=lambda s: int(s, 0), default=BOOT_BASE)
    p.add_argument("bin")
    p.set_defaults(fn=cmd_sim)

    p = sub.add_parser("qemu")
    p.add_argument("--out", required=True)
    p.add_argument("--shim")
    p.add_argument("bin")
    p.set_defaults(fn=cmd_qemu)

    args = ap.parse_args()
    if not os.path.isfile(args.bin):
        die(f"{args.bin}: no such file")
    args.fn(args)


if __name__ == "__main__":
    main()
