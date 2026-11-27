`include "definitions.vh"

// =============================================================================
// Fetch stage: program counter and branch target buffer.
//
// The BTB is direct-mapped and indexed by pc[IDX+1:2]. A hit predicts "taken"
// to the stored target; a miss predicts "not taken" (pc + 4). Decode/Execute
// resolves the real outcome one cycle later and reports a misprediction, which
// costs exactly one bubble.
// =============================================================================
module pc_gen #(
    parameter IDX_WIDTH = `BTB_IDX_WIDTH          // 2**IDX_WIDTH BTB entries
)(
    input  wire clk,
    input  wire rst,

    // Pipeline control
    input  wire stall,                            // hold the PC and the BTB

    // Trap redirection. Outranks everything else: a misprediction reported in
    // the same cycle belongs to an instruction that is being flushed.
    input  wire                  trap_take,      // enter the handler
    input  wire [`BUS_WIDTH-1:0] trap_vector,    // mtvec or stvec
    input  wire                  trap_return,    // MRET or SRET
    input  wire [`BUS_WIDTH-1:0] trap_epc,       // mepc or sepc (return address)

    // Resolution feedback from Decode/Execute
    input  wire                  mispredict,
    input  wire                  actual_taken,
    input  wire [`BUS_WIDTH-1:0] correct_pc,      // where we should have gone
    input  wire [`BUS_WIDTH-1:0] branch_pc,       // PC of the resolved instruction

    output reg  [`BUS_WIDTH-1:0] pc_out,          // fetch address (virtual, to the I-TLB)
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
    // PC selection. Trap entry and return come first and are not blocked by
    // `stall`: the control unit only asserts them when no bus transaction is
    // outstanding. Otherwise the PC follows a resolved misprediction or the
    // BTB's prediction.
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
    // BTB update, deliberately independent of stall and of the trap signals.
    //
    // The BTB is only a hint: a wrong entry costs one bubble and is corrected
    // by the same mechanism. While stalled, stage 2 is held, so a repeated
    // update is identical; after a trap the flushed instruction re-executes and
    // writes the same entry. Keeping trap_take out of the write enables keeps
    // the BTB off the critical mem_stall -> trap path.
    //
    // A misaligned target is never allocated, so the BTB cannot predict a
    // misaligned fetch and manufacture traps.
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
