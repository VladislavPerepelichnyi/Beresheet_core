# =============================================================================
# Timing constraints, Tang Nano 20K.
#
# sys_clk is the 27 MHz crystal. The rPLL output `clk` runs at 24 MHz
# (41.667 ns) but is deliberately constrained at 37.037 ns (27 MHz): the
# router stops optimising once a constraint is met, so the tighter target buys
# real margin at the actual frequency. Real slack is therefore
# (41.667 ns + clock allowance) - arrival, not the slack reported against this
# constraint. Do not relax it towards 41.667 ns.
#
# clk_sdram only drives the SDRAM clock pad; its fixed phase offset from clk
# is a design parameter (gowin_rpll.v), not a path for static timing.
#
# Gowin's SDC parser does not accept line continuations; keep each constraint
# on one line.
# =============================================================================

create_clock -name sys_clk -period 37.037 -waveform {0 18.5} [get_ports {sys_clk}]

create_clock -name cpu_clk -period 37.037 -waveform {0 18.5} [get_nets {clk}]

# S1 is asynchronous and not used by the design
set_false_path -from [get_ports {s1}]
