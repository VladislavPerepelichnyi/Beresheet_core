#!/usr/bin/env python3
"""
Mutation check for the Sv32 MMU.

Nearly every rule this module enforces is a rule from the privileged
specification, and a permission check that is wrong in the permissive direction
fails silently: the access succeeds, the program works, and the isolation the
kernel thinks it has is not there. Those are the mutants that matter here.

Needs the build tree to itself; do not run `make test` alongside it.

Two guards here are individually unobservable and jointly load bearing, which is
the same shape found in the trap logic during the timing work. A walk latches the
page it is for, *and* abandons itself if the request moves to another page.
Either one alone is enough to stop a walk filling the TLB under the wrong page
number, so removing either alone changes nothing a test can see. Removing both
corrupts the TLB silently - an entry tagged with one page carrying another
page's translation - so the pair is mutated together below.

One guard is deliberately not mutated. Dropping the `!pte_is_leaf` test at the
last level is unobservable: a pointer PTE has R, W and X all zero by definition,
so it fails the permission check anyway and the access faults either way. The
guard is kept because it stops a pointer being installed in the TLB as a bogus
leaf - which wastes an entry and re-faults instead of re-walking - but no test
can tell the difference, and a surviving mutant that expresses nothing is not a
hole in the tests.
"""
import os
import shutil
import subprocess
import sys

SRC = "RTL/core/MMU.v"
BAK = SRC + ".mutbak"

MUTANTS = [
    ("U-mode may touch a supervisor page",
     "            if (eff_priv == `U_MODE)\n"
     "                priv_ok = check_flags[PTE_U];",
     "            if (eff_priv == `U_MODE)\n"
     "                priv_ok = 1'b1;"),

    ("S-mode may touch a user page without SUM",
     "                priv_ok = (!check_flags[PTE_U]) ||\n"
     "                          (mstatus_sum && (IS_FETCH == 0));",
     "                priv_ok = (!check_flags[PTE_U]) || mstatus_sum || 1'b1;"),

    ("SUM also opens user pages to instruction fetch",
     "                          (mstatus_sum && (IS_FETCH == 0));",
     "                          (mstatus_sum);"),

    ("a store is allowed on a page without W",
     "            else if (req_write)\n"
     "                perm_ok = check_flags[PTE_W];",
     "            else if (req_write)\n"
     "                perm_ok = check_flags[PTE_R];"),

    ("MXR is ignored, so an execute-only page is never readable",
     "                perm_ok = check_flags[PTE_R] ||\n"
     "                          (mstatus_mxr && check_flags[PTE_X]);",
     "                perm_ok = check_flags[PTE_R] || (mstatus_mxr && 1'b0);"),

    ("a fetch does not need X",
     "            if (IS_FETCH)\n"
     "                perm_ok = check_flags[PTE_X];",
     "            if (IS_FETCH)\n"
     "                perm_ok = check_flags[PTE_R] | check_flags[PTE_X];"),

    ("the dirty bit is not required for a store",
     "            if (!IS_FETCH && req_write) ad_ok = check_flags[PTE_A] && check_flags[PTE_D];",
     "            if (!IS_FETCH && req_write) ad_ok = check_flags[PTE_A] &&\n"
     "                                                 (check_flags[PTE_D] | 1'b1);"),

    ("the accessed bit is not required at all",
     "            else                        ad_ok = check_flags[PTE_A];",
     "            else                        ad_ok = 1'b1;"),

    ("the reserved R=0 W=1 encoding is accepted",
     "    wire pte_bad_rw  = !ptw_rdata[PTE_R] && ptw_rdata[PTE_W];",
     "    wire pte_bad_rw  = !ptw_rdata[PTE_R] && ptw_rdata[PTE_W]\n"
     "                       && !ptw_rdata[PTE_X];"),

    ("a misaligned megapage is rounded down instead of faulting",
     "    wire pte_mega_misaligned = |ptw_rdata[19:10];",
     "    wire pte_mega_misaligned = 1'b0;"),

    ("a megapage ignores VPN0, so every page in it aliases the first",
     "    assign paddr = xlate_on ? {hit_mega ? {hit_ppn[19:10], vpn0} : hit_ppn,\n"
     "                               page_off}\n"
     "                            : vaddr;",
     "    assign paddr = xlate_on ? {hit_mega ? {hit_ppn[19:10], (vpn0 & 10'd0)}\n"
     "                                        : hit_ppn, page_off}\n"
     "                            : vaddr;"),

    ("SFENCE.VMA does not invalidate anything",
     "            if (sfence_req) begin\n"
     "                for (i = 0; i < TLB_ENTRIES; i = i + 1)\n"
     "                    tlb_valid[i] <= 1'b0;",
     "            if (sfence_req) begin\n"
     "                for (i = 0; i < TLB_ENTRIES; i = i + 1)\n"
     "                    tlb_valid[i] <= tlb_valid[i];"),

    ("the ASID is not part of the match",
     "            if (tlb_valid[i] && (tlb_asid[i] == satp_asid) &&",
     "            if (tlb_valid[i] && (tlb_asid[i] == tlb_asid[i]) &&"),

    ("MPRV is honoured for instruction fetch too",
     "    wire [1:0] eff_priv = (IS_FETCH == 0) && (priv_mode == `M_MODE) && mstatus_mprv\n"
     "                          ? mstatus_mpp : priv_mode;",
     "    wire [1:0] eff_priv = (priv_mode == `M_MODE) && mstatus_mprv\n"
     "                          ? mstatus_mpp : priv_mode;"),

    ("a latched fault gates the re-walk, so a faulted page is lost forever",
     "                    if (xlate_on && req_valid && !hit) begin",
     "                    if (xlate_on && req_valid && !hit && !walk_fault) begin"),

    ("a walk that outlives its address: both guards removed at once",
     "                    tlb_vpn  [victim] <= walk_vpn;",
     "                    tlb_vpn  [victim] <= vpn;   /* MUTANT_PAIR */"),

    ("M-mode translates",
     "    wire       xlate_on = satp_mode && (eff_priv != `M_MODE);",
     "    wire       xlate_on = satp_mode;"),

]


# The paired mutant needs a second edit in the same build.
PAIR_EXTRA = (
    "                    if (req_valid && (vpn != walk_vpn)) begin\n"
    "                        ptw_re    <= 1'b0;\n"
    "                        ptw_state <= STATE_IDLE;\n"
    "                    end else if (ptw_ready) begin",
    "                    if (ptw_ready && (walk_vpn[19:10] == walk_vpn[19:10])) begin",
)


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
                escaped.append(name + " (stale)")
                continue

            mutated = original.replace(find, repl, 1)
            if "MUTANT_PAIR" in repl:
                # Remove the other half of the pair as well, everywhere it
                # appears - the walker has two states that use it.
                mutated = mutated.replace(PAIR_EXTRA[0], PAIR_EXTRA[1])
            open(SRC, "w").write(mutated)
            os.utime(SRC, None)
            r = run("make test-mmu 2>&1")
            out = r.stdout + r.stderr

            if "MMU UNIT TEST" not in out:
                print(f"  [bld] BUILD-FAIL {name}")
                for line in out.splitlines():
                    if "%Error" in line:
                        print(f"        {line.strip()[:100]}")
                escaped.append(name + " (build)")
            elif "MMU UNIT TEST FAILED" in out or "TIMEOUT" in out:
                first = next((l.strip() for l in out.splitlines()
                              if "FAIL" in l and "UNIT TEST" not in l), "")
                print(f"  [ok] CAUGHT      {name}")
                if first:
                    print(f"        by: {first[:94]}")
            else:
                print(f"  [!!] SURVIVED    {name}")
                escaped.append(name)
    finally:
        shutil.move(BAK, SRC)
        os.utime(SRC, None)
        check = run("make test-mmu 2>&1")
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
