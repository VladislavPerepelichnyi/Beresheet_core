#!/usr/bin/env python3
"""
Mutation check for the data cache.

Injects one deliberate defect at a time and requires tb_dcache to fail. A test
that cannot fail is not evidence, and this project has already been caught once
by a mutant that was wrong rather than a test that was weak - so every mutation
here is written to express the bug it names, not merely to perturb the source.

Needs the build tree to itself; do not run `make test` alongside it.

One mutation is deliberately absent. Letting the combinational data write run
while the sequential block gives way to a flush looks like a bug and is not:
the CPU is still holding the request, so once the flush finishes the store is
served again from a clean line and the result is correct. The guard is kept
because two always blocks deciding the same thing separately is how the real
bug happened - but a mutant that expresses nothing observable is not evidence,
and this project has already spent time on one of those.

The real ordering bug lives in the core, not here: FENCE.I asking for a flush
while the store ahead of it is still on the bus. It is caught by the Zifencei
section of the BIOS, which writes an instruction into SDRAM and executes it.
"""
import os
import re
import shutil
import subprocess
import sys

SRC = "RTL/core/cache.v"
BAK = SRC + ".mutbak"

MUTANTS = [
    ("byte strobes ignored on a write hit",
     "                data_be    = cpu_wstrb;",
     "                data_be    = 4'b1111;"),

    ("write-back addresses the line with the requesting tag, not the victim's",
     "                            evict_tag       <= tag_ram[{idx, victim_way}];",
     "                            evict_tag       <= ptag;"),

    ("the second window swallows the device region, so MMIO is cached",
     "    wire in_win2 = (CACHEABLE2_SIZE != 0) &&\n"
     "                   (cpu_paddr[`BUS_WIDTH-1:W2_BITS] ==\n"
     "                    CACHEABLE2_BASE[`BUS_WIDTH-1:W2_BITS]);",
     "    wire in_win2 = (CACHEABLE2_SIZE != 0) && (W2_BITS > 0) &&\n"
     "                   (cpu_paddr[`BUS_WIDTH-1:`BUS_WIDTH-1] ==\n"
     "                    CACHEABLE2_BASE[`BUS_WIDTH-1:`BUS_WIDTH-1]);"),

    ("a write hit does not mark the line dirty",
     "                        if (cpu_we)\n"
     "                            dirty_ram[{idx, hit_way}] <= 1'b1;",
     "                        if (cpu_we && 1'b0)\n"
     "                            dirty_ram[{idx, hit_way}] <= 1'b1;"),

    ("ready is registered instead of decoded from the state",
     "    assign cpu_ready = (state == S_HIT) || (state == S_UNC_DONE);",
     "    reg ready_q;\n"
     "    always @(posedge clk)\n"
     "        ready_q <= (state == S_HIT) || (state == S_UNC_DONE);\n"
     "    assign cpu_ready = ready_q;"),

    ("the fill stops one beat early",
     "                    if (beat == LAST_BEAT[BEAT_BITS-1:0]) begin\n"
     "                        fsm_mem_re <= 1'b0;",
     "                    if (beat == LAST_BEAT[BEAT_BITS-1:0] - 1'b1) begin\n"
     "                        fsm_mem_re <= 1'b0;"),

    ("the tag compare ignores the valid bit",
     "            if (valid_ram[{idx, i[WAY_BITS-1:0]}] &&\n"
     "                (tag_ram[{idx, i[WAY_BITS-1:0]}] == ptag)) begin",
     "            if ((tag_ram[{idx, i[WAY_BITS-1:0]}] == ptag)) begin"),

    ("flush invalidates without writing back",
     "                end else if (valid_ram[{flush_idx[INDEX_BITS-1:0], flush_way}] &&\n"
     "                             dirty_ram[{flush_idx[INDEX_BITS-1:0], flush_way}]) begin",
     "                end else if (1'b0) begin"),
]


def run(cmd):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True)


def main():
    shutil.copy(SRC, BAK)
    original = open(SRC).read()
    escaped = []

    try:
        for name, find, repl in MUTANTS:
            if find not in original:
                print(f"  [??] STALE       {name}")
                print(f"       pattern no longer present; the mutant tests nothing")
                escaped.append(name + " (stale)")
                continue

            open(SRC, "w").write(original.replace(find, repl, 1))
            r = run("make test-dcache 2>&1")
            out = r.stdout + r.stderr

            if "Error" in out and "UNIT TEST" not in out:
                print(f"  [bld] BUILD-FAIL {name}")
                for line in out.splitlines():
                    if "%Error" in line:
                        print(f"        {line.strip()[:100]}")
                escaped.append(name + " (build)")
            elif "DCACHE UNIT TEST FAILED" in out or "TIMEOUT" in out:
                first = next((l.strip() for l in out.splitlines()
                              if "FAIL" in l and "UNIT TEST" not in l), "")
                print(f"  [ok] CAUGHT      {name}")
                if first:
                    print(f"        by: {first[:96]}")
            else:
                print(f"  [!!] SURVIVED    {name}")
                escaped.append(name)
    finally:
        shutil.move(BAK, SRC)

        # Stamp the restored file with the current time, and do not treat this
        # as housekeeping.
        #
        # shutil.move is a rename, so the restored source carries the backup's
        # timestamp - which is from before the script started, and therefore
        # older than the object built from the last mutant. make compares
        # timestamps: it sees a source older than its binary, decides there is
        # nothing to do, and every later `make test-dcache` silently runs the
        # mutant instead of the design. The test then fails against RTL that is
        # correct on disk, which is a genuinely horrible thing to debug.
        os.utime(SRC, None)

        # And prove the restore worked, rather than assuming it.
        check = run("make test-dcache 2>&1")
        if "UNIT TEST PASSED" not in (check.stdout + check.stderr):
            print("  [!!] RESTORE FAILED - the source on disk is not clean")
            sys.exit(2)

    print()
    if escaped:
        print("escaped:")
        for e in escaped:
            print("  " + e)
        sys.exit(1)
    print(f"{len(MUTANTS)} mutants, all caught")


if __name__ == "__main__":
    main()
