`include "wb_defines.vh"

// =============================================================================
// Two-master Wishbone arbiter, fixed priority: data port (m0) over instruction
// port (m1).
//
// A pending data access always belongs to an instruction that has already
// been fetched, so data requests are finite and fixed priority cannot starve
// the fetch port.
//
// The grant is chosen combinationally on the first cycle of a transfer and
// latched until its ACK/ERR, so the bus is stable from STB to the response
// as the spec requires. Releasing on the response rather than on CYC matters
// because the fetch port holds CYC continuously. While m0 asserts LOCK the
// grant survives the response, keeping both halves of an RV32A
// read-modify-write indivisible (spec 2.2.3, LOCK_O). Each re-arbitration
// costs one idle bus cycle.
// =============================================================================
module wb_arbiter (
    input  wire clk,
    input  wire rst,

    // --- Master 0: data port, higher priority ---
    input  wire [`WB_ADDR_WIDTH-1:0] m0_adr_i,
    input  wire [`WB_DATA_WIDTH-1:0] m0_dat_i,
    input  wire [`WB_SEL_WIDTH-1:0]  m0_sel_i,
    input  wire                      m0_we_i,
    input  wire                      m0_stb_i,
    input  wire                      m0_cyc_i,
    input  wire                      m0_lock_i,
    output wire [`WB_DATA_WIDTH-1:0] m0_dat_o,
    output wire                      m0_ack_o,
    output wire                      m0_err_o,

    // --- Master 1: instruction port ---
    input  wire [`WB_ADDR_WIDTH-1:0] m1_adr_i,
    input  wire [`WB_DATA_WIDTH-1:0] m1_dat_i,
    input  wire [`WB_SEL_WIDTH-1:0]  m1_sel_i,
    input  wire                      m1_we_i,
    input  wire                      m1_stb_i,
    input  wire                      m1_cyc_i,
    output wire [`WB_DATA_WIDTH-1:0] m1_dat_o,
    output wire                      m1_ack_o,
    output wire                      m1_err_o,

    // --- Shared bus ---
    output wire [`WB_ADDR_WIDTH-1:0] s_adr_o,
    output wire [`WB_DATA_WIDTH-1:0] s_dat_o,
    output wire [`WB_SEL_WIDTH-1:0]  s_sel_o,
    output wire                      s_we_o,
    output wire                      s_stb_o,
    output wire                      s_cyc_o,
    input  wire [`WB_DATA_WIDTH-1:0] s_dat_i,
    input  wire                      s_ack_i,
    input  wire                      s_err_i
);

    localparam GNT_M0 = 1'b0;
    localparam GNT_M1 = 1'b1;

    reg  grant;                     // latched grant, valid while locked
    reg  locked;                    // a transfer is in flight

    wire want_m0 = m0_cyc_i;
    wire want_m1 = m1_cyc_i;

    wire new_grant = want_m0 ? GNT_M0 : GNT_M1;
    wire eff_grant = locked ? grant : new_grant;

    // Nothing reaches the slaves unless some master holds a grant
    wire active = locked | want_m0 | want_m1;
    wire sel_m0 = (eff_grant == GNT_M0);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            grant  <= GNT_M0;
            locked <= 1'b0;
        end
        else if (locked) begin
            // Release on the terminating response unless m0 holds LOCK. A
            // master must therefore drop LOCK on its final transfer.
            if ((s_ack_i | s_err_i) && !(sel_m0 && m0_lock_i))
                locked <= 1'b0;
        end
        else if (want_m0 | want_m1) begin
            grant  <= new_grant;
            locked <= 1'b1;
        end
    end

    assign s_adr_o = sel_m0 ? m0_adr_i : m1_adr_i;
    assign s_dat_o = sel_m0 ? m0_dat_i : m1_dat_i;
    assign s_sel_o = sel_m0 ? m0_sel_i : m1_sel_i;
    assign s_we_o  = sel_m0 ? m0_we_i  : m1_we_i;
    assign s_stb_o = active & (sel_m0 ? m0_stb_i : m1_stb_i);
    assign s_cyc_o = active & (sel_m0 ? m0_cyc_i : m1_cyc_i);

    // Responses are routed only to the granted master
    assign m0_dat_o = s_dat_i;
    assign m0_ack_o = active &  sel_m0 & s_ack_i;
    assign m0_err_o = active &  sel_m0 & s_err_i;

    assign m1_dat_o = s_dat_i;
    assign m1_ack_o = active & ~sel_m0 & s_ack_i;
    assign m1_err_o = active & ~sel_m0 & s_err_i;

endmodule
