`include "definitions.vh"
`include "wb_defines.vh"

// =============================================================================
// Tang Nano 20K top level (GW2AR-18, 27 MHz crystal, in-package 64 Mbit SDRAM).
//
// Board-specific glue around soc_wb: PLL, power-on reset, pins and LEDs.
// The rPLL makes the 24 MHz system clock and a phase-shifted copy for the
// SDRAM. The SDRAM ports use the O_sdram_* / IO_sdram_dq names that Gowin
// binds to the in-package die, so they have no entries in the .cst file.
// led[0] is a hardware heartbeat; led[5:1] are driven by the LED PWM device.
// =============================================================================
module top_tang_nano_20k (
    input  wire        sys_clk,          // 27 MHz crystal
    input  wire        s1,               // button S1, not used

    // In-package SDRAM; names fixed by the Gowin toolchain
    output wire        O_sdram_clk,
    output wire        O_sdram_cke,
    output wire        O_sdram_cs_n,
    output wire        O_sdram_cas_n,
    output wire        O_sdram_ras_n,
    output wire        O_sdram_wen_n,
    inout  wire [31:0] IO_sdram_dq,
    output wire [10:0] O_sdram_addr,
    output wire [1:0]  O_sdram_ba,
    output wire [3:0]  O_sdram_dqm,

    output wire        uart_tx,
    input  wire        uart_rx,

    // microSD socket, SPI mode
    output wire        sd_cs_n,
    output wire        sd_sck,
    output wire        sd_mosi,
    input  wire        sd_miso,

    output wire [5:0]  led               // active low
);

    // ------------------------------------------------------------------------
    // Configuration checks. The PLL settings in gowin_rpll.v are fixed for a
    // 24 MHz system clock; any other SOC_CLK_HZ, or a configuration generated
    // for another board, fails elaboration on an unresolvable module name.
    // ------------------------------------------------------------------------
    localparam FREQ = `SOC_CLK_HZ;

`ifndef BOARD_TANGNANO20K
    soc_config_is_not_for_BOARD_TANGNANO20K u_board_check ();
`endif

    generate
        if (FREQ != 24_000_000) begin : g_clk_check
            soc_config_SOC_CLK_HZ_must_be_24000000_for_this_PLL u_clk_check ();
        end
    endgenerate

    // ------------------------------------------------------------------------
    // Clocking
    // ------------------------------------------------------------------------
    wire clk, clk_sdram, pll_lock;

    Gowin_rPLL pll (
        .clkin   (sys_clk),
        .clkout  (clk),                  // 24 MHz system clock
        .clkoutp (clk_sdram),            // phase shifted, SDRAM clock pad
        .lock    (pll_lock),
        .reset   (1'b0)
    );

    // ------------------------------------------------------------------------
    // Power-on reset: held for 65535 cycles of the PLL output (2.7 ms). The
    // counter cannot advance until the PLL produces a clock, so no lock
    // signal is needed.
    // ------------------------------------------------------------------------
    localparam POR_CYCLES = 16'hFFFF;

    reg [15:0] por_cnt = 16'd0;
    always @(posedge clk) begin
        if (por_cnt != POR_CYCLES)
            por_cnt <= por_cnt + 16'd1;
    end

    wire rst = (por_cnt != POR_CYCLES);

    // ------------------------------------------------------------------------
    // SoC
    // ------------------------------------------------------------------------
    wire        halted, trap_error, ebreak_halt, bus_error, decode_miss;
    wire [3:0]  trap_cause;
    wire        retire_valid, dbg_muldiv_stall;
    wire [31:0] retire_pc, retire_instruction, stage2_pc, stage2_instruction;
    wire [31:0] dbg_reg_data;
    wire [5:0]  led_pwm;

    soc_wb #(
        .FREQ      (FREQ),
        .BOOT_INIT ("bios.wordhex")      // found on the synthesis include path
    ) soc (
        .clk (clk), .clk_sdram (clk_sdram), .rst (rst),

        .SDRAM_DQ   (IO_sdram_dq),
        .SDRAM_A    (O_sdram_addr),
        .SDRAM_BA   (O_sdram_ba),
        .SDRAM_nCS  (O_sdram_cs_n),
        .SDRAM_nWE  (O_sdram_wen_n),
        .SDRAM_nRAS (O_sdram_ras_n),
        .SDRAM_nCAS (O_sdram_cas_n),
        .SDRAM_CLK  (O_sdram_clk),
        .SDRAM_CKE  (O_sdram_cke),
        .SDRAM_DQM  (O_sdram_dqm),

        .uart_tx (uart_tx),
        .uart_rx (uart_rx),
        .sd_cs_n (sd_cs_n),
        .sd_sck  (sd_sck),
        .sd_mosi (sd_mosi),
        .sd_miso (sd_miso),
        .led_pwm (led_pwm),

        .halted (halted), .trap_error (trap_error), .ebreak_halt (ebreak_halt),
        .trap_cause (trap_cause), .bus_error (bus_error),
        .decode_miss (decode_miss),

        .dbg_reg_addr (5'd10),
        .dbg_reg_data (dbg_reg_data),
        .retire_valid (retire_valid),
        .retire_pc (retire_pc),
        .retire_instruction (retire_instruction),
        .dbg_stage2_pc (stage2_pc),
        .dbg_stage2_instruction (stage2_instruction),
        .dbg_muldiv_stall (dbg_muldiv_stall),
        .dbg_csr_capture (), .dbg_csr_commit (), .dbg_csr_old (),
        .dbg_amo_read (), .dbg_amo_write (), .dbg_resv_valid (),
        .dbg_dc_hits (), .dbg_dc_misses (), .dbg_dc_evictions (),
        .dbg_dc_uncached (),
        .dbg_ic_hits (), .dbg_ic_misses (), .dbg_ic_uncached (),
        .dbg_dtlb_hits (), .dbg_dtlb_misses (), .dbg_dtlb_faults (),
        .dbg_itlb_hits (), .dbg_itlb_misses (), .dbg_itlb_faults ()
    );

    // ------------------------------------------------------------------------
    // LEDs. led[0] blinks at about 0.7 Hz whenever the clock and bitstream
    // are good, independent of software.
    // ------------------------------------------------------------------------
    reg [24:0] beat = 25'd0;
    always @(posedge clk) beat <= beat + 25'd1;

    wire [5:0] status = {led_pwm[5:1], beat[24]};

    assign led = ~status;

    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = |{s1, halted, trap_cause, decode_miss, retire_pc, retire_valid,
                    retire_instruction, stage2_pc, stage2_instruction,
                    dbg_reg_data, dbg_muldiv_stall, pll_lock, trap_error,
                    ebreak_halt, bus_error, led_pwm[0]};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
