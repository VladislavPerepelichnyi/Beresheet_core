`include "definitions.vh"
`include "wb_defines.vh"

// =============================================================================
// Core memory port -> Wishbone master.
//
// This is deliberately almost a rename. The core's port was designed in stage 1
// as a request/hold/ready handshake, which is exactly what Wishbone is, so:
//
//   req (re | we)  ->  STB_O and CYC_O
//   addr           ->  ADR_O
//   wdata          ->  DAT_O
//   wstrb          ->  SEL_O
//   we             ->  WE_O
//   ACK_I          ->  ready
//   DAT_I          ->  rdata
//
// The one piece of real logic is holding the request steady. Wishbone requires
// the master to keep every output stable from STB until ACK, and the core does
// that already: mem_stall freezes the EX/MEM register, so addr, wdata, wstrb
// and we cannot change underneath the slave.
//
// ERR_I is folded into ready and reported separately. Without traps there is
// nothing to vector to yet, so a bus error latches a sticky flag the firmware
// or the testbench can read, and the access completes as a zero read. Once
// Zicsr lands this becomes a load/store access-fault exception.
//
// One thing here is more than a rename: the RMW cycle of spec section 3.4,
// which is exactly what an RV32A atomic is. During an atomic the core asserts
// `lock`, and this bridge then
//
//   holds CYC_O across both halves     a Wishbone cycle may contain several
//                                      transfers; that is what CYC delimits
//   asserts LOCK_O                     "the current bus cycle is
//                                      uninterruptible" (spec section 2.2.3)
//
// STB_O still drops between the two transfers, which the spec calls a master
// wait state and shows in Figure 3-14. Without the lock the arbiter releases on
// the read's ACK and another master could write the same word before our write
// lands - which would make the operation consecutive rather than indivisible.
// Nothing on this SoC writes memory except the CPU, so today the lock changes
// no behaviour; the moment a DMA-capable device is added it is what keeps the
// atomics correct.
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
    input  wire                  lock,        // hold the bus: an RMW is in flight
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
    output reg                       bus_error      // sticky, cleared by reset
);

    wire req = we | re;

    // Address bits 1:0 are always zero on this port: the core word-aligns the
    // address and expresses the byte position in wstrb.
    assign wb_adr_o = {addr[`BUS_WIDTH-1:2], 2'b00};
    assign wb_dat_o = wdata;
    assign wb_sel_o = wstrb;
    assign wb_we_o   = we;
    assign wb_stb_o  = req;
    assign wb_cyc_o  = req | lock;
    assign wb_lock_o = lock;

    // For a single transfer CYC and STB are the same signal. They separate for
    // the RMW cycle above, where CYC spans two transfers and STB marks each
    // one, and they will separate again for burst cycles with the caches
    // (spec section 3.3).

    assign rdata = wb_err_i ? {`WB_DATA_WIDTH{1'b0}} : wb_dat_i;
    assign ready = wb_ack_i | wb_err_i;

    always @(posedge clk or posedge rst) begin
        if (rst)            bus_error <= 1'b0;
        else if (wb_err_i)  bus_error <= 1'b1;
    end

endmodule
