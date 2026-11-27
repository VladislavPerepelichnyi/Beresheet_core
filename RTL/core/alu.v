`include "definitions.vh"

// =============================================================================
// Arithmetic / logic unit. Purely combinational.
//
// Branch conditions are NOT evaluated here: a single "zero" flag cannot express
// the six RV32I branch tests. See branch_unit.v.
// =============================================================================
module alu (
    input  wire [`BUS_WIDTH-1:0] a,              // operand A: rs1, PC or zero
    input  wire [`BUS_WIDTH-1:0] b,              // operand B: rs2 or immediate
    input  wire [3:0]            alu_control,
    output reg  [`BUS_WIDTH-1:0] result
);

    always @(*) begin
        case (alu_control)
            `ALU_ADD:  result = a + b;
            `ALU_SUB:  result = a - b;
            `ALU_AND:  result = a & b;
            `ALU_OR:   result = a | b;
            `ALU_XOR:  result = a ^ b;

            // RV32 shifts use only the low 5 bits of the shift operand
            `ALU_SLL:  result = a << b[4:0];
            `ALU_SRL:  result = a >> b[4:0];
            `ALU_SRA:  result = $signed(a) >>> b[4:0];

            `ALU_SLT:  result = ($signed(a) < $signed(b)) ? 32'd1 : 32'd0;
            `ALU_SLTU: result = (a < b) ? 32'd1 : 32'd0;

            // Keeps the block fully specified so no latch is inferred
            default:   result = {`BUS_WIDTH{1'b0}};
        endcase
    end

endmodule

