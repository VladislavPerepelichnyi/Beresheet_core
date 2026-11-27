`include "wb_defines.vh"

// =============================================================================
// LED PWM controller and software interrupt lines, Wishbone slave.
//
//   +0x00 + 4*n  LEDn duty   DUTY_BITS wide; 0 = off, all ones = brightest
//   +0x20        SWIRQ       one bit per line, each a level into a PLIC source
//
// All channels share one free-running counter; channel n is on while
// counter < duty[n], so duty 0 is fully off. SWIRQ lets software raise a real
// external interrupt, which exercises the PLIC path end to end without a
// device. Reserved offsets read as zero.
// =============================================================================
module led_pwm_wb #(
    parameter CHANNELS  = 6,
    parameter DUTY_BITS = 8,
    parameter SW_LINES  = 4
)(
    input  wire clk,
    input  wire rst,

    input  wire [`WB_ADDR_WIDTH-1:0] wb_adr_i,
    input  wire [`WB_DATA_WIDTH-1:0] wb_dat_i,
    input  wire [`WB_SEL_WIDTH-1:0]  wb_sel_i,
    input  wire                      wb_we_i,
    input  wire                      wb_stb_i,
    input  wire                      wb_cyc_i,
    output reg  [`WB_DATA_WIDTH-1:0] wb_dat_o,
    output reg                       wb_ack_o,

    output wire [CHANNELS-1:0]       pwm_out,   // active high
    output wire [SW_LINES-1:0]       swirq_out  // level, to the PLIC
);

    localparam IDX_SWIRQ = 4'd8;      // +0x20
    localparam CH_W      = $clog2(CHANNELS);

    reg [DUTY_BITS-1:0] duty [0:CHANNELS-1];
    reg [DUTY_BITS-1:0] counter;
    reg [SW_LINES-1:0]  swirq;

    assign swirq_out = swirq;

    wire [3:0] idx = wb_adr_i[5:2];
    wire       sel = wb_stb_i & wb_cyc_i & ~wb_ack_o;

    genvar c;
    generate
        for (c = 0; c < CHANNELS; c = c + 1) begin : g_pwm
            assign pwm_out[c] = (counter < duty[c]);
        end
    endgenerate

    integer i;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            counter  <= {DUTY_BITS{1'b0}};
            swirq    <= {SW_LINES{1'b0}};
            wb_ack_o <= 1'b0;
            wb_dat_o <= {`WB_DATA_WIDTH{1'b0}};
            for (i = 0; i < CHANNELS; i = i + 1)
                duty[i] <= {DUTY_BITS{1'b0}};
        end
        else begin
            counter <= counter + {{(DUTY_BITS-1){1'b0}}, 1'b1};

            wb_ack_o <= sel;

            if (sel) begin
                if (wb_we_i) begin
                    if (idx < CHANNELS[3:0])
                        duty[idx[CH_W-1:0]] <= wb_dat_i[DUTY_BITS-1:0];
                    else if (idx == IDX_SWIRQ)
                        swirq <= wb_dat_i[SW_LINES-1:0];
                end

                if (idx < CHANNELS[3:0])
                    wb_dat_o <= {{(`WB_DATA_WIDTH-DUTY_BITS){1'b0}},
                                 duty[idx[CH_W-1:0]]};
                else if (idx == IDX_SWIRQ)
                    wb_dat_o <= {{(`WB_DATA_WIDTH-SW_LINES){1'b0}}, swirq};
                else
                    wb_dat_o <= {`WB_DATA_WIDTH{1'b0}};
            end
        end
    end

    // Whole-word registers with narrow fields; the region is decoded upstream.
    /* verilator lint_off UNUSEDSIGNAL */
    wire unused_sel = |wb_sel_i;
    wire unused_adr = |{wb_adr_i[31:6], wb_adr_i[1:0]};
    wire unused_dat = |wb_dat_i[31:8];
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
