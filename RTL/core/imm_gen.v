`include "definitions.vh"

// =============================================================================
// Immediate generator. Bit layouts follow the instruction format table of the
// Unprivileged ISA manual. Every format is sign-extended from inst[31] except
// U-type, which is already a full 32-bit value.
// =============================================================================
module imm_gen (
    input  wire [`BUS_WIDTH-1:0] inst,
    input  wire [2:0]            imm_src,
    output reg  [`BUS_WIDTH-1:0] imm
);

    always @(*) begin
        case (imm_src)
            // imm[11:0] = inst[31:20]
            `IMM_I: imm = {{20{inst[31]}}, inst[31:20]};

            // imm[11:5] = inst[31:25], imm[4:0] = inst[11:7]
            `IMM_S: imm = {{20{inst[31]}}, inst[31:25], inst[11:7]};

            // imm[12|10:5] = inst[31|30:25], imm[4:1|11] = inst[11:8|7], imm[0] = 0
            `IMM_B: imm = {{19{inst[31]}}, inst[31], inst[7], inst[30:25], inst[11:8], 1'b0};

            // imm[20|10:1|11|19:12] = inst[31|30:21|20|19:12], imm[0] = 0
            `IMM_J: imm = {{11{inst[31]}}, inst[31], inst[19:12], inst[20], inst[30:21], 1'b0};

            // imm[31:12] = inst[31:12], low 12 bits zero
            `IMM_U: imm = {inst[31:12], 12'b0};

            // Constant zero, for the atomics: their address is rs1 with no
            // displacement, and inst[31:20] there holds funct5/aq/rl/rs2.
            `IMM_Z: imm = {`BUS_WIDTH{1'b0}};

            default: imm = {`BUS_WIDTH{1'b0}};
        endcase
    end

endmodule
