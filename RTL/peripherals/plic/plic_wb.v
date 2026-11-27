`include "wb_defines.vh"

// =============================================================================
// PLIC - Platform-Level Interrupt Controller. A Wishbone slave.
//
// Derived from the AXI4-Lite version in plic_core.v: same architecture, same
// register map, rewritten for this bus. Register offsets follow
// doc/hardware/riscv-plic.pdf and are fixed by that specification, because
// existing drivers depend on them. Only the base address is ours to choose.
//
//   +0x000000 + 4*id    priority[id]       WARL, 0 disables the source
//   +0x001000           pending bits       READ-ONLY, bit 0 hardwired zero
//   +0x002000 + 0x80*c  enable[context]    bit per source
//   +0x200000 + 0x1000*c        threshold[context]
//   +0x200000 + 0x1000*c + 4    claim (read) / complete (write)
//
// A "context" is one privilege mode on one hart. Two exist here: context 0 is
// hart 0 machine mode, context 1 is hart 0 supervisor mode. Only context 0 is
// wired to anything today - the S-mode context is built now so that adding
// S-mode later is a wiring change rather than a redesign, and because that is
// the layout Linux and OpenSBI expect to find.
//
// Three mechanisms, and it is worth being clear which does what:
//
//   the gateway   converts a source's signal into exactly one request, and
//                 refuses to raise another until software says it is done.
//                 This is what stops a level-held line from re-interrupting
//                 forever.
//   the core      picks the highest-priority pending-and-enabled source and
//                 compares it against the context's threshold to decide
//                 whether to assert the external interrupt pin.
//   claim/complete  software reads the winner's ID (which atomically clears
//                 its pending bit) and later writes the ID back, which
//                 releases the gateway.
//
// Changes from the AXI version, both deliberate:
//
//   * `complete` is a one-cycle pulse rather than a stored value. Held as a
//     register it stays equal to the last completed ID forever, so the gateway
//     leaves its BUSY state immediately on every subsequent interrupt from that
//     source - the gate is permanently open after the first completion.
//   * pending bits are read-only, per the spec: "A pending bit in the PLIC core
//     can be cleared by setting the associated enable bit then performing a
//     claim." Allowing writes makes a convenient test hook and an
//     unfaithful device.
// =============================================================================
module plic_wb #(
    parameter NUM_SRCS     = 8,     // ids 0..NUM_SRCS-1; id 0 does not exist
    parameter NUM_CTXS     = 2,     // hart0 M-mode, hart0 S-mode
    parameter MAX_PRIORITY = 7
)(
    input  wire clk,
    input  wire rst,

    // --- Interrupt sources. Bit 0 is ignored: source 0 does not exist. ---
    input  wire [NUM_SRCS-1:0] src_irq,

    // --- One external-interrupt output per context ---
    output wire [NUM_CTXS-1:0] eip,

    // --- Wishbone slave ---
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

    localparam PRIORITY_BASE = 24'h000000;
    localparam PENDING_BASE  = 24'h001000;
    localparam ENABLE_BASE   = 24'h002000;
    localparam ENABLE_STRIDE = 24'h000080;
    localparam CONTEXT_BASE  = 24'h200000;
    localparam CONTEXT_STRIDE= 24'h001000;

    // ------------------------------------------------------------------------
    // State
    // ------------------------------------------------------------------------
    reg [PRIO_W-1:0] priority_r  [0:NUM_SRCS-1];
    reg [NUM_SRCS-1:0] pending_r;
    reg [NUM_SRCS-1:0] enable_r   [0:NUM_CTXS-1];
    reg [PRIO_W-1:0] threshold_r [0:NUM_CTXS-1];

    // Gateway, one per source
    localparam GW_IDLE = 2'd0, GW_BUSY = 2'd1;
    reg [1:0] gw_state [0:NUM_SRCS-1];

    // ------------------------------------------------------------------------
    // Bus decode
    // ------------------------------------------------------------------------
    wire [23:0] off = wb_adr_i[23:0];
    wire        sel = wb_stb_i & wb_cyc_i & ~wb_ack_o;

    // Ranges are tightened to what actually exists, so a read of a reserved
    // address returns zero rather than aliasing onto a real register.
    wire in_priority = (off < (PRIORITY_BASE + 4 * NUM_SRCS));
    wire in_pending  = (off >= PENDING_BASE) && (off < PENDING_BASE + 4);
    wire in_enable   = (off >= ENABLE_BASE)  &&
                       (off <  ENABLE_BASE + ENABLE_STRIDE * NUM_CTXS);
    // Only the first two words of a context block exist; the rest of the 4 KiB
    // is reserved, so it must not alias back onto claim/complete.
    wire in_context  = (off >= CONTEXT_BASE) &&
                       (off <  CONTEXT_BASE + CONTEXT_STRIDE * NUM_CTXS) &&
                       (off[11:3] == 9'd0);

    // Every stride here is a power of two, so the indices are bit fields rather
    // than divisions: 0x80 per enable block, 0x1000 per context block.
    wire [ID_W-1:0]  prio_idx = off[ID_W+1:2];
    wire [CTX_W-1:0] enb_ctx  = off[7+CTX_W-1:7];
    wire [CTX_W-1:0] ctx_idx  = off[12+CTX_W-1:12];
    wire             ctx_is_claim = off[2];     // +0 threshold, +4 claim/complete

    // ------------------------------------------------------------------------
    // The core's arbitration: highest priority wins, lowest ID breaks ties.
    //
    // Computed combinationally from the current pending and enable state, so a
    // claim read returns the winner as of that cycle rather than one cycle
    // stale. That matters because the claim also clears the pending bit - the
    // two have to refer to the same source.
    // ------------------------------------------------------------------------
    reg [PRIO_W-1:0] best_prio [0:NUM_CTXS-1];
    reg [ID_W-1:0]   best_id   [0:NUM_CTXS-1];

    integer c, s;
    always @(*) begin
        for (c = 0; c < NUM_CTXS; c = c + 1) begin
            best_prio[c] = {PRIO_W{1'b0}};
            best_id[c]   = {ID_W{1'b0}};
            // Strictly-greater keeps the lowest ID on a tie, which is the
            // tie-break the specification asks for.
            for (s = 1; s < NUM_SRCS; s = s + 1) begin
                if (pending_r[s] && enable_r[c][s] &&
                    (priority_r[s] > best_prio[c])) begin
                    best_prio[c] = priority_r[s];
                    best_id[c]   = s[ID_W-1:0];
                end
            end
        end
    end

    // "The PLIC will mask all PLIC interrupts of a priority less than or equal
    // to threshold", so the comparison is strictly greater. A threshold of zero
    // therefore permits every source with a non-zero priority - and a priority
    // of zero disables a source outright.
    genvar gc;
    generate
        for (gc = 0; gc < NUM_CTXS; gc = gc + 1) begin : g_eip
            assign eip[gc] = (best_prio[gc] > threshold_r[gc]);
        end
    endgenerate

    // ------------------------------------------------------------------------
    // Completion, as a pulse
    // ------------------------------------------------------------------------
    wire            complete_now = sel && wb_we_i && in_context && ctx_is_claim;
    wire [CTX_W-1:0] complete_ctx = ctx_idx;
    wire [ID_W-1:0] complete_id  = wb_dat_i[ID_W-1:0];

    // A claim is a read of the claim/complete register, and it is the only read
    // in this device with a side effect.
    wire claim_now = sel && !wb_we_i && in_context && ctx_is_claim;

    // ------------------------------------------------------------------------
    // Gateways.
    //
    // IDLE -> a request is latched into pending when the source asserts
    // BUSY -> no further requests until software completes this one. This is
    //         what stops a level-held line re-pending between claim and
    //         completion, which would be a livelock.
    //
    // Completion goes straight back to IDLE, so a source still asserted at
    // that point raises a new request on the next cycle. That is the
    // specified behaviour for level-sensitive sources, and every source on
    // this SoC is level-sensitive: a device still asserted after its handler
    // completed still needs service. A handler that completes without
    // servicing gets interrupted again, which is the driver's bug to see.
    // ------------------------------------------------------------------------
    reg [NUM_SRCS-1:0] gw_raise;      // one-cycle "set pending" per source

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
                        // Released by a completion naming this source on a
                        // context where it is enabled. The spec says a
                        // completion that matches no enabled source is
                        // silently ignored, which is what the enable test does.
                        //
                        // Back to IDLE even if the line is still high, and
                        // IDLE then raises a fresh request. That is the spec
                        // for a level-sensitive source: "if the interrupt is
                        // level-triggered and the interrupt is still asserted,
                        // a new interrupt request will be forwarded". An
                        // earlier GW_WAIT_LOW state waited for the line to fall
                        // first, which is edge behaviour, and a level device
                        // that is still asserted at completion never falls on
                        // its own - it is waiting to be serviced, and service
                        // needs the interrupt. Linux found it: a byte arriving
                        // at the 16550 while the shell's prompt was being
                        // transmitted held the line high through completion,
                        // the gateway sat in WAIT_LOW, and the console never
                        // read another character.
                        if (complete_now && (complete_id == k[ID_W-1:0]) &&
                            enable_r[complete_ctx][k])
                            gw_state[k] <= GW_IDLE;

                    default: gw_state[k] <= GW_IDLE;
                endcase
            end
        end
    end

    // ------------------------------------------------------------------------
    // Registers and the bus
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

            // --- gateways raise pending bits ---
            for (i = 1; i < NUM_SRCS; i = i + 1)
                if (gw_raise[i]) pending_r[i] <= 1'b1;

            // Source 0 does not exist; its pending bit is hardwired zero.
            pending_r[0] <= 1'b0;

            // --- writes ---
            if (sel && wb_we_i) begin
                if (in_priority) begin
                    // Writing priority[0] is ignored: source 0 does not exist.
                    if (prio_idx != {ID_W{1'b0}})
                        priority_r[prio_idx] <= wb_dat_i[PRIO_W-1:0];
                end
                else if (in_enable) begin
                    enable_r[enb_ctx] <= {wb_dat_i[NUM_SRCS-1:1], 1'b0};
                end
                else if (in_context) begin
                    if (!ctx_is_claim)
                        threshold_r[ctx_idx] <= wb_dat_i[PRIO_W-1:0];
                    // A completion write changes no register here: its whole
                    // effect is the gateway pulse above.
                end
                // in_pending: read-only, writes ignored
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

            // --- a claim clears the winner's pending bit ---
            //
            // Last, so it wins over the gateway raise above in the same cycle.
            // A source that is still asserted will be re-raised only after its
            // completion releases the gateway, which is exactly the ordering
            // the gateway exists to enforce.
            if (claim_now && best_id[ctx_idx] != {ID_W{1'b0}})
                pending_r[best_id[ctx_idx]] <= 1'b0;
        end
    end

    /* verilator lint_off UNUSEDSIGNAL */
    // Whole-word accesses only; byte lanes carry no meaning for these registers.
    // The upper address byte selected this slave in the interconnect, so it is
    // not decoded again here. The upper data bits are unused because priority
    // and threshold are narrow fields and the enable word is NUM_SRCS wide.
    wire unused_sel = |wb_sel_i;
    wire unused_src = src_irq[0];        // source 0 does not exist
    wire unused_adr = |wb_adr_i[31:24];
    wire unused_dat = |wb_dat_i[31:8];
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
