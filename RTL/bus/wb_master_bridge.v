`include "definitions.vh"
`include "wb_defines.vh"

// =============================================================================
// Core memory port to Wishbone master.
//
// The core's request/ready handshake already holds address, data and strobes
// stable until ready (the pipeline stalls), so the mapping is direct:
// req -> STB/CYC, addr/wdata/wstrb/we -> ADR/DAT/SEL/WE, ACK -> ready.
//
// ERR also completes the access (read data forced to zero) and sets a sticky
// bus_error flag. `lock` is asserted with the read half of an RV32A
// read-modify-write and drives CYC and LOCK; CYC may drop before the write
// half. Indivisibility comes from the arbiter, which keeps the grant after a
// locked response. With the D-cache present only atomics to uncached
// addresses reach this bridge with LOCK set.
// =============================================================================
module wb_master_bridge (
    input  wire clk,
    input  wire rst,

    // --- Core side ---
    input  wire [`BUS_WIDTH-1:0] addr,
    input  wire [`BUS_WIDTH-1:0] wdata,
    input  wire [3:0]            wstrb,
    input  wire                  we,
    input  wire                  re,
    input  wire                  lock,        // RMW in progress
    output wire [`BUS_WIDTH-1:0] rdata,
    output wire                  ready,

    // --- Wishbone master side ---
    output wire [`WB_ADDR_WIDTH-1:0] wb_adr_o,
    output wire [`WB_DATA_WIDTH-1:0] wb_dat_o,
    output wire [`WB_SEL_WIDTH-1:0]  wb_sel_o,
    output wire                      wb_we_o,
    output wire                      wb_stb_o,
    output wire                      wb_cyc_o,
    output wire                      wb_lock_o,
    input  wire [`WB_DATA_WIDTH-1:0] wb_dat_i,
    input  wire                      wb_ack_i,
    input  wire                      wb_err_i,

    // --- Status ---
    output reg                       bus_error      // sticky until reset
);

    wire req = we | re;

    // The core word-aligns the address and expresses byte position in wstrb
    assign wb_adr_o  = {addr[`BUS_WIDTH-1:2], 2'b00};
    assign wb_dat_o  = wdata;
    assign wb_sel_o  = wstrb;
    assign wb_we_o   = we;
    assign wb_stb_o  = req;
    assign wb_cyc_o  = req | lock;
    assign wb_lock_o = lock;

    assign rdata = wb_err_i ? {`WB_DATA_WIDTH{1'b0}} : wb_dat_i;
    assign ready = wb_ack_i | wb_err_i;

    always @(posedge clk or posedge rst) begin
        if (rst)            bus_error <= 1'b0;
        else if (wb_err_i)  bus_error <= 1'b1;
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire unused_addr = |addr[1:0];
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
