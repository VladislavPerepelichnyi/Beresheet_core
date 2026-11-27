//Copyright (C)2014-2022 Gowin Semiconductor Corporation.
//All rights reserved.
//File Title: IP file
//GOWIN Version: V1.9.8.05
//Part Number: GW2A-LV18PG256C8/I7
//Device: GW2A-18C
//Created Time: Fri May 06 23:06:50 2022

`include "clk_config.vh"

module Gowin_rPLL (clkout, clkoutp, lock, reset, clkin);

output clkout;
output clkoutp;
output lock;
input reset;
input clkin;

wire clkoutp_o;
wire clkoutd_o;
wire clkoutd3_o;
wire gw_gnd;

assign gw_gnd = 1'b0;

rPLL rpll_inst (
    .CLKOUT(clkout),
    .LOCK(lock),
    .CLKOUTP(clkoutp),
    .CLKOUTD(clkoutd_o),
    .CLKOUTD3(clkoutd3_o),
    .RESET(reset),
    .RESET_P(gw_gnd),
    .CLKIN(clkin),
    .CLKFB(gw_gnd),
    .FBDSEL({gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd}),
    .IDSEL({gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd}),
    .ODSEL({gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd}),
    .PSDA({gw_gnd,gw_gnd,gw_gnd,gw_gnd}),
    .DUTYDA({gw_gnd,gw_gnd,gw_gnd,gw_gnd}),
    .FDLY({gw_gnd,gw_gnd,gw_gnd,gw_gnd})
);

// 27 Mhz. This is NESTang main clock frequency
// 27 MHz in, 24 MHz out:  27 * (FBDIV+1)/(IDIV+1) = 27 * 8/9 = 24.000 MHz
//
// The clock came down from 27 to buy timing margin for the MMU and the caches.
// 24 rather than 23.625 because the CLINT divides this by a whole number to make
// mtime tick at 1 MHz, and 23.625 would not - every OS timeout would be out by
// 2.7% and the device tree would be lying about timebase-frequency.
//
// The cost is the phase-detector frequency: 27/9 = 3.0 MHz, which is exactly the
// documented minimum for this rPLL rather than comfortably inside it. fVCO is
// 24 * 32 = 768 MHz, well within 400-1200.
// SOC_CLK_18M drops the core to 18 MHz, and it exists for one experiment.
//
// Userspace on this machine passes every test simulation can run - misaligned
// accesses and atomics from U-mode, demand paging, COW, signal delivery,
// integer division including the trivial and divide-by-zero cases - and then a
// libc binary hangs on real silicon. That pattern, correct in Verilator and
// wrong on the board, has bitten this project twice before, and the remaining
// difference simulation cannot model is gate delay.
//
// At 24 MHz the worst path arrives at 39.332 ns into a 41.667 ns period: real
// margin is +2.3 ns, or 5.6%. That is positive but thin for this part, and the
// worst path is the D-cache data RAM into the writeback register - the load
// data path, which is exactly what a libc exercises millions of times and a
// hand-written assembly probe touches a dozen times.
//
// 27 * 2/3 = 18 MHz exactly, so mtime still divides to 1 MHz on a whole number
// and no OS timeout is skewed. fVCO = 18 * 48 = 864 MHz, inside 400-1200. The
// phase detector runs at 27/3 = 9 MHz, comfortably above the 3 MHz minimum the
// 24 MHz setting sits exactly on.
`ifdef CLK18
defparam rpll_inst.FBDIV_SEL = 1;       // x2
defparam rpll_inst.IDIV_SEL  = 2;       // /3
defparam rpll_inst.ODIV_SEL  = 48;
`else
defparam rpll_inst.FBDIV_SEL = 7;
defparam rpll_inst.IDIV_SEL = 8;
defparam rpll_inst.ODIV_SEL = 32;
`endif

// 54 Mhz. You can go up to 66Mhz under current timing parameters
//defparam rpll_inst.FBDIV_SEL = 1;
//defparam rpll_inst.IDIV_SEL = 0;
//defparam rpll_inst.ODIV_SEL = 16;

defparam rpll_inst.FCLKIN = "27";
defparam rpll_inst.DYN_IDIV_SEL = "false";
defparam rpll_inst.DYN_FBDIV_SEL = "false";
defparam rpll_inst.DYN_ODIV_SEL = "false";
// The SDRAM clock's phase, and the one parameter here that no tool checks.
//
// "1010" is 10 of 16 steps = 225 degrees, inherited from the reference design
// where it was tuned at 27 MHz. It is deliberately unchanged: the SDRAM's data
// valid window opens a fixed number of nanoseconds after its own clock edge, and
// what has to hold is that the controller samples after that. At 27 MHz the
// controller sampled 37.04 - 23.15 = 13.9 ns after the SDRAM's edge; at 24 MHz
// the same 225 degrees gives 41.67 - 26.04 = 15.6 ns. More margin, not less.
//
// That is a model, not a measurement, and the memory test on hardware is what
// actually decides it. If 8 MB word-by-word ever fails after a clock change,
// this is the first thing to move - try "1001" (202.5 deg) and "1000" (180 deg).
defparam rpll_inst.PSDA_SEL = "1010";
defparam rpll_inst.DYN_DA_EN = "false";
defparam rpll_inst.DUTYDA_SEL = "1000";
defparam rpll_inst.CLKOUT_FT_DIR = 1'b1;
defparam rpll_inst.CLKOUTP_FT_DIR = 1'b1;
defparam rpll_inst.CLKOUT_DLY_STEP = 0;
defparam rpll_inst.CLKOUTP_DLY_STEP = 0;
defparam rpll_inst.CLKFB_SEL = "internal";
defparam rpll_inst.CLKOUT_BYPASS = "false";
defparam rpll_inst.CLKOUTP_BYPASS = "false";
defparam rpll_inst.CLKOUTD_BYPASS = "false";
defparam rpll_inst.DYN_SDIV_SEL = 2;
defparam rpll_inst.CLKOUTD_SRC = "CLKOUT";
defparam rpll_inst.CLKOUTD3_SRC = "CLKOUT";
defparam rpll_inst.DEVICE = "GW2A-18C";

endmodule //Gowin_rPLL
