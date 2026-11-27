`include "definitions.vh"

// =============================================================================
// EX/MEM pipeline register (Decode/Execute -> Mem/Writeback).
//
// Carries the ALU result, the store data, and the control signals the last
// stage needs. pc / instruction are for tracing only.
// =============================================================================
module ex_mem_reg (
    input  wire clk,
    input  wire rst,

    input  wire flush,
    input  wire stall,

    // --- Data ---
    input  wire [`BUS_WIDTH-1:0]      alu_result_in,
    input  wire [`BUS_WIDTH-1:0]      store_data_in,
    input  wire [`BUS_WIDTH-1:0]      link_pc_in,
    input  wire [`REG_ADDR_WIDTH-1:0] rd_addr_in,

    // --- Control ---
    input  wire       reg_we_in,
    input  wire       mem_we_in,
    input  wire       mem_re_in,
    input  wire [1:0] wb_sel_in,
    input  wire [2:0] funct3_in,                    // load / store width
    input  wire       is_atomic_in,                 // RV32A
    input  wire [4:0] amo_funct5_in,                // which atomic
    input  wire       valid_in,

    // --- Trace ---
    input  wire [`BUS_WIDTH-1:0] pc_in,
    input  wire [`BUS_WIDTH-1:0] instruction_in,

    output reg  [`BUS_WIDTH-1:0]      alu_result_out,
    output reg  [`BUS_WIDTH-1:0]      store_data_out,
    output reg  [`BUS_WIDTH-1:0]      link_pc_out,
    output reg  [`REG_ADDR_WIDTH-1:0] rd_addr_out,

    output reg        reg_we_out,
    output reg        mem_we_out,
    output reg        mem_re_out,
    output reg  [1:0] wb_sel_out,
    output reg  [2:0] funct3_out,
    output reg        is_atomic_out,
    output reg  [4:0] amo_funct5_out,
    output reg        valid_out,

    output reg  [`BUS_WIDTH-1:0] pc_out,
    output reg  [`BUS_WIDTH-1:0] instruction_out
);

    always @(posedge clk or posedge rst) begin
        if (rst || flush) begin
            alu_result_out  <= {`BUS_WIDTH{1'b0}};
            store_data_out  <= {`BUS_WIDTH{1'b0}};
            link_pc_out     <= {`BUS_WIDTH{1'b0}};
            rd_addr_out     <= {`REG_ADDR_WIDTH{1'b0}};
            reg_we_out      <= 1'b0;
            mem_we_out      <= 1'b0;
            mem_re_out      <= 1'b0;
            wb_sel_out      <= `WB_ALU;
            funct3_out      <= 3'b000;
            is_atomic_out   <= 1'b0;
            amo_funct5_out  <= 5'b00000;
            valid_out       <= 1'b0;
            pc_out          <= `PC_INIT_VALUE;
            instruction_out <= `I_NOP;
        end
        else if (stall) begin
            // Hold everything, including the write enables: the access is being
            // retried against a memory that is not ready yet.
            alu_result_out  <= alu_result_out;
            store_data_out  <= store_data_out;
            link_pc_out     <= link_pc_out;
            rd_addr_out     <= rd_addr_out;
            reg_we_out      <= reg_we_out;
            mem_we_out      <= mem_we_out;
            mem_re_out      <= mem_re_out;
            wb_sel_out      <= wb_sel_out;
            funct3_out      <= funct3_out;
            is_atomic_out   <= is_atomic_out;
            amo_funct5_out  <= amo_funct5_out;
            valid_out       <= valid_out;
            pc_out          <= pc_out;
            instruction_out <= instruction_out;
        end
        else begin
            alu_result_out  <= alu_result_in;
            store_data_out  <= store_data_in;
            link_pc_out     <= link_pc_in;
            rd_addr_out     <= rd_addr_in;
            reg_we_out      <= reg_we_in  & valid_in;
            mem_we_out      <= mem_we_in  & valid_in;
            mem_re_out      <= mem_re_in  & valid_in;
            wb_sel_out      <= wb_sel_in;
            funct3_out      <= funct3_in;
            is_atomic_out   <= is_atomic_in & valid_in;
            amo_funct5_out  <= amo_funct5_in;
            valid_out       <= valid_in;
            pc_out          <= pc_in;
            instruction_out <= instruction_in;
        end
    end

endmodule
