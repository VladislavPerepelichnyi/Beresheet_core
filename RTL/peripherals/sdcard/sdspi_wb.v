`include "wb_defines.vh"

// =============================================================================
// SD card, SPI mode. A Wishbone slave wrapping ZipCPU's sdspi controller.
//
// The controller itself is unmodified third-party RTL (rtl/spi of the sdspi
// repository, kept byte-identical so a diff against upstream stays meaningful).
// This wrapper does two things it needs and our bus does not provide.
//
// 1. Classic to pipelined.
//
//    sdspi is a Wishbone B4 *pipelined* slave: it ties o_wb_stall low and treats
//    every cycle of STB as a new request. Our interconnect is classic standard,
//    where the master holds STB until ACK - which is at least two cycles.
//
//    Connected directly, every access would happen twice. Writing the command
//    register twice issues two SD commands; writing the FIFO twice pushes two
//    words. The controller would appear to work and then desynchronise, which is
//    a miserable thing to debug through an SPI bus.
//
//    So STB is converted to a single-cycle pulse and the answer is held until
//    our master takes it. Three cycles per access, which is nothing next to an
//    SPI transfer at 400 kHz.
//
// 2. The tie-offs.
//
//    i_bus_grant  the SPI bus is not shared, and OPT_SPI_ARBITRATION is off
//    i_card_detect this board's microSD socket has no detect pin, so the card
//                 is declared present. The controller still reports a removal it
//                 infers from the card itself.
//
// Register map, four 32-bit words, and the addresses are the controller's:
//
//   +0x00  CMD    command and status
//   +0x04  DATA   command argument, or the aux configuration word
//   +0x08  FIFO A
//   +0x0C  FIFO B
// =============================================================================
module sdspi_wb #(
    // The SPI clock is the system clock divided by (divider + 1). The card must
    // see 100-400 kHz until it is initialised, and firmware lowers this
    // afterwards; this is only the value out of reset.
    parameter [7:0] INITIAL_CLKDIV = 8'h7c    // 24 MHz / 125 = 192 kHz
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
    // Classic -> pipelined.
    //
    // start is one cycle: high when a transfer is asked for and neither a
    // request nor an answer is already in flight.
    // ------------------------------------------------------------------------
    reg  busy;
    wire core_ack;
    wire [`WB_DATA_WIDTH-1:0] core_dat;

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
    // The controller. Word addressed: our byte address >> 2 picks the register.
    // ------------------------------------------------------------------------
    sdspi #(
        .OPT_CARD_DETECT     (1'b1),
        .OPT_SPI_ARBITRATION (1'b0),
        .OPT_EXTRA_WB_CLOCK  (1'b0),
        .INITIAL_CLKDIV      (INITIAL_CLKDIV),
        // The default is 75, which is the SD spec's >=74 with one clock to
        // spare. That is enough for a card that has just been powered up, and
        // thin for one that has not: programming the FPGA resets this
        // controller but leaves the card powered and holding whatever state
        // the previous session left it in. The clock train is what pulls such
        // a card back to a known point before CMD0, so it is worth having
        // several times the minimum. 256 clocks at 144 kHz is 1.8 ms, which is
        // still nothing next to the 1500 ms startup delay the BIOS already
        // waits, and it costs one wider counter.
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
        .o_wb_stall  (),
        .o_wb_ack    (core_ack),
        .o_wb_data   (core_dat),

        .o_cs_n         (sd_cs_n),
        .o_sck          (sd_sck),
        .o_mosi         (sd_mosi),
        .i_miso         (sd_miso),
        // No detect pin on this socket, so the card is always "present". The
        // controller's own removal detection still works.
        .i_card_detect  (1'b1),

        .o_int       (irq),
        .i_bus_grant (1'b1),
        .o_debug     ()
    );

    /* verilator lint_off UNUSEDSIGNAL */
    // The controller is word addressed and never stalls, so neither the byte
    // lanes nor the upper address bits reach it.
    wire unused = |{wb_adr_i[`WB_ADDR_WIDTH-1:4], wb_adr_i[1:0]};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
