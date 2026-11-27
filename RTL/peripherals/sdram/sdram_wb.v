`include "wb_defines.vh"

// =============================================================================
// Wishbone slave adapter for sdram_core (Tang Nano 20K in-package SDRAM).
//
// Converts a Wishbone transfer into the controller's single-cycle rd/wr pulse
// and waits for completion, and issues auto-refresh from its own timer. The
// part needs 4096 refreshes per 64 ms (one per 15.6 us); refresh takes
// priority over bus requests, which simply wait for ACK.
//
// The controller raises `busy` one cycle after a command pulse, so the
// sequencer first waits for busy to rise (command accepted) and only then for
// it to fall (command complete).
// =============================================================================
module sdram_wb #(
    parameter FREQ = `SOC_CLK_HZ
)(
    input  wire clk,
    input  wire rst,

    // --- Wishbone slave ---
    input  wire [`WB_ADDR_WIDTH-1:0] wb_adr_i,
    input  wire [`WB_DATA_WIDTH-1:0] wb_dat_i,
    input  wire [`WB_SEL_WIDTH-1:0]  wb_sel_i,
    input  wire                      wb_we_i,
    input  wire                      wb_stb_i,
    input  wire                      wb_cyc_i,
    output reg  [`WB_DATA_WIDTH-1:0] wb_dat_o,
    output reg                       wb_ack_o,

    // --- To sdram_core ---
    output reg                       sd_rd,
    output reg                       sd_wr,
    output reg                       sd_refresh,
    output wire [22:0]               sd_addr,
    output wire [31:0]               sd_din,
    output wire [3:0]                sd_wmask,
    input  wire [31:0]               sd_dout,
    input  wire                      sd_data_ready,
    input  wire                      sd_busy
);

    // Refresh every 15 us, inside the 15.6 us requirement
    localparam integer REFRESH_CYCLES = FREQ / 1_000_000 * 15;
    localparam TIMER_W = 16;

    localparam ST_IDLE      = 3'd0;
    localparam ST_WAIT_BUSY = 3'd1;   // command issued, not yet accepted
    localparam ST_ACTIVE    = 3'd2;   // command in progress
    localparam ST_ACK       = 3'd3;   // ACK high; master drops STB

    localparam OP_READ    = 2'd0;
    localparam OP_WRITE   = 2'd1;
    localparam OP_REFRESH = 2'd2;

    reg [2:0]         state;
    reg [1:0]         op;
    reg [TIMER_W-1:0] refresh_timer;
    reg               refresh_pending;

    // Byte address within the 8 MB region
    assign sd_addr  = wb_adr_i[22:0];
    assign sd_din   = wb_dat_i;
    assign sd_wmask = wb_sel_i;

    wire request = wb_stb_i & wb_cyc_i;

    // ------------------------------------------------------------------------
    // Refresh timer, independent of bus activity
    // ------------------------------------------------------------------------
    wire refresh_issue = (state == ST_IDLE) && !sd_busy && refresh_pending;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            refresh_timer   <= {TIMER_W{1'b0}};
            refresh_pending <= 1'b0;
        end
        else begin
            if (refresh_timer >= REFRESH_CYCLES[TIMER_W-1:0]) begin
                refresh_timer   <= {TIMER_W{1'b0}};
                refresh_pending <= 1'b1;
            end
            else begin
                refresh_timer <= refresh_timer + {{(TIMER_W-1){1'b0}}, 1'b1};
            end

            if (refresh_issue)
                refresh_pending <= 1'b0;
        end
    end

    // ------------------------------------------------------------------------
    // Access sequencer
    // ------------------------------------------------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state      <= ST_IDLE;
            op         <= OP_READ;
            sd_rd      <= 1'b0;
            sd_wr      <= 1'b0;
            sd_refresh <= 1'b0;
            wb_ack_o   <= 1'b0;
            wb_dat_o   <= 32'd0;
        end
        else begin
            // Command strobes and ACK are single-cycle pulses
            sd_rd      <= 1'b0;
            sd_wr      <= 1'b0;
            sd_refresh <= 1'b0;
            wb_ack_o   <= 1'b0;

            case (state)
                // busy is also high during the controller's power-up and
                // initialisation sequence, which holds off the first access
                ST_IDLE: if (!sd_busy) begin
                    if (refresh_pending) begin
                        sd_refresh <= 1'b1;
                        op         <= OP_REFRESH;
                        state      <= ST_WAIT_BUSY;
                    end
                    else if (request) begin
                        if (wb_we_i) begin
                            sd_wr <= 1'b1;
                            op    <= OP_WRITE;
                        end
                        else begin
                            sd_rd <= 1'b1;
                            op    <= OP_READ;
                        end
                        state <= ST_WAIT_BUSY;
                    end
                end

                ST_WAIT_BUSY: if (sd_busy) state <= ST_ACTIVE;

                ST_ACTIVE: begin
                    if (op == OP_READ) begin
                        // dout32 is valid only while data_ready is high
                        if (sd_data_ready) begin
                            wb_dat_o <= sd_dout;
                            wb_ack_o <= 1'b1;
                            state    <= ST_ACK;
                        end
                    end
                    else if (!sd_busy) begin
                        if (op == OP_WRITE) begin
                            wb_ack_o <= 1'b1;
                            state    <= ST_ACK;
                        end
                        else begin
                            state <= ST_IDLE;   // refresh: no bus response
                        end
                    end
                end

                ST_ACK: state <= ST_IDLE;

                default: state <= ST_IDLE;
            endcase
        end
    end

    // The region is decoded upstream
    /* verilator lint_off UNUSEDSIGNAL */
    wire unused_adr = |wb_adr_i[31:23];
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
