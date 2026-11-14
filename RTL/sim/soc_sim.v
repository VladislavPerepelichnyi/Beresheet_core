`include "definitions.vh"

// =============================================================================
// Minimal simulation SoC: one core plus split instruction and data memories.
//
// Both memories are loaded from the same program image, so code fetches see
// .text while loads see .rodata and the initial values of .data. The core does
// not modify its own code in the RV32I stage, which is exactly when a Harvard
// split over a shared image is safe. It gets replaced by a unified bus with
// caches at roadmap stages 3 and 12.
// =============================================================================
module soc_sim #(
    parameter MEM_BYTES = `INSTRUCTION_ROM_SIZE,
    parameter INIT_FILE = ""
)(
    input  wire clk,
    input  wire rst,

    output wire        halted,
    output wire        trap_error,
    output wire        ebreak_halt,
    output wire [3:0]  trap_cause,

    input  wire [`REG_ADDR_WIDTH-1:0] dbg_reg_addr,
    output wire [`BUS_WIDTH-1:0]      dbg_reg_data,
    output wire                       retire_valid,
    output wire [`BUS_WIDTH-1:0]      retire_pc,
    output wire [`BUS_WIDTH-1:0]      retire_instruction,
    output wire [`BUS_WIDTH-1:0]      dbg_stage2_pc,
    output wire [`BUS_WIDTH-1:0]      dbg_stage2_instruction,
    output wire                       dbg_muldiv_stall,
    output wire                       dbg_csr_capture,
    output wire                       dbg_csr_commit,
    output wire [`BUS_WIDTH-1:0]      dbg_csr_old,
    output wire                       dbg_amo_read,
    output wire                       dbg_amo_write,
    output wire                       dbg_resv_valid
);

    // Stands in for the CLINT's mtime, so the `time` CSR is not a constant in
    // the core-only testbench. Async reset, matching the rest of the design -
    // mixing reset styles on the same net is a real lint finding, not noise.
    reg [63:0] fake_mtime;
    always @(posedge clk or posedge rst) begin
        if (rst) fake_mtime <= 64'd0;
        else     fake_mtime <= fake_mtime + 64'd1;
    end

    wire [`BUS_WIDTH-1:0] imem_addr, imem_rdata;
    // The zero-latency ROM needs no request signal; it is left unconnected
    // here and used by the Wishbone SoC instead.
    /* verilator lint_off UNUSEDSIGNAL */
    wire                  imem_req;
    /* verilator lint_on UNUSEDSIGNAL */
    wire [`BUS_WIDTH-1:0] dmem_addr, dmem_wdata, dmem_rdata;
    wire [3:0]            dmem_wstrb;
    wire                  dmem_we, dmem_re, dmem_ready;
    wire                  fence_i_ack;
    // The bus lock only means something to an arbiter, and there is none here:
    // the core-only testbench wires the memories straight to the ports.
    /* verilator lint_off UNUSEDSIGNAL */
    wire                  dmem_lock;
    /* verilator lint_on UNUSEDSIGNAL */

    riscv_core core (
        .clk                (clk),
        .rst                (rst),
        .imem_addr          (imem_addr),
        .imem_req           (imem_req),
        .imem_rdata         (imem_rdata),
        .imem_ready         (1'b1),        // zero-latency ROM, always ready
        .dmem_addr          (dmem_addr),
        .dmem_wdata         (dmem_wdata),
        .dmem_wstrb         (dmem_wstrb),
        .dmem_we            (dmem_we),
        .dmem_re            (dmem_re),
        .dmem_lock          (dmem_lock),
        .dmem_rdata         (dmem_rdata),
        .dmem_ready         (dmem_ready),
        // No caches against the bare core, so FENCE.I has nothing to flush -
        // but it still has to be answered. Tying busy low would leave the core
        // waiting for a flush to start that never does; feeding the request
        // straight back says "already done", and FENCE.I retires in two cycles.
        // The MMUs are present against the bare core too: with satp at zero
        // they are combinational, so this stays a zero-latency machine.
        .dbg_dtlb_hits      (),
        .dbg_dtlb_misses    (),
        .dbg_itlb_hits      (),
        .dbg_itlb_misses    (),
        .dbg_dtlb_faults    (),
        .dbg_itlb_faults    (),
        .fence_i_req        (fence_i_ack),
        .cache_flush_busy   (fence_i_ack),
        // No CLINT in the core-only testbench. mtime still has to advance or
        // the `time` CSR would read a constant, so a local counter stands in.
        .irq_soft           (1'b0),
        .irq_timer          (1'b0),
        .irq_ext            (1'b0),
        .irq_ext_s          (1'b0),
        .mtime              (fake_mtime),
        .halted             (halted),
        .trap_error         (trap_error),
        .ebreak_halt        (ebreak_halt),
        .trap_cause         (trap_cause),
        .dbg_reg_addr       (dbg_reg_addr),
        .dbg_reg_data       (dbg_reg_data),
        .retire_valid       (retire_valid),
        .retire_pc          (retire_pc),
        .retire_instruction (retire_instruction),
        .dbg_stage2_pc          (dbg_stage2_pc),
        .dbg_stage2_instruction (dbg_stage2_instruction),
        .dbg_muldiv_stall       (dbg_muldiv_stall),
        .dbg_csr_capture        (dbg_csr_capture),
        .dbg_csr_commit         (dbg_csr_commit),
        .dbg_csr_old            (dbg_csr_old),
        .dbg_amo_read           (dbg_amo_read),
        .dbg_amo_write          (dbg_amo_write),
        .dbg_resv_valid         (dbg_resv_valid)
    );

    instruction_rom #(
        .ROM_BYTES (MEM_BYTES),
        .INIT_FILE (INIT_FILE)
    ) irom (
        .addr        (imem_addr),
        .instruction (imem_rdata)
    );

    data_ram #(
        .RAM_BYTES (MEM_BYTES),
        .INIT_FILE (INIT_FILE)
    ) dram (
        .clk   (clk),
        .addr  (dmem_addr),
        .wdata (dmem_wdata),
        .wstrb (dmem_wstrb),
        .we    (dmem_we),
        .re    (dmem_re),
        .rdata (dmem_rdata),
        .ready (dmem_ready)
    );

endmodule
