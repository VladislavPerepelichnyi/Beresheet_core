`include "wb_defines.vh"

// =============================================================================
// Two-master Wishbone arbiter. Data port wins over instruction port.
//
// Why data wins: a data access is already blocking a retiring instruction,
// while a stalled fetch only delays work that has not started. Giving the
// instruction port priority instead can deadlock a pipeline whose fetch runs
// ahead of a store it depends on.
//
// Grant is held for the whole transfer, because Wishbone requires the master's
// outputs to stay stable from STB until ACK. Release happens on the ACK, not on
// CYC dropping: the instruction port wants a fetch on every cycle and so holds
// CYC permanently, and waiting for it to drop would starve the data port
// forever. Since every STB gets exactly one response, releasing on the response
// is precise.
//
// LOCK is the one exception, and it is why the atomics work. An RV32A atomic is
// two transfers that must be indivisible, so the data port asserts LOCK across
// both and the grant survives the first ACK - "the INTERCON does not grant the
// bus to any other MASTER until the current MASTER negates LOCK_O or CYC_O"
// (spec section 2.2.3). The hold is bounded at two transfers, so the
// instruction port cannot starve.
//
// Re-arbitration therefore costs one idle cycle between transfers. That is a
// deliberate trade: it also guarantees a clean gap between transactions, which
// keeps slaves that dislike back-to-back strobes happy.
//
// This cannot deadlock even though priority is strict. A data access only
// exists because some instruction reached stage 3, which required a fetch, so
// data requests are always finite and the fetch port always gets the bus back.
//
// The grant must be settled before any strobe reaches a slave. An earlier
// version registered the grant but still let STB through while idle, so a
// transfer could begin under the *previous* grant and its ACK would then be
// routed to the newly granted master - the data port silently received the
// instruction fetch's data. Two things prevent that here: `active` gates STB and
// CYC so nothing starts until a grant exists, and the grant is chosen
// combinationally on the starting cycle and latched for the rest of the
// transfer, so the bus is stable from the first cycle without costing one.
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
    input  wire                      m0_lock_i,     // uninterruptible cycle
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

    // --- Shared bus out ---
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
    reg  locked;                    // a transfer is in flight, do not re-grant

    wire want_m0 = m0_cyc_i;
    wire want_m1 = m1_cyc_i;

    // Who would win if we arbitrated right now. Data port first.
    wire new_grant = want_m0 ? GNT_M0 : GNT_M1;

    // The grant in force this cycle: latched mid-transfer, fresh otherwise
    wire eff_grant = locked ? grant : new_grant;

    // Nothing reaches the slaves unless a grant is in force
    wire active = locked | want_m0 | want_m1;

    wire sel_m0 = (eff_grant == GNT_M0);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            grant  <= GNT_M0;
            locked <= 1'b0;
        end
        else if (locked) begin
            // Release on the response that terminates this transfer, unless the
            // granted master still has LOCK asserted - which says another
            // transfer follows in the same cycle. A master must therefore
            // negate LOCK on its final transfer, or the grant is never given
            // back; see the note in mem_wb.v.
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

    // Responses go only to the granted master, so the other one keeps waiting
    // rather than mistaking someone else's ACK for its own.
    assign m0_dat_o = s_dat_i;
    assign m0_ack_o = active &  sel_m0 & s_ack_i;
    assign m0_err_o = active &  sel_m0 & s_err_i;

    assign m1_dat_o = s_dat_i;
    assign m1_ack_o = active & ~sel_m0 & s_ack_i;
    assign m1_err_o = active & ~sel_m0 & s_err_i;

endmodule
