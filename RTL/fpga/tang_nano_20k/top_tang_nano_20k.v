`include "definitions.vh"
`include "wb_defines.vh"

// =============================================================================
// Tang Nano 20K top level: GW2AR-18, 27 MHz crystal, in-package 64 Mbit SDRAM.
//
// Everything platform independent lives in soc_wb. This file is only the board:
// clocking, reset, pin names, and status LEDs.
//
// Clocking. The PLL takes the 27 MHz crystal and produces 27 MHz again, which
// looks pointless until you notice the second output: clkoutp is the same
// frequency phase shifted, and the SDRAM needs that to sample in the middle of
// the controller's data window. The divider and phase values are copied
// verbatim from nand2mario's reference design, which is proven on this exact
// board with this exact controller - the lowest-risk starting point. Raising
// the clock later means re-tuning PSDA_SEL, and the SDRAM controller's timing
// parameters are only valid up to 66.7 MHz.
//
// The SDRAM ports use the "magic" names O_sdram_* / IO_sdram_dq that the Gowin
// tools recognise and wire to the in-package die. That is why there are no SDRAM
// entries in the .cst file.
//
// LEDs are active low on this board, and led[0] is a free-running heartbeat.
// That one bit is worth more than the rest put together during bring-up: if it
// blinks, the clock and the bitstream are good and any remaining fault is in the
// design or the firmware. If it does not, nothing downstream is worth debugging.
// =============================================================================
module top_tang_nano_20k (
    input  wire        sys_clk,          // 27 MHz crystal
    input  wire        s1,               // button, active low, manual reset

    // In-package SDRAM. Names are fixed by the Gowin toolchain.
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

    // --- microSD, wired for SPI mode ---
    output wire        sd_cs_n,
    output wire        sd_sck,
    output wire        sd_mosi,
    input  wire        sd_miso,

    output wire [5:0]  led               // active low on this board
);

    localparam FREQ = `SOC_CLK_HZ;

    // ------------------------------------------------------------------------
    // Clocking
    // ------------------------------------------------------------------------
    wire clk, clk_sdram, pll_lock;

    Gowin_rPLL pll (
        .clkin   (sys_clk),
        .clkout  (clk),                  // system clock, 27 MHz
        .clkoutp (clk_sdram),            // phase shifted, for the SDRAM
        .lock    (pll_lock),
        .reset   (1'b0)
    );

    // ------------------------------------------------------------------------
    // Reset
    //
    // A plain counter on the PLL output, and nothing else. That is deliberate:
    //
    //  * it is self-timing. The counter is clocked by the PLL output, so it
    //    cannot advance until the PLL is actually producing a clock, which is
    //    exactly the condition reset should wait for. No lock signal needed.
    //
    //  * it does not depend on the button. An earlier version held reset while
    //    S1 read low, which assumes the button is active low. The reference
    //    design for this board waits for s1 to go *high* before starting, so
    //    pressed is probably high here - and with that polarity the design sat
    //    in reset forever and transmitted nothing. A power-on reset should not
    //    depend on a guess about a button, so S1 is now only reported on an LED
    //    where its polarity can simply be read off the board.
    //
    // 65536 cycles is 2.4 ms at 27 MHz, far longer than the PLL needs to lock.
    // ------------------------------------------------------------------------
    localparam POR_CYCLES = 16'hFFFF;

    reg [15:0] por_cnt = 16'd0;
    always @(posedge clk) begin
        if (por_cnt != POR_CYCLES)
            por_cnt <= por_cnt + 16'd1;
    end

    wire rst = (por_cnt != POR_CYCLES);

    // Synchronise the button purely for display
    reg s1_sync0, s1_sync1;
    always @(posedge clk) begin
        s1_sync0 <= s1;
        s1_sync1 <= s1_sync0;
    end

    // ------------------------------------------------------------------------
    // The SoC
    // ------------------------------------------------------------------------
    wire        halted, trap_error, ebreak_halt, bus_error, decode_miss;
    wire [3:0]  trap_cause;
    wire        retire_valid, dbg_muldiv_stall;
    wire [31:0] retire_pc, retire_instruction, stage2_pc, stage2_instruction;
    wire [31:0] dbg_reg_data;
    wire [5:0]  led_pwm;
    wire [4:0]  dbg_flush;   // bring-up: {fl_state[1:0], fl_busy, ic_busy, dc_busy}

    soc_wb #(
        .FREQ      (FREQ),
        // The BIOS image, loaded into block RAM at configuration time.
        // Word oriented; see scripts/bin_to_wordhex.py.
        .BOOT_INIT ("bios.wordhex")
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
        .dbg_flush (dbg_flush),
        .dbg_dtlb_hits (), .dbg_dtlb_misses (), .dbg_dtlb_faults (),
        .dbg_itlb_hits (), .dbg_itlb_misses (), .dbg_itlb_faults (),

        .halted (halted), .trap_error (trap_error), .ebreak_halt (ebreak_halt),
        .trap_cause (trap_cause), .bus_error (bus_error),
        .decode_miss (decode_miss),

        .dbg_reg_addr (5'd10),                    // a0
        .dbg_reg_data (dbg_reg_data),
        .retire_valid (retire_valid),
        .retire_pc (retire_pc),
        .retire_instruction (retire_instruction),
        .dbg_stage2_pc (stage2_pc),
        .dbg_stage2_instruction (stage2_instruction),
        .dbg_muldiv_stall (dbg_muldiv_stall)
    );

    // ------------------------------------------------------------------------
    // Status LEDs
    //
    // The heartbeat is the single most useful signal on the board: if it is not
    // blinking, the problem is the clock or the bitstream, not the firmware, and
    // that distinction saves a lot of guessing before the serial link is trusted.
    // ------------------------------------------------------------------------
    reg [24:0] beat;
    always @(posedge clk) beat <= beat + 25'd1;


    // Five LEDs are driven by software through the PWM device, so the timer
    // interrupt can dim them. led[0] stays a hardware heartbeat: if that one is
    // not blinking, the clock or the bitstream is wrong and nothing about the
    // firmware is worth debugging yet. Keeping one LED outside software's reach
    // is worth more during bring-up than a sixth channel.
    wire [5:0] status = {led_pwm[5], led_pwm[4], led_pwm[3],
                         led_pwm[2], led_pwm[1],
                         beat[24]};

    assign led = ~status;       // active low

    // Not used on this board, but keeping them referenced documents that the
    // omission is deliberate rather than an oversight.
    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = |{halted, trap_cause, decode_miss, retire_pc, retire_valid,
                    retire_instruction, stage2_pc, stage2_instruction,
                    dbg_reg_data, dbg_muldiv_stall, pll_lock, trap_error,
                    ebreak_halt, bus_error, led_pwm[0], dbg_flush};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
