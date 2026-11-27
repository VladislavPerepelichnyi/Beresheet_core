#!/usr/bin/env python3
"""
Report the timing margin against the clock the board really runs at.

The SDC constrains the design tighter than the PLL output, so Gowin's summary
quotes a target rather than the real margin. This reads the longest setup path
from the timing report and the cpu_clk period from the SDC, and recomputes the
slack for the real clock period.

Usage:  timing_margin.py <clock_hz> <timing_paths> <sdc>
"""
import re
import sys

if len(sys.argv) != 4:
    sys.exit(__doc__)
real_hz, paths, sdc = int(sys.argv[1]), sys.argv[2], sys.argv[3]

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

# What the tool adds to the period (uncertainty, skew) is independent of the
# period itself, so it carries over to the real clock unchanged.
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
