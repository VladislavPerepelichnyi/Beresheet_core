`include "wb_defines.vh"

// =============================================================================
// PLIC (Platform-Level Interrupt Controller), Wishbone slave.
//
// Register layout per the RISC-V PLIC specification:
//
//   +0x000000 + 4*id            priority[id]      0 disables the source
//   +0x001000                   pending bits      read-only, bit 0 is zero
//   +0x002000 + 0x80*ctx        enable[ctx]       one bit per source
//   +0x200000 + 0x1000*ctx      threshold[ctx]
//   +0x200000 + 0x1000*ctx + 4  claim (read) / complete (write)
//
// A context is one privilege mode of one hart: 0 = hart 0 M-mode, 1 = hart 0
// S-mode. Per source, a gateway turns the level input into one pending
// request and blocks further requests until software completes it. Per
// context, the highest-priority pending and enabled source (lowest ID on a
// tie) is compared against the threshold to drive eip. A claim returns that
// source's ID and clears its pending bit in the same cycle. All sources are
// level-sensitive.
// =============================================================================
module plic_wb #(
    parameter NUM_SRCS     = 8,     // IDs 0..NUM_SRCS-1; ID 0 does not exist
    parameter NUM_CTXS     = 2,
    parameter MAX_PRIORITY = 7
)(
    input  wire clk,
    input  wire rst,

    input  wire [NUM_SRCS-1:0] src_irq,       // bit 0 ignored
    output wire [NUM_CTXS-1:0] eip,           // one per context

    input  wire [`WB_ADDR_WIDTH-1:0] wb_adr_i,
    input  wire [`WB_DATA_WIDTH-1:0] wb_dat_i,
    input  wire [`WB_SEL_WIDTH-1:0]  wb_sel_i,
    input  wire                      wb_we_i,
    input  wire                      wb_stb_i,
    input  wire                      wb_cyc_i,
    output reg  [`WB_DATA_WIDTH-1:0] wb_dat_o,
    output reg                       wb_ack_o
);

    localparam PRIO_W = $clog2(MAX_PRIORITY + 1);
    localparam ID_W   = $clog2(NUM_SRCS);
    localparam CTX_W  = $clog2(NUM_CTXS);

    localparam PRIORITY_BASE  = 24'h000000;
    localparam PENDING_BASE   = 24'h001000;
    localparam ENABLE_BASE    = 24'h002000;
    localparam ENABLE_STRIDE  = 24'h000080;
    localparam CONTEXT_BASE   = 24'h200000;
    localparam CONTEXT_STRIDE = 24'h001000;

    // ------------------------------------------------------------------------
    // State
    // ------------------------------------------------------------------------
    reg [PRIO_W-1:0]   priority_r  [0:NUM_SRCS-1];
    reg [NUM_SRCS-1:0] pending_r;
    reg [NUM_SRCS-1:0] enable_r    [0:NUM_CTXS-1];
    reg [PRIO_W-1:0]   threshold_r [0:NUM_CTXS-1];

    localparam GW_IDLE = 2'd0, GW_BUSY = 2'd1;
    reg [1:0] gw_state [0:NUM_SRCS-1];

    // ------------------------------------------------------------------------
    // Bus decode. Ranges cover only implemented registers, so reserved
    // offsets read as zero instead of aliasing onto real ones.
    // ------------------------------------------------------------------------
    wire [23:0] off = wb_adr_i[23:0];
    wire        sel = wb_stb_i & wb_cyc_i & ~wb_ack_o;

    wire in_priority = (off < (PRIORITY_BASE + 4 * NUM_SRCS));
    wire in_pending  = (off >= PENDING_BASE) && (off < PENDING_BASE + 4);
    wire in_enable   = (off >= ENABLE_BASE)  &&
                       (off <  ENABLE_BASE + ENABLE_STRIDE * NUM_CTXS);
    wire in_context  = (off >= CONTEXT_BASE) &&
                       (off <  CONTEXT_BASE + CONTEXT_STRIDE * NUM_CTXS) &&
                       (off[11:3] == 9'd0);      // first two words of the block

    // All strides are powers of two, so indices are plain bit fields
    wire [ID_W-1:0]  prio_idx     = off[ID_W+1:2];
    wire [CTX_W-1:0] enb_ctx      = off[7+CTX_W-1:7];
    wire [CTX_W-1:0] ctx_idx      = off[12+CTX_W-1:12];
    wire             ctx_is_claim = off[2];      // +0 threshold, +4 claim

    // ------------------------------------------------------------------------
    // Arbitration, combinational from current state: a claim returns and
    // clears the winner of the same cycle, so the two always agree.
    // ------------------------------------------------------------------------
    reg [PRIO_W-1:0] best_prio [0:NUM_CTXS-1];
    reg [ID_W-1:0]   best_id   [0:NUM_CTXS-1];

    integer c, s;
    always @(*) begin
        for (c = 0; c < NUM_CTXS; c = c + 1) begin
            best_prio[c] = {PRIO_W{1'b0}};
            best_id[c]   = {ID_W{1'b0}};
            // Strictly greater: the lowest ID wins a tie
            for (s = 1; s < NUM_SRCS; s = s + 1) begin
                if (pending_r[s] && enable_r[c][s] &&
                    (priority_r[s] > best_prio[c])) begin
                    best_prio[c] = priority_r[s];
                    best_id[c]   = s[ID_W-1:0];
                end
            end
        end
    end

    // Interrupts with priority <= threshold are masked
    genvar gc;
    generate
        for (gc = 0; gc < NUM_CTXS; gc = gc + 1) begin : g_eip
            assign eip[gc] = (best_prio[gc] > threshold_r[gc]);
        end
    endgenerate

    // ------------------------------------------------------------------------
    // Claim and completion, each a single-cycle event
    // ------------------------------------------------------------------------
    wire             complete_now = sel && wb_we_i && in_context && ctx_is_claim;
    wire [CTX_W-1:0] complete_ctx = ctx_idx;
    wire [ID_W-1:0]  complete_id  = wb_dat_i[ID_W-1:0];

    wire claim_now = sel && !wb_we_i && in_context && ctx_is_claim;

    // ------------------------------------------------------------------------
    // Gateways
    //
    // IDLE: an asserted source sets its pending bit and moves to BUSY.
    // BUSY: no new request until a completion naming this source arrives on a
    //       context where it is enabled (other completions are ignored, per
    //       spec). The gateway then returns to IDLE even if the line is still
    //       high, so a level source that still needs service is forwarded
    //       again, as the spec requires for level-triggered interrupts.
    // ------------------------------------------------------------------------
    reg [NUM_SRCS-1:0] gw_raise;

    integer g;
    always @(*) begin
        gw_raise = {NUM_SRCS{1'b0}};
        for (g = 1; g < NUM_SRCS; g = g + 1)
            if ((gw_state[g] == GW_IDLE) && src_irq[g])
                gw_raise[g] = 1'b1;
    end

    integer k;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            for (k = 0; k < NUM_SRCS; k = k + 1) gw_state[k] <= GW_IDLE;
        end
        else begin
            for (k = 1; k < NUM_SRCS; k = k + 1) begin
                case (gw_state[k])
                    GW_IDLE:
                        if (src_irq[k]) gw_state[k] <= GW_BUSY;

                    GW_BUSY:
                        if (complete_now && (complete_id == k[ID_W-1:0]) &&
                            enable_r[complete_ctx][k])
                            gw_state[k] <= GW_IDLE;

                    default: gw_state[k] <= GW_IDLE;
                endcase
            end
        end
    end

    // ------------------------------------------------------------------------
    // Registers and bus access
    // ------------------------------------------------------------------------
    integer i, j;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            pending_r <= {NUM_SRCS{1'b0}};
            for (i = 0; i < NUM_SRCS; i = i + 1) priority_r[i]  <= {PRIO_W{1'b0}};
            for (j = 0; j < NUM_CTXS; j = j + 1) begin
                enable_r[j]    <= {NUM_SRCS{1'b0}};
                threshold_r[j] <= {PRIO_W{1'b0}};
            end
            wb_ack_o <= 1'b0;
            wb_dat_o <= {`WB_DATA_WIDTH{1'b0}};
        end
        else begin
            wb_ack_o <= sel;

            for (i = 1; i < NUM_SRCS; i = i + 1)
                if (gw_raise[i]) pending_r[i] <= 1'b1;
            pending_r[0] <= 1'b0;

            // --- writes ---
            if (sel && wb_we_i) begin
                if (in_priority) begin
                    if (prio_idx != {ID_W{1'b0}})
                        priority_r[prio_idx] <= wb_dat_i[PRIO_W-1:0];
                end
                else if (in_enable) begin
                    enable_r[enb_ctx] <= {wb_dat_i[NUM_SRCS-1:1], 1'b0};
                end
                else if (in_context) begin
                    // A completion write only releases the gateway (above)
                    if (!ctx_is_claim)
                        threshold_r[ctx_idx] <= wb_dat_i[PRIO_W-1:0];
                end
                // Pending bits are read-only
            end

            // --- reads ---
            if (sel) begin
                if (in_priority)
                    wb_dat_o <= {{(`WB_DATA_WIDTH-PRIO_W){1'b0}},
                                 priority_r[prio_idx]};
                else if (in_pending)
                    wb_dat_o <= {{(`WB_DATA_WIDTH-NUM_SRCS){1'b0}}, pending_r};
                else if (in_enable)
                    wb_dat_o <= {{(`WB_DATA_WIDTH-NUM_SRCS){1'b0}}, enable_r[enb_ctx]};
                else if (in_context) begin
                    if (ctx_is_claim)
                        wb_dat_o <= {{(`WB_DATA_WIDTH-ID_W){1'b0}}, best_id[ctx_idx]};
                    else
                        wb_dat_o <= {{(`WB_DATA_WIDTH-PRIO_W){1'b0}},
                                     threshold_r[ctx_idx]};
                end
                else
                    wb_dat_o <= {`WB_DATA_WIDTH{1'b0}};
            end

            // A claim clears the winner's pending bit. Placed last so it takes
            // precedence over a gateway raise in the same cycle; the gateway
            // is BUSY until completion, so the source cannot re-pend early.
            if (claim_now && best_id[ctx_idx] != {ID_W{1'b0}})
                pending_r[best_id[ctx_idx]] <= 1'b0;
        end
    end

    // Whole-word registers with narrow fields; the region is decoded upstream.
    /* verilator lint_off UNUSEDSIGNAL */
    wire unused_sel = |wb_sel_i;
    wire unused_src = src_irq[0];
    wire unused_adr = |wb_adr_i[31:24];
    wire unused_dat = |wb_dat_i[31:8];
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
