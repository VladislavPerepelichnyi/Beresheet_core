`include "definitions.vh"

// =============================================================================
// Architectural register file: 32 x 32-bit, two read ports, one write port.
//
// The read ports include an internal write-through bypass. In this 3-stage
// pipeline the Mem/Writeback stage drives the write port combinationally while
// the very next instruction is reading in Decode/Execute, so the bypass alone
// resolves every distance-1 RAW hazard - no separate forwarding unit needed.
// x0 is hardwired to zero on both read and write.
// =============================================================================
module file_register (
    input  wire clk,
    input  wire rst,

    // Read ports (Decode/Execute stage)
    input  wire [`REG_ADDR_WIDTH-1:0] raddr1,
    input  wire [`REG_ADDR_WIDTH-1:0] raddr2,
    output reg  [`BUS_WIDTH-1:0]      rdata1,
    output reg  [`BUS_WIDTH-1:0]      rdata2,

    // Write port (Mem/Writeback stage)
    input  wire                       we,
    input  wire [`REG_ADDR_WIDTH-1:0] waddr,
    input  wire [`BUS_WIDTH-1:0]      wdata,

    // Third read port, used only by the testbench to inspect results
    input  wire [`REG_ADDR_WIDTH-1:0] dbg_addr,
    output wire [`BUS_WIDTH-1:0]      dbg_data
);

    reg [`BUS_WIDTH-1:0] reg_file [0:`REG_NUM-1];

    integer i;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            for (i = 0; i < `REG_NUM; i = i + 1)
                reg_file[i] <= {`BUS_WIDTH{1'b0}};
        end
        else if (we && (waddr != {`REG_ADDR_WIDTH{1'b0}})) begin
            reg_file[waddr] <= wdata;
        end
    end

    // Read port 1
    always @(*) begin
        if (raddr1 == {`REG_ADDR_WIDTH{1'b0}})   rdata1 = {`BUS_WIDTH{1'b0}};
        else if (we && (waddr == raddr1))        rdata1 = wdata;  // write-through bypass
        else                                     rdata1 = reg_file[raddr1];
    end

    // Read port 2
    always @(*) begin
        if (raddr2 == {`REG_ADDR_WIDTH{1'b0}})   rdata2 = {`BUS_WIDTH{1'b0}};
        else if (we && (waddr == raddr2))        rdata2 = wdata;  // write-through bypass
        else                                     rdata2 = reg_file[raddr2];
    end

    // Debug read port: no bypass, shows only committed state
    assign dbg_data = (dbg_addr == {`REG_ADDR_WIDTH{1'b0}}) ? {`BUS_WIDTH{1'b0}}
                                                            : reg_file[dbg_addr];

    // ------------------------------------------------------------------------
    // Named aliases so the ABI register names show up in the waveform viewer.
    // Not driven anywhere else, hence the lint waiver.
    // ------------------------------------------------------------------------
    /* verilator lint_off UNUSEDSIGNAL */
    wire [31:0] x1_ra  = reg_file[1];
    wire [31:0] x2_sp  = reg_file[2];
    wire [31:0] x3_gp  = reg_file[3];
    wire [31:0] x4_tp  = reg_file[4];
    wire [31:0] x5_t0  = reg_file[5];
    wire [31:0] x6_t1  = reg_file[6];
    wire [31:0] x7_t2  = reg_file[7];
    wire [31:0] x8_s0  = reg_file[8];
    wire [31:0] x9_s1  = reg_file[9];
    wire [31:0] x10_a0 = reg_file[10];
    wire [31:0] x11_a1 = reg_file[11];
    wire [31:0] x12_a2 = reg_file[12];
    wire [31:0] x13_a3 = reg_file[13];
    wire [31:0] x14_a4 = reg_file[14];
    wire [31:0] x15_a5 = reg_file[15];
    wire [31:0] x16_a6 = reg_file[16];
    wire [31:0] x17_a7 = reg_file[17];
    wire [31:0] x18_s2 = reg_file[18];
    wire [31:0] x19_s3 = reg_file[19];
    wire [31:0] x20_s4 = reg_file[20];
    wire [31:0] x21_s5 = reg_file[21];
    wire [31:0] x22_s6 = reg_file[22];
    wire [31:0] x23_s7 = reg_file[23];
    wire [31:0] x24_s8 = reg_file[24];
    wire [31:0] x25_s9 = reg_file[25];
    wire [31:0] x26_s10 = reg_file[26];
    wire [31:0] x27_s11 = reg_file[27];
    wire [31:0] x28_t3 = reg_file[28];
    wire [31:0] x29_t4 = reg_file[29];
    wire [31:0] x30_t5 = reg_file[30];
    wire [31:0] x31_t6 = reg_file[31];
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
