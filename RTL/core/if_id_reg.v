`include "definitions.vh"

// =============================================================================
// IF/ID pipeline register (Fetch -> Decode/Execute).
//
// The valid bit is what makes a flush safe: without it a flushed slot would
// still carry a PC and a prediction, and Decode/Execute would report a bogus
// misprediction that redirects the PC in the middle of the recovery.
// =============================================================================
module if_id_reg (
    input  wire clk,
    input  wire rst,

    input  wire flush,                              // insert a bubble
    input  wire stall,                              // hold current contents

    input  wire [`BUS_WIDTH-1:0] instruction_in,
    input  wire [`BUS_WIDTH-1:0] pc_in,             // PC of instruction_in
    input  wire [`BUS_WIDTH-1:0] predicted_pc_in,   // what Fetch predicted next

    // Instruction page fault. The slot travels as valid but poisoned: it
    // reaches the trap logic with its own PC, and its instruction bits are
    // meaningless.
    input  wire                  fault_in,

    output reg  [`BUS_WIDTH-1:0] instruction_out,
    output reg  [`BUS_WIDTH-1:0] pc_out,
    output reg  [`BUS_WIDTH-1:0] predicted_pc_out,
    output reg                   fault_out,
    output reg                   valid_out
);

    always @(posedge clk or posedge rst) begin
        if (rst || flush) begin
            instruction_out  <= `I_NOP;
            pc_out           <= `PC_INIT_VALUE;
            predicted_pc_out <= `PC_INIT_VALUE;
            fault_out        <= 1'b0;
            valid_out        <= 1'b0;
        end
        else if (stall) begin
            instruction_out  <= instruction_out;
            pc_out           <= pc_out;
            predicted_pc_out <= predicted_pc_out;
            fault_out        <= fault_out;
            valid_out        <= valid_out;
        end
        else begin
            instruction_out  <= instruction_in;
            pc_out           <= pc_in;
            predicted_pc_out <= predicted_pc_in;
            fault_out        <= fault_in;
            valid_out        <= 1'b1;
        end
    end

endmodule
