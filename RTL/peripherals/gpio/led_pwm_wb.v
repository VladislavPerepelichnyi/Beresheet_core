`include "wb_defines.vh"

// =============================================================================
// LED brightness controller. A Wishbone slave, and the simplest possible
// example of adding your own MMIO device.
//
// One 32-bit register per LED, each holding an 8-bit duty value:
//
//   +0x00  LED0 duty   0x00 = off, 0xFF = full brightness
//   +0x04  LED1 duty
//   ...    one word per channel
//   +0x20  SWIRQ       one bit per software-triggered interrupt line
//
// SWIRQ has nothing to do with LEDs; it lives here because this is the SoC's
// general-purpose register block. Each bit drives a PLIC interrupt source
// directly, so software can raise and lower a real external interrupt without
// any device having to misbehave first. That makes the PLIC's priority,
// threshold and claim/complete behaviour testable, and it is a genuinely useful
// thing to have on a board - it is how you check an interrupt path end to end
// when the device that normally drives it is the thing you suspect.
//
// The PWM is in hardware rather than in software, and that choice is the point
// of the example. Software could toggle the pins from a timer interrupt, but it
// would need an interrupt every few microseconds to get a flicker-free result,
// and the CPU would do nothing else. Here the interrupt only has to run often
// enough for the *eye* - a hundred times a second - and the hardware handles the
// kilohertz part. Putting the fast, dumb, regular work in hardware and the slow,
// interesting work in software is most of what peripheral design is.
//
// The free-running counter is shared by all channels, so they all switch on
// together at the start of each period. That is fine for LEDs. A real design
// driving inductive loads would stagger the phases to spread the current.
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
    // A read-only word for whatever bring-up needs to see. It lives here for
    // the same reason SWIRQ does: this is the SoC's general-purpose corner, and
    // a machine that hangs with no way to ask it why is a machine that gets
    // debugged by guessing.
    input  wire [`WB_DATA_WIDTH-1:0] dbg_word,
    output reg  [`WB_DATA_WIDTH-1:0] wb_dat_o,
    output reg                       wb_ack_o,

    output wire [CHANNELS-1:0]       pwm_out,   // active high
    output wire [SW_LINES-1:0]       swirq_out  // level, straight to the PLIC
);

    localparam IDX_SWIRQ = 4'd8;      // +0x20
    localparam IDX_DBG   = 4'd12;     // +0x30, read only
    localparam CH_W      = $clog2(CHANNELS);

    reg [DUTY_BITS-1:0] duty [0:CHANNELS-1];
    reg [DUTY_BITS-1:0] counter;
    reg [SW_LINES-1:0]  swirq;

    assign swirq_out = swirq;

    // Word index within the region: one register per channel, then SWIRQ.
    wire [3:0] idx = wb_adr_i[5:2];
    wire       sel = wb_stb_i & wb_cyc_i & ~wb_ack_o;

    // A channel is on for `duty` counts out of 2**DUTY_BITS. Comparing with <
    // rather than <= is what makes duty = 0 mean fully off; with <= it would
    // still be on for one count in every 256, which is visible on an LED in a
    // dark room.
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
                else if (idx == IDX_DBG)
                    wb_dat_o <= dbg_word;
                else
                    wb_dat_o <= {`WB_DATA_WIDTH{1'b0}};
            end
        end
    end

    /* verilator lint_off UNUSEDSIGNAL */
    // Duty values are written as whole words; byte lanes carry no extra meaning.
    // The region was already decoded upstream, so only the word index matters.
    wire unused_sel = |wb_sel_i;
    wire unused_adr = |{wb_adr_i[31:6], wb_adr_i[1:0]};
    wire unused_dat = |wb_dat_i[31:8];      // duty and SWIRQ are narrow fields
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
