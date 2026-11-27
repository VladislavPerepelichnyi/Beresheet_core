`include "definitions.vh"

// =============================================================================
// Top level for the core-only fast simulator (RTL/sim/fast/).
//
// The core's memory and interrupt ports pass straight through to C++, which
// models memory and the devices. The wrapper exists only to export a handful
// of internal CSR-file registers through hierarchical references: the
// delegated-trap and privilege invariants need them, and exporting them as
// ports keeps Verilator free to optimise everything else (--public would not).
// =============================================================================
module fast_sim_top (
    input  wire        clk,
    input  wire        rst,

    output wire [31:0] imem_addr,
    output wire        imem_req,
    input  wire [31:0] imem_rdata,
    input  wire        imem_ready,

    output wire [31:0] dmem_addr,
    output wire [31:0] dmem_wdata,
    output wire [3:0]  dmem_wstrb,
    output wire        dmem_we,
    output wire        dmem_re,
    output wire        dmem_lock,
    input  wire [31:0] dmem_rdata,
    input  wire        dmem_ready,

    output wire        fence_i_req,
    input  wire        cache_flush_busy,

    input  wire        irq_soft,
    input  wire        irq_timer,
    input  wire        irq_ext,
    input  wire        irq_ext_s,
    input  wire [63:0] mtime,

    output wire        halted,
    output wire        trap_error,
    output wire        ebreak_halt,
    output wire [3:0]  trap_cause,

    input  wire [4:0]  dbg_reg_addr,
    output wire [31:0] dbg_reg_data,
    output wire        retire_valid,
    output wire [31:0] retire_pc,
    output wire [31:0] retire_instruction,
    output wire [31:0] dbg_stage2_pc,
    output wire [31:0] dbg_stage2_instruction,
    output wire        dbg_muldiv_stall,
    output wire        dbg_csr_capture,
    output wire        dbg_csr_commit,
    output wire [31:0] dbg_csr_old,
    output wire        dbg_amo_read,
    output wire        dbg_amo_write,
    output wire        dbg_resv_valid,

    output wire [31:0] dbg_dtlb_hits,
    output wire [31:0] dbg_dtlb_misses,
    output wire [31:0] dbg_itlb_hits,
    output wire [31:0] dbg_itlb_misses,
    output wire [31:0] dbg_dtlb_faults,
    output wire [31:0] dbg_itlb_faults,

    // Internal state for the harness's invariant checks.
    output wire        dbg_trap_deleg,      // a trap is being taken into S-mode
    output wire [31:0] dbg_mcause,
    output wire [31:0] dbg_mepc,
    output wire [31:0] dbg_mtval,
    output wire [1:0]  dbg_mpp,
    output wire        dbg_mpie,
    output wire [1:0]  dbg_priv
);

    riscv_core core (
        .clk                    (clk),
        .rst                    (rst),
        .imem_addr              (imem_addr),
        .imem_req               (imem_req),
        .imem_rdata             (imem_rdata),
        .imem_ready             (imem_ready),
        .dmem_addr              (dmem_addr),
        .dmem_wdata             (dmem_wdata),
        .dmem_wstrb             (dmem_wstrb),
        .dmem_we                (dmem_we),
        .dmem_re                (dmem_re),
        .dmem_lock              (dmem_lock),
        .dmem_rdata             (dmem_rdata),
        .dmem_ready             (dmem_ready),
        .dbg_dtlb_hits          (dbg_dtlb_hits),
        .dbg_dtlb_misses        (dbg_dtlb_misses),
        .dbg_itlb_hits          (dbg_itlb_hits),
        .dbg_itlb_misses        (dbg_itlb_misses),
        .dbg_dtlb_faults        (dbg_dtlb_faults),
        .dbg_itlb_faults        (dbg_itlb_faults),
        .fence_i_req            (fence_i_req),
        .cache_flush_busy       (cache_flush_busy),
        .irq_soft               (irq_soft),
        .irq_timer              (irq_timer),
        .irq_ext                (irq_ext),
        .irq_ext_s              (irq_ext_s),
        .mtime                  (mtime),
        .halted                 (halted),
        .trap_error             (trap_error),
        .ebreak_halt            (ebreak_halt),
        .trap_cause             (trap_cause),
        .dbg_reg_addr           (dbg_reg_addr),
        .dbg_reg_data           (dbg_reg_data),
        .retire_valid           (retire_valid),
        .retire_pc              (retire_pc),
        .retire_instruction     (retire_instruction),
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

    assign dbg_trap_deleg = core.trap_take & core.trap_to_s;
    assign dbg_mcause     = core.decode_exec_inst.csr_inst.mcause;
    assign dbg_mepc       = core.decode_exec_inst.csr_inst.mepc;
    assign dbg_mtval      = core.decode_exec_inst.csr_inst.mtval;
    assign dbg_mpp        = core.decode_exec_inst.csr_inst.mstatus_mpp;
    assign dbg_mpie       = core.decode_exec_inst.csr_inst.mstatus_mpie;
    assign dbg_priv       = core.decode_exec_inst.csr_inst.priv;

endmodule
