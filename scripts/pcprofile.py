#!/usr/bin/env python3
"""
Turn tb_soc's +pcsample output into a function-level profile.

    pcprofile.py <pcsample.txt> <System.map> [fw_dynamic.elf] [--from N] [--to N] [--top K]

Each line of the sample file is the last retired PC (and, in newer files, ra
and sp) at one sampling instant
(see +pcsample in RTL/sim/tb_soc.v). Every sample is attributed to the nearest
symbol at or below it, so the counts are a statistical picture of where the
cycles went - which is the one thing a silent stretch of a boot does not tell
you by itself.

Address spaces on this machine:
    >= 0xC0000000   kernel (PAGE_OFFSET on rv32), resolved via System.map
    0x8070_0000+    OpenSBI, resolved via `nm` of fw_dynamic.elf if given
    0x0000_0000+    boot RAM (BIOS) below 32 KB
    anything else   user space

--from / --to select a sample index range, e.g. one idle gap.
"""
import bisect
import collections
import subprocess
import sys


def load_symbols(lines):
    syms = []
    for line in lines:
        parts = line.split()
        if len(parts) < 3 or parts[1] not in "tTwW":
            continue
        try:
            syms.append((int(parts[0], 16), parts[2]))
        except ValueError:
            pass
    syms.sort()
    return [a for a, _ in syms], [n for _, n in syms]


def resolver(addrs, names):
    def look(pc):
        i = bisect.bisect_right(addrs, pc) - 1
        return names[i] if i >= 0 else "?"
    return look


def main(argv):
    args = [a for a in argv[1:]]
    opts = {"--from": 0, "--to": None, "--top": 25}
    pos = []
    while args:
        a = args.pop(0)
        if a in opts:
            opts[a] = int(args.pop(0))
        else:
            pos.append(a)
    if len(pos) < 2:
        sys.exit(__doc__)

    rows = [[int(x, 16) for x in line.split()]
            for line in open(pos[0]) if line.strip()]
    rows = rows[opts["--from"]:opts["--to"]]
    samples = [r[0] for r in rows]

    with open(pos[1]) as f:
        kern = resolver(*load_symbols(f))
    sbi = None
    if len(pos) > 2:
        nm = subprocess.run(["nm", pos[2]], capture_output=True, text=True).stdout
        sbi = resolver(*load_symbols(nm.splitlines()))

    def classify(pc):
        if pc >= 0xC0000000:
            return "k:" + kern(pc)
        if 0x80700000 <= pc < 0x80800000:
            return "sbi:" + (sbi(pc) if sbi else hex(pc))
        if pc < 0x8000:
            return "bios"
        return "user"

    counts = collections.Counter(classify(pc) for pc in samples)
    total = len(samples) or 1
    zones = collections.Counter(k.split(":")[0] for k in counts.elements())
    print(f"{len(samples)} samples   " +
          "   ".join(f"{z} {100*c/total:.1f}%" for z, c in zones.most_common()))
    print()
    for name, c in counts.most_common(opts["--top"]):
        print(f"{100*c/total:6.2f}%  {c:7d}  {name}")

    # Newer sample files carry ra and sp too (see +pcsample in tb_soc.v).
    if rows and len(rows[0]) >= 3:
        print()
        print("by kernel stack (sp & ~0x1fff = one thread), with its top callers:")
        threads = collections.defaultdict(collections.Counter)
        for pc, ra, sp in (r[:3] for r in rows):
            stack = sp & ~0x1FFF if pc >= 0xC0000000 else classify(pc).split(":")[0]
            threads[stack][classify(ra) if ra >= 0xC0000000 else "-"] += 1
        for stack, callers in sorted(threads.items(),
                                     key=lambda kv: -sum(kv[1].values()))[:6]:
            n = sum(callers.values())
            tag = stack if isinstance(stack, str) else f"{stack:08x}"
            top = ", ".join(f"{k}({v})" for k, v in callers.most_common(5))
            print(f"{100*n/total:6.2f}%  {tag}  ra: {top}")


if __name__ == "__main__":
    main(sys.argv)
