`include "definitions.vh"

// =============================================================================
// Branch condition evaluator for the six RV32I conditional branches.
// Lives in the Decode/Execute stage next to the ALU, so a branch never has to
// borrow the ALU result.
// =============================================================================
module branch_unit (
    input  wire [2:0]            funct3,
    input  wire [`BUS_WIDTH-1:0] rs1_data,
    input  wire [`BUS_WIDTH-1:0] rs2_data,
    output reg                   take_branch,
    output reg                   illegal_funct3  // funct3 = 010 / 011 are unused
);

    wire equal      = (rs1_data == rs2_data);
    wire less_signed   = ($signed(rs1_data) < $signed(rs2_data));
    wire less_unsigned = (rs1_data < rs2_data);

    always @(*) begin
        illegal_funct3 = 1'b0;
        case (funct3)
            `F3_BEQ:  take_branch =  equal;
            `F3_BNE:  take_branch = !equal;
            `F3_BLT:  take_branch =  less_signed;
            `F3_BGE:  take_branch = !less_signed;
            `F3_BLTU: take_branch =  less_unsigned;
            `F3_BGEU: take_branch = !less_unsigned;
            default: begin
                take_branch    = 1'b0;
                illegal_funct3 = 1'b1;
            end
        endcase
    end

endmodule
