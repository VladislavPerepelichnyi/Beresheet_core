# =============================================================================
# Timing constraints.
#
# Only the crystal is declared. Gowin's timing engine propagates through the
# rPLL and derives both outputs itself, and naming the internal PLL nets by hand
# is brittle: synthesis renames them.
#
# The crystal is 27 MHz; the PLL divides it to 24 MHz (8/9) and both of its
# outputs run at that, one phase shifted from the other. The shift is
# deliberate - it is what gives the SDRAM its setup and hold margin - so it is a
# design parameter rather than a path for the tool to close.
#
# Note: Gowin's SDC parser does not accept backslash line continuations, so
# every constraint stays on one line.
# =============================================================================

create_clock -name sys_clk -period 37.037 -waveform {0 18.5} [get_ports {sys_clk}]

# The PLL output that everything actually runs on. Without this the whole
# internal design is unconstrained and the timing report says "no timing paths",
# which reads like success and is not.
#
# DELIBERATELY TIGHTER THAN THE REAL CLOCK. The PLL makes 24 MHz (41.667 ns);
# this asks for 27 MHz (37.037 ns).
#
# The reason is that the router is timing driven: it optimises until the
# constraint is met and then stops. Constraining at the real 41.667 ns produced a
# 43.53 ns path with 0.37 ns to spare - the tool had simply spent the extra
# budget on easier placement, and dropping the clock bought nothing at all.
# Constraining at 37.037 makes it produce a ~39.2 ns path, and running that at
# 41.667 ns leaves about 4.7 ns of real margin.
#
# So the number below is a target, not a description. The real margin is
#
#     (real period 41.667 + clock allowance 2.236) - arrival
#
# and `make fpga-report` prints it. If this is ever changed, change it *down*:
# raising it towards the real period gives the margin straight back.
create_clock -name cpu_clk -period 37.037 -waveform {0 18.5} [get_nets {clk}]

# clk_sdram is deliberately not declared: it only drives the SDRAM clock pad, and
# its relationship to cpu_clk is a fixed phase shift chosen for SDRAM setup and
# hold, not something static analysis can check without a model of the part.

# The button is asynchronous and is synchronised in RTL.
set_false_path -from [get_ports {s1}]
