#!/usr/bin/env python3
"""Report the real timing margin.

The SDC deliberately constrains tighter than the PLL actually runs, so Gowin's
own summary quotes a frequency the design is not clocked at. This translates it
back: the constraint is a target, the real question is how much of the real
period is left over.

The constraint is read from the SDC rather than assumed. An earlier version of
this script hardcoded 37.037 ns, which was true when it was written and silently
wrong the moment the constraint was changed - it then reported two different
margins for two runs whose longest path was identical.
"""
import re
import sys

real_hz = int(sys.argv[1]) if len(sys.argv) > 1 else 24_000_000
paths   = sys.argv[2] if len(sys.argv) > 2 else \
          'build/fpga/impl/pnr/custom_riscv.timing_paths'
sdc     = sys.argv[3] if len(sys.argv) > 3 else \
          'RTL/fpga/tang_nano_20k/tang_nano_20k.sdc'

try:
    lines = open(paths).read().split('\n')
    i = lines.index('SETUP')
    arrival, required = float(lines[i + 2]), float(lines[i + 3])
except Exception as e:
    print("  timing: no path report (%s)" % e)
    sys.exit(0)

try:
    m = re.search(r'create_clock\s+-name\s+cpu_clk\s+-period\s+([0-9.]+)',
                  open(sdc).read())
    constraint = float(m.group(1))
except Exception as e:
    print("  timing: cannot read the cpu_clk constraint from %s (%s)" % (sdc, e))
    sys.exit(0)

real_period = 1e9 / real_hz

# Whatever the tool adds on top of the period - clock uncertainty, skew, the
# capture edge - is the difference between what it required and the period it
# was asked for. That part does not change when the real clock is slower.
allowance = required - constraint
real_req  = real_period + allowance
margin    = real_req - arrival

print("  clock          : %.3f MHz  (period %.3f ns)" % (real_hz / 1e6, real_period))
print("  sdc constraint : %.3f ns  (%.3f MHz, a target - not the real clock)"
      % (constraint, 1000.0 / constraint))
print("  longest path   : %.2f ns" % arrival)
print("  real margin    : %+.2f ns  (%.1f%% of the period)"
      % (margin, 100 * margin / real_period))
if margin < 0:
    print("  VERDICT        : DOES NOT CLOSE at %.3f MHz" % (real_hz / 1e6))
