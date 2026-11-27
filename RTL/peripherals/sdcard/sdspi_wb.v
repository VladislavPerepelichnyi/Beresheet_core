`include "wb_defines.vh"

// =============================================================================
// SD card in SPI mode: Wishbone slave wrapping ZipCPU's sdspi controller.
//
// The controller sources (sdspi, llsdspi, spicmd, spirxdata, spitxdata) are
// unmodified upstream RTL. This wrapper adapts the bus and ties off unused
// inputs:
//
//   * sdspi is a Wishbone *pipelined* slave and treats every STB cycle as a
//     new request, while this bus holds STB until ACK. STB is therefore
//     reduced to a single-cycle start pulse and the response is held for the
//     master, so each access reaches the controller exactly once.
//   * The SPI bus is not shared (i_bus_grant = 1), and the socket has no
//     card-detect pin, so the card is reported present; the controller still
//     detects removal from the card's responses.
//
// Registers (controller layout): +0x0 CMD, +0x4 DATA, +0x8 FIFO A, +0xC FIFO B.
// =============================================================================
module sdspi_wb #(
    // Reset value of the SPI clock divider: f_sck = f_clk / (2 * (div + 1)).
    // The card must be clocked at 100-400 kHz until initialised.
    parameter [7:0] INITIAL_CLKDIV = 8'h7c
)(
    input  wire clk,
    input  wire rst,

    // --- Wishbone slave, classic standard ---
    input  wire [`WB_ADDR_WIDTH-1:0] wb_adr_i,
    input  wire [`WB_DATA_WIDTH-1:0] wb_dat_i,
    input  wire [`WB_SEL_WIDTH-1:0]  wb_sel_i,
    input  wire                      wb_we_i,
    input  wire                      wb_stb_i,
    input  wire                      wb_cyc_i,
    output reg  [`WB_DATA_WIDTH-1:0] wb_dat_o,
    output reg                       wb_ack_o,

    // --- SPI pins ---
    output wire sd_cs_n,
    output wire sd_sck,
    output wire sd_mosi,
    input  wire sd_miso,

    output wire irq
);

    // ------------------------------------------------------------------------
    // Classic to pipelined: one start pulse per transfer, issued only when
    // no request or response is already in flight.
    // ------------------------------------------------------------------------
    reg  busy;
    wire core_ack;
    wire [`WB_DATA_WIDTH-1:0] core_dat;
    /* verilator lint_off UNUSEDSIGNAL */
    wire        core_stall;                 // always low in this configuration
    wire [31:0] core_debug;
    /* verilator lint_on UNUSEDSIGNAL */

    wire start = wb_stb_i & wb_cyc_i & ~busy & ~wb_ack_o;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            busy     <= 1'b0;
            wb_ack_o <= 1'b0;
            wb_dat_o <= {`WB_DATA_WIDTH{1'b0}};
        end
        else begin
            wb_ack_o <= 1'b0;

            if (start)
                busy <= 1'b1;
            else if (busy && core_ack) begin
                busy     <= 1'b0;
                wb_ack_o <= 1'b1;
                wb_dat_o <= core_dat;
            end
        end
    end

    // ------------------------------------------------------------------------
    // Controller, word addressed
    // ------------------------------------------------------------------------
    sdspi #(
        .OPT_CARD_DETECT     (1'b1),
        .OPT_SPI_ARBITRATION (1'b0),
        .OPT_EXTRA_WB_CLOCK  (1'b0),
        .INITIAL_CLKDIV      (INITIAL_CLKDIV),
        // The SD spec requires at least 74 clocks before CMD0. Reprogramming
        // the FPGA resets the controller but not the card, so a longer train
        // is used to bring a card left mid-transaction back to a known state.
        .STARTUP_CLOCKS      (256)
    ) sd (
        .i_clk       (clk),
        .i_sd_reset  (rst),

        .i_wb_cyc    (wb_cyc_i),
        .i_wb_stb    (start),
        .i_wb_we     (wb_we_i),
        .i_wb_addr   (wb_adr_i[3:2]),
        .i_wb_data   (wb_dat_i),
        .i_wb_sel    (wb_sel_i),
        .o_wb_stall  (core_stall),
        .o_wb_ack    (core_ack),
        .o_wb_data   (core_dat),

        .o_cs_n         (sd_cs_n),
        .o_sck          (sd_sck),
        .o_mosi         (sd_mosi),
        .i_miso         (sd_miso),
        .i_card_detect  (1'b1),         // no detect pin on this socket

        .o_int       (irq),
        .i_bus_grant (1'b1),
        .o_debug     (core_debug)
    );

    // The controller is word addressed and never stalls
    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = |{wb_adr_i[`WB_ADDR_WIDTH-1:4], wb_adr_i[1:0]};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
