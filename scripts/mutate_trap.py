#!/usr/bin/env python3
# NOTE: this needs the build tree to itself. Running make test (or anything else
# that drives make) alongside it races on build/obj_dir and build/obj_soc, and
# the result is spurious survivors and build failures rather than an error.
"""Mutate the two-cycle trap logic. Each mutant is a plausible way to get the
split wrong, and each is run bare and over the bus."""
import subprocess, shutil, os, sys

SRC = 'RTL/core/control_unit.v'
TESTS_BARE = ['09_traps', '13_privilege', '08_csr', '12_atomics', '14_trap_timing']
TESTS_SOC  = ['09_traps', '13_privilege', '10_interrupts', '14_trap_timing']

MUTANTS = [
  ("pipeline not held during detect: the offender advances and commits",
   """        else if (trap_hold) begin""",
   """        else if (1'b0) begin"""),

  ("take without re-checking redirect_ok: redirect mid-fetch",
   """        trap_take   = trap_pending && redirect_ok;""",
   """        trap_take   = trap_pending;"""),

  ("cause recomputed instead of latched",
   """        trap_cause = {trap_is_irq_q, {(`BUS_WIDTH-5){1'b0}}, trap_code_q};""",
   """        trap_cause = {trap_is_irq, {(`BUS_WIDTH-5){1'b0}}, trap_code};"""),

  ("destination recomputed instead of latched",
   """        trap_to_s   = trap_to_s_q;""",
   """        trap_to_s   = trap_is_irq ? irq_dest_s : exc_delegated;"""),

  ("xRET not suppressed while a trap is on its way in",
   """        trap_return = (is_mret || is_sret) && inst_valid && redirect_ok &&
                      !trap_hold;""",
   """        trap_return = (is_mret || is_sret) && inst_valid && redirect_ok;"""),

  ("a CSR access may start while a trap is pending",
   """    wire csr_start = csr_req && (state == STATE_RUNNING) && !fault &&
                     !mem_stall && !trap_hold;""",
   """    wire csr_start = csr_req && (state == STATE_RUNNING) && !fault &&
                     !mem_stall;"""),

  ("detect without redirect_ok: latch during a bus transaction",
   """    wire trap_detect    = trap_condition && redirect_ok && !trap_pending;""",
   """    wire trap_detect    = trap_condition && !trap_pending;"""),

  ("pending dropped when it cannot be taken immediately",
   """        else if (trap_take) begin
            trap_pending  <= 1'b0;
        end""",
   """        else begin
            trap_pending  <= 1'b0;
        end"""),

  ("the RV32M unit may start while a trap is pending",
   """                           is_mret || is_sret || trap_hold ||
                           mem_stall || fetch_stall;""",
   """                           is_mret || is_sret ||
                           mem_stall || fetch_stall;"""),
]

def build(t):
    r = subprocess.run(['make', t], capture_output=True, text=True)
    return r.returncode == 0, (r.stdout + r.stderr)

def run_bare(name):
    r = subprocess.run(['build/obj_dir/sim_rv32i', '+hex=build/tests/%s.hex' % name,
                        '+timeout=300000'], capture_output=True, text=True)
    return 'TEST PASSED' in r.stdout, r.stdout

def run_soc(name):
    r = subprocess.run(['build/obj_soc/sim_soc',
                        '+hex=build/tests/soc_%s.wordhex' % name,
                        '+timeout=800000', '+quiet'], capture_output=True, text=True)
    return 'TEST PASSED' in r.stdout, r.stdout

shutil.copy(SRC, SRC + '.trapbak')
orig = open(SRC).read()
escaped = []
try:
    for name, old, new in MUTANTS:
        if old not in orig:
            print("  ??  PATTERN-MISS  %s" % name, flush=True); escaped.append(name); continue
        open(SRC, 'w').write(orig.replace(old, new, 1))
        okb, eb = build('verilate'); oks, es = build('verilate-soc')
        if not (okb and oks):
            errs = [l for l in (eb + es).splitlines() if l.startswith('%Error')][:1]
            print("  bld BUILD-FAIL   %s  %s" % (name, errs), flush=True)
            open(SRC, 'w').write(orig); continue

        caught_by = []
        for t in TESTS_BARE:
            ok, out = run_bare(t)
            if not ok: caught_by.append('bare/' + t)
        for t in TESTS_SOC:
            ok, out = run_soc(t)
            if not ok: caught_by.append('soc/' + t)

        if caught_by:
            print("  [ok ] %s\n         caught by %s" % (name, ', '.join(caught_by[:3])), flush=True)
        else:
            print("  [!! ] SURVIVED  %s" % name, flush=True)
            escaped.append(name)
        open(SRC, 'w').write(orig)
finally:
    shutil.copy(SRC + '.trapbak', SRC); os.remove(SRC + '.trapbak')
    build('verilate'); build('verilate-soc')

print()
print("%d mutants, %d escaped" % (len(MUTANTS), len(escaped)))
for e in escaped: print("  escaped:", e)
