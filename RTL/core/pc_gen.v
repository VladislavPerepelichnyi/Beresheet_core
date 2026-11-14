`include "definitions.vh"

// =============================================================================
// Fetch stage: program counter and branch target buffer.
//
// The BTB is direct-mapped and indexed by pc[IDX+1:2]. A hit predicts "taken"
// to the stored target; a miss predicts "not taken" (pc + 4). Decode/Execute
// resolves the real outcome one cycle later and reports a misprediction, which
// costs exactly one bubble.
//
// The earlier fully-associative version scanned all entries in a combinational
// for-loop; that does not map to hardware at any useful size and could also
// allocate the same PC twice. Direct-mapped tag+valid lookup replaces it.
// =============================================================================
module pc_gen #(
    parameter IDX_WIDTH = `BTB_IDX_WIDTH          // 2**IDX_WIDTH BTB entries
)(
    input  wire clk,
    input  wire rst,

    // Pipeline control
    input  wire stall,                            // hold the PC and the BTB

    // Trap redirection. Outranks everything else: a trap must be taken now, and
    // any misprediction being reported in the same cycle belongs to an
    // instruction that is about to be flushed anyway.
    input  wire                  trap_take,      // enter the handler
    input  wire [`BUS_WIDTH-1:0] trap_vector,    // mtvec
    input  wire                  trap_return,    // MRET
    input  wire [`BUS_WIDTH-1:0] trap_epc,       // mepc

    // Resolution feedback from Decode/Execute
    input  wire                  mispredict,
    input  wire                  actual_taken,
    input  wire [`BUS_WIDTH-1:0] correct_pc,      // where we should have gone
    input  wire [`BUS_WIDTH-1:0] branch_pc,       // PC of the resolved instruction

    output reg  [`BUS_WIDTH-1:0] pc_out,          // address presented to the I-memory
    output wire [`BUS_WIDTH-1:0] predicted_pc,    // prediction handed to IF/ID
    output wire                  misaligned_fetch
);

    localparam TAG_WIDTH   = `BUS_WIDTH - IDX_WIDTH - 2;
    localparam BTB_ENTRIES = 1 << IDX_WIDTH;

    reg                  btb_valid  [0:BTB_ENTRIES-1];
    reg [TAG_WIDTH-1:0]  btb_tag    [0:BTB_ENTRIES-1];
    reg [`BUS_WIDTH-1:0] btb_target [0:BTB_ENTRIES-1];

    // Lookup for the PC currently being fetched
    wire [IDX_WIDTH-1:0] fetch_idx = pc_out[IDX_WIDTH+1:2];
    wire [TAG_WIDTH-1:0] fetch_tag = pc_out[`BUS_WIDTH-1:IDX_WIDTH+2];
    wire                 btb_hit   = btb_valid[fetch_idx] && (btb_tag[fetch_idx] == fetch_tag);

    // Lookup for the instruction being resolved, so we can update its entry
    wire [IDX_WIDTH-1:0] update_idx = branch_pc[IDX_WIDTH+1:2];
    wire [TAG_WIDTH-1:0] update_tag = branch_pc[`BUS_WIDTH-1:IDX_WIDTH+2];

    assign predicted_pc     = btb_hit ? btb_target[fetch_idx] : (pc_out + 32'd4);
    assign misaligned_fetch = (pc_out[1:0] != 2'b00);

    // ------------------------------------------------------------------------
    // PC selection.
    //
    // Trap entry and return are checked before `stall`, unlike everything else.
    // A trap is not a request that can wait: the instruction that caused it is
    // being flushed this cycle, so a deferred redirect would have nothing left
    // to derive itself from. The control unit holds trap_take off until no bus
    // transaction is outstanding, which is what makes that safe.
    // ------------------------------------------------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst)                 pc_out <= `PC_INIT_VALUE;
        else if (trap_take)      pc_out <= trap_vector;
        else if (trap_return)    pc_out <= trap_epc;
        else if (stall)          pc_out <= pc_out;
        else if (mispredict)     pc_out <= correct_pc;
        else                     pc_out <= predicted_pc;
    end

    // ------------------------------------------------------------------------
    // BTB update, deliberately in its own block with no dependence on stall or
    // on the trap signals.
    //
    // The BTB is a hint, not state: a wrong entry costs one bubble and is then
    // corrected by the very mechanism that wrote it. So it does not need to be
    // suppressed when the pipeline is frozen (stage 2 is held, so the inputs
    // are stable and a repeated update is identical), and it does not need to
    // be suppressed on a trap (the flushed instruction re-executes after MRET
    // and would produce the same entry).
    //
    // Separating them matters for timing, not tidiness. Sharing one priority
    // chain put trap_take - and through it mem_stall, and through that the
    // EX/MEM valid bit - in front of the BTB's write enables, and that was
    // measured as the critical path of the whole design.
    //
    // The one thing worth guarding is allocation with a misaligned target: a
    // stale entry pointing at an odd address would predict a misaligned fetch
    // and manufacture traps. correct_pc's low bits are already here, so the
    // check is free.
    // ------------------------------------------------------------------------
    wire target_aligned = (correct_pc[1:0] == 2'b00);

    integer k;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            for (k = 0; k < BTB_ENTRIES; k = k + 1)
                btb_valid[k] <= 1'b0;
        end
        else if (mispredict) begin
            if (actual_taken && target_aligned) begin
                // Predicted not-taken but the jump happened: record the target
                btb_valid[update_idx]  <= 1'b1;
                btb_tag[update_idx]    <= update_tag;
                btb_target[update_idx] <= correct_pc;
            end
            else if (!actual_taken &&
                     btb_valid[update_idx] && (btb_tag[update_idx] == update_tag)) begin
                // Predicted taken but it fell through: drop the stale entry
                btb_valid[update_idx] <= 1'b0;
            end
        end
    end

endmodule
