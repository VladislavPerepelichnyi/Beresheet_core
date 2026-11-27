`include "definitions.vh"

// =============================================================================
// RV32IMA core (Zicsr, Zicntr, Zifencei, M/S/U modes, Sv32 MMU), 3-stage
// in-order pipeline.
//
//   Stage 1  Fetch                  pc_gen + BTB, I-TLB, instruction port
//   Stage 2  Decode and Execute     register file, immediate, ALU, branch,
//                                   RV32M unit, CSR file, D-TLB
//   Stage 3  Memory and Writeback   load/store alignment, atomics, writeback
//
// Hazard handling:
//   RAW            the register file's write-through bypass: stage 3 drives
//                  the write port combinationally, so the instruction reading
//                  in stage 2 sees the new value, loads included.
//   Control        BTB prediction in stage 1, resolution in stage 2, one
//                  bubble on a misprediction.
//   Multi-cycle    RV32M, CSR accesses, page walks, FENCE.I, trap entry and
//                  a pending fetch hold stages 1-2 and bubble stage 3.
//   Data memory    an access that is not ready freezes the whole pipeline.
//
// Both memory ports use a request/ready handshake and are bridged to Wishbone
// (through the caches) by the SoC. Page-table walks from both MMUs share the
// data port. Interrupt lines and mtime come from the CLINT and the PLIC.
// =============================================================================
module riscv_core #(
    // TLB sizes are set by timing, not hit rate. The fully associative D-TLB
    // compare ends the longest path (load data -> bypass -> ALU -> D-TLB), and
    // every doubling costs about 3.5 ns; the I-TLB feeds the I-cache tag
    // compare. A miss is only a two-level walk through the data cache, and
    // with 4 MiB kernel megapages four I-TLB entries cover 16 MiB of text.
    parameter DTLB_ENTRIES = 2,
    parameter ITLB_ENTRIES = 4
)(
    input  wire clk,
    input  wire rst,

    // --- Instruction fetch port (physical address; hold until ready) ---
    output wire [`BUS_WIDTH-1:0] imem_addr,
    output wire                  imem_req,
    input  wire [`BUS_WIDTH-1:0] imem_rdata,
    input  wire                  imem_ready,

    // --- Data port (physical address; hold until ready). Also carries the
    //     MMUs' page-table reads. ---
    output wire [`BUS_WIDTH-1:0] dmem_addr,
    output wire [`BUS_WIDTH-1:0] dmem_wdata,
    output wire [3:0]            dmem_wstrb,
    output wire                  dmem_we,
    output wire                  dmem_re,
    output wire                  dmem_lock,       // RV32A: hold the bus across an RMW
    input  wire [`BUS_WIDTH-1:0] dmem_rdata,
    input  wire                  dmem_ready,

    // --- MMU statistics, for simulation; unconnected on hardware ---
    output wire [31:0] dbg_dtlb_hits,
    output wire [31:0] dbg_dtlb_misses,
    output wire [31:0] dbg_itlb_hits,
    output wire [31:0] dbg_itlb_misses,
    output wire [31:0] dbg_dtlb_faults,
    output wire [31:0] dbg_itlb_faults,

    // --- Zifencei. fence_i_req asks the SoC to write the data cache back and
    //     invalidate the instruction cache; cache_flush_busy must go high for
    //     at least one cycle and stays high until both are done. ---
    output wire        fence_i_req,
    input  wire        cache_flush_busy,

    // --- Interrupts and real time, from the CLINT and the PLIC ---
    input  wire        irq_soft,
    input  wire        irq_timer,
    input  wire        irq_ext,        // PLIC context 0, machine mode
    input  wire        irq_ext_s,      // PLIC context 1, supervisor mode
    input  wire [63:0] mtime,          // for the `time` CSR

    // --- Status: halted on a trap with a null mtvec (see control_unit) ---
    output wire        halted,
    output wire        trap_error,
    output wire        ebreak_halt,
    output wire [3:0]  trap_cause,

    // --- Debug / trace ---
    input  wire [`REG_ADDR_WIDTH-1:0] dbg_reg_addr,
    output wire [`BUS_WIDTH-1:0]      dbg_reg_data,
    output wire                       retire_valid,
    output wire [`BUS_WIDTH-1:0]      retire_pc,
    output wire [`BUS_WIDTH-1:0]      retire_instruction,
    // Decode/Execute contents. When the core halts, the offending instruction
    // is still here.
    output wire [`BUS_WIDTH-1:0]      dbg_stage2_pc,
    output wire [`BUS_WIDTH-1:0]      dbg_stage2_instruction,
    output wire                       dbg_muldiv_stall,
    // Zicsr observation: lets the testbench check that each CSR access
    // captures and commits exactly once.
    output wire                       dbg_csr_capture,
    output wire                       dbg_csr_commit,
    output wire [`BUS_WIDTH-1:0]      dbg_csr_old,
    // RV32A observation: the atomic sequencer's phases and reservation.
    output wire                       dbg_amo_read,
    output wire                       dbg_amo_write,
    output wire                       dbg_resv_valid
);

    // ------------------------------------------------------------------------
    // Control signals
    // ------------------------------------------------------------------------
    wire        stall_pc, stall_if_id, flush_if_id, stall_ex_mem, flush_ex_mem;
    wire [3:0]  alu_control;
    wire [1:0]  alu_src_a, wb_sel;
    wire        alu_src_b;
    wire [2:0]  imm_src;
    wire        ctl_reg_we, ctl_mem_we, ctl_mem_re;
    wire        is_branch, is_jump, is_jalr, is_muldiv, is_atomic;
    wire        muldiv_stall, pipeline_hold;
    wire        is_csr, csr_re, csr_we, csr_capture, csr_commit, csr_exists;
    wire [1:0]            csr_priv;
    wire [`BUS_WIDTH-1:0] csr_mtvec, csr_stvec, csr_mepc, csr_sepc;
    wire [`BUS_WIDTH-1:0] csr_mip, csr_mie, csr_medeleg, csr_mideleg;
    wire [2:0]            csr_mcounteren, csr_scounteren;
    wire        csr_mstatus_mie, csr_mstatus_sie;
    wire        csr_mstatus_tvm, csr_mstatus_tw, csr_mstatus_tsr;
    // MMU inputs. Declared here, above the instances that consume them.
    wire [`BUS_WIDTH-1:0] satp_value;
    wire [1:0]            mstatus_mpp;
    wire                  mstatus_mprv, mstatus_sum, mstatus_mxr;
    wire                  sfence_req;
    wire [1:0]            priv = csr_priv;
    wire        trap_take, trap_to_s, trap_return, trap_ret_s;
    wire [`BUS_WIDTH-1:0] trap_cause_full, trap_tval;
    wire        mem_stall;

    // Trap vector and return address, selected by the destination mode. Both
    // inputs are CSR registers, so this mux is off the critical path.
    wire [`BUS_WIDTH-1:0] trap_vector   = trap_to_s  ? csr_stvec : csr_mtvec;
    wire [`BUS_WIDTH-1:0] trap_epc_sel  = trap_ret_s ? csr_sepc  : csr_mepc;

    // ------------------------------------------------------------------------
    // Stage 1: Fetch
    // ------------------------------------------------------------------------
    wire [`BUS_WIDTH-1:0] pc_f, predicted_pc_f;
    wire                  misaligned_fetch;

    wire                  mispredict, actual_taken;
    wire [`BUS_WIDTH-1:0] correct_pc, branch_pc;

    pc_gen pc_gen_inst (
        .clk              (clk),
        .rst              (rst),
        .stall            (stall_pc),
        .trap_take        (trap_take),
        .trap_vector      (trap_vector),
        .trap_return      (trap_return),
        .trap_epc         (trap_epc_sel),
        .mispredict       (mispredict),
        .actual_taken     (actual_taken),
        .correct_pc       (correct_pc),
        .branch_pc        (branch_pc),
        .pc_out           (pc_f),
        .predicted_pc     (predicted_pc_f),
        .misaligned_fetch (misaligned_fetch)
    );

    // ------------------------------------------------------------------------
    // Instruction translation. In bare mode or M-mode it is combinational and
    // imem_addr is pc_f. A fetch that faults is never requested; the fault
    // travels forward as a poisoned IF/ID slot instead.
    // ------------------------------------------------------------------------
    wire [`BUS_WIDTH-1:0] itlb_paddr;
    wire                  itlb_ready, itlb_fault;
    /* verilator lint_off UNUSEDSIGNAL */
    wire [3:0]            itlb_cause_unused;
    /* verilator lint_on UNUSEDSIGNAL */
    wire [`BUS_WIDTH-1:0] iptw_addr;
    wire                  iptw_re;
    wire                  iptw_ready;

    mmu #(.TLB_ENTRIES (ITLB_ENTRIES), .IS_FETCH (1)) immu (
        .clk (clk), .rst (rst),
        .vaddr        (pc_f),
        .req_valid    (1'b1),
        .req_write    (1'b0),
        .priv_mode    (priv),
        .mstatus_mpp  (mstatus_mpp),
        .mstatus_mprv (mstatus_mprv),
        .mstatus_sum  (mstatus_sum),
        .mstatus_mxr  (mstatus_mxr),
        .satp_value   (satp_value),
        .sfence_req   (sfence_req),
        .paddr        (itlb_paddr),
        .ready        (itlb_ready),
        .page_fault   (itlb_fault),
        // Always cause 12 for a fetch; the control unit names it directly.
        .pf_cause     (itlb_cause_unused),
        .ptw_addr     (iptw_addr),
        .ptw_re       (iptw_re),
        .ptw_rdata    (dmem_rdata),
        .ptw_ready    (iptw_ready),
        .stat_hits    (dbg_itlb_hits),
        .stat_misses  (dbg_itlb_misses),
        .stat_faults  (dbg_itlb_faults)
    );

    assign imem_addr = itlb_paddr;

    // Requested once translation has produced a usable address.
    assign imem_req    = itlb_ready & ~itlb_fault;
    wire   fetch_stall = ~itlb_ready | (imem_req & ~imem_ready);

    // ------------------------------------------------------------------------
    // IF/ID boundary
    // ------------------------------------------------------------------------
    wire [`BUS_WIDTH-1:0] instruction_d, pc_d, predicted_pc_d;
    wire                  valid_d;
    wire                  ifetch_fault_d;

    if_id_reg if_id_inst (
        .clk              (clk),
        .rst              (rst),
        .flush            (flush_if_id),
        .stall            (stall_if_id),
        .instruction_in   (imem_rdata),
        .pc_in            (pc_f),
        .predicted_pc_in  (predicted_pc_f),
        .fault_in         (itlb_fault),
        .instruction_out  (instruction_d),
        .pc_out           (pc_d),
        .predicted_pc_out (predicted_pc_d),
        .fault_out        (ifetch_fault_d),
        .valid_out        (valid_d)
    );

    // ------------------------------------------------------------------------
    // Stage 2: Decode and Execute
    // ------------------------------------------------------------------------
    wire [`BUS_WIDTH-1:0]      alu_result_d, store_data_d, link_pc_d;
    wire [`REG_ADDR_WIDTH-1:0] rd_addr_d;
    wire                       target_misaligned, branch_illegal;

    wire                       wb_reg_we;
    wire [`REG_ADDR_WIDTH-1:0] wb_reg_addr;
    wire [`BUS_WIDTH-1:0]      wb_reg_data;

    decode_exec decode_exec_inst (
        .clk               (clk),
        .rst               (rst),
        .instruction_in    (instruction_d),
        .pc_in             (pc_d),
        .predicted_pc_in   (predicted_pc_d),
        .valid_in          (valid_d),
        .alu_control       (alu_control),
        .alu_src_a         (alu_src_a),
        .alu_src_b         (alu_src_b),
        .imm_src           (imm_src),
        .is_branch         (is_branch),
        .is_jump           (is_jump),
        .is_jalr           (is_jalr),
        .is_muldiv         (is_muldiv),
        .pipeline_hold     (pipeline_hold),
        .is_csr            (is_csr),
        .csr_re            (csr_re),
        .csr_we            (csr_we),
        .csr_capture       (csr_capture),
        .csr_commit        (csr_commit),
        // minstret counts retired instructions, so it is driven from the
        // Mem/Writeback retirement pulse, not from anything in stage 2.
        .instret           (retire_valid),
        .trap_take         (trap_take),
        .trap_to_s         (trap_to_s),
        .trap_cause        (trap_cause_full),
        .trap_tval         (trap_tval),
        .trap_return       (trap_return),
        .trap_ret_s        (trap_ret_s),
        .mtime             (mtime),
        .irq_soft          (irq_soft),
        .irq_timer         (irq_timer),
        .irq_ext           (irq_ext),
        .irq_ext_s         (irq_ext_s),
        .wb_we             (wb_reg_we),
        .wb_rd_addr        (wb_reg_addr),
        .wb_wdata          (wb_reg_data),
        .dbg_addr          (dbg_reg_addr),
        .dbg_data          (dbg_reg_data),
        .mispredict        (mispredict),
        .actual_taken      (actual_taken),
        .correct_pc        (correct_pc),
        .branch_pc         (branch_pc),
        .target_misaligned (target_misaligned),
        .branch_illegal    (branch_illegal),
        .muldiv_stall      (muldiv_stall),
        .csr_exists        (csr_exists),
        .csr_priv          (csr_priv),
        .csr_mtvec         (csr_mtvec),
        .csr_stvec         (csr_stvec),
        .csr_mepc          (csr_mepc),
        .csr_sepc          (csr_sepc),
        .csr_mstatus_mie   (csr_mstatus_mie),
        .csr_mstatus_sie   (csr_mstatus_sie),
        .csr_mstatus_tvm   (csr_mstatus_tvm),
        .csr_satp          (satp_value),
        .csr_mstatus_mpp   (mstatus_mpp),
        .csr_mstatus_mprv  (mstatus_mprv),
        .csr_mstatus_sum   (mstatus_sum),
        .csr_mstatus_mxr   (mstatus_mxr),
        .csr_mstatus_tw    (csr_mstatus_tw),
        .csr_mstatus_tsr   (csr_mstatus_tsr),
        .csr_mip           (csr_mip),
        .csr_mie           (csr_mie),
        .csr_medeleg       (csr_medeleg),
        .csr_mideleg       (csr_mideleg),
        .csr_mcounteren    (csr_mcounteren),
        .csr_scounteren    (csr_scounteren),
        .dbg_csr_old       (dbg_csr_old),
        .alu_result        (alu_result_d),
        .store_data        (store_data_d),
        .link_pc           (link_pc_d),
        .rd_addr_out       (rd_addr_d)
    );

    // ------------------------------------------------------------------------
    // EX/MEM boundary
    // ------------------------------------------------------------------------
    wire [`BUS_WIDTH-1:0]      alu_result_m, store_data_m, link_pc_m;
    wire [`REG_ADDR_WIDTH-1:0] rd_addr_m;
    wire                       reg_we_m, mem_we_m, mem_re_m, valid_m;
    wire [1:0]                 wb_sel_m;
    wire [2:0]                 funct3_m;
    wire                       is_atomic_m;
    wire [4:0]                 amo_funct5_m;

    // ------------------------------------------------------------------------
    // Data translation, in Decode/Execute: a page fault joins the other
    // synchronous faults there and the instruction never reaches stage 3, so
    // the trap is precise. For a load or store the physical address replaces
    // the ALU result in EX/MEM.
    // ------------------------------------------------------------------------
    wire [`BUS_WIDTH-1:0] dtlb_paddr;
    wire                  dtlb_ready, dtlb_fault;
    wire [3:0]            dtlb_cause;
    wire [`BUS_WIDTH-1:0] dptw_addr;
    wire                  dptw_re;
    wire                  dptw_ready;

    // A slot whose fetch faulted carries meaningless bits that may decode as a
    // load or store. It must not request a data translation: the data walker
    // has priority on the shared port and would starve the I-TLB walk the
    // pending fetch-fault trap is waiting for.
    wire dmem_op_d = (ctl_mem_re | ctl_mem_we) & ~ifetch_fault_d;

    // An AMO decodes as a load (its first bus access is a read) but writes the
    // page, so it is translated as a store: it needs W and D, and a fault is a
    // store/AMO page fault (cause 15). LR is a plain load; SC already sets mem_we.
    wire amo_write_d = is_atomic & (instruction_d[31:27] != `F5_LR);

    mmu #(.TLB_ENTRIES (DTLB_ENTRIES), .IS_FETCH (0)) dmmu (
        .clk (clk), .rst (rst),
        .vaddr        (alu_result_d),
        .req_valid    (dmem_op_d & valid_d),
        .req_write    (ctl_mem_we | amo_write_d),
        .priv_mode    (priv),
        .mstatus_mpp  (mstatus_mpp),
        .mstatus_mprv (mstatus_mprv),
        .mstatus_sum  (mstatus_sum),
        .mstatus_mxr  (mstatus_mxr),
        .satp_value   (satp_value),
        .sfence_req   (sfence_req),
        .paddr        (dtlb_paddr),
        .ready        (dtlb_ready),
        .page_fault   (dtlb_fault),
        .pf_cause     (dtlb_cause),
        .ptw_addr     (dptw_addr),
        .ptw_re       (dptw_re),
        .ptw_rdata    (dmem_rdata),
        .ptw_ready    (dptw_ready),
        .stat_hits    (dbg_dtlb_hits),
        .stat_misses  (dbg_dtlb_misses),
        .stat_faults  (dbg_dtlb_faults)
    );

    wire dxlate_stall = dmem_op_d & valid_d & ~dtlb_ready;

    ex_mem_reg ex_mem_inst (
        .clk             (clk),
        .rst             (rst),
        .flush           (flush_ex_mem),
        .stall           (stall_ex_mem),
        .alu_result_in   (dmem_op_d ? dtlb_paddr : alu_result_d),
        .store_data_in   (store_data_d),
        .link_pc_in      (link_pc_d),
        .rd_addr_in      (rd_addr_d),
        .reg_we_in       (ctl_reg_we),
        .mem_we_in       (ctl_mem_we),
        .mem_re_in       (ctl_mem_re),
        .wb_sel_in       (wb_sel),
        .funct3_in       (instruction_d[14:12]),
        .is_atomic_in    (is_atomic),
        .amo_funct5_in   (instruction_d[31:27]),
        .valid_in        (valid_d),
        .pc_in           (pc_d),
        .instruction_in  (instruction_d),
        .alu_result_out  (alu_result_m),
        .store_data_out  (store_data_m),
        .link_pc_out     (link_pc_m),
        .rd_addr_out     (rd_addr_m),
        .reg_we_out      (reg_we_m),
        .mem_we_out      (mem_we_m),
        .mem_re_out      (mem_re_m),
        .wb_sel_out      (wb_sel_m),
        .funct3_out      (funct3_m),
        .is_atomic_out   (is_atomic_m),
        .amo_funct5_out  (amo_funct5_m),
        .valid_out       (valid_m),
        .pc_out          (retire_pc),
        .instruction_out (retire_instruction)
    );

    // Retirement pulses once, on the cycle the instruction completes; valid_m
    // stays high while mem_stall holds EX/MEM.
    assign retire_valid = valid_m & ~mem_stall;

    assign dbg_muldiv_stall       = muldiv_stall;
    assign dbg_csr_capture        = csr_capture;
    assign dbg_csr_commit         = csr_commit;

    assign dbg_stage2_pc          = pc_d;
    assign dbg_stage2_instruction = instruction_d;

    // ------------------------------------------------------------------------
    // Stage 3: Memory and Writeback
    //
    // The data port is shared by stage 3, the data walker and the instruction
    // walker, in that priority order. Page-table reads go through the data
    // cache like any other read. Stage 3 is older than any walk in progress,
    // so serving it first cannot starve either walker.
    // ------------------------------------------------------------------------
    wire [`BUS_WIDTH-1:0] cpu_dmem_addr, cpu_dmem_wdata;
    wire [3:0]            cpu_dmem_wstrb;
    wire                  cpu_dmem_we, cpu_dmem_re, cpu_dmem_lock;
    wire                  cpu_dmem_ready;

    wire cpu_dmem_req = cpu_dmem_we | cpu_dmem_re;
    wire dptw_grant   = dptw_re & ~cpu_dmem_req;
    wire iptw_grant   = iptw_re & ~cpu_dmem_req & ~dptw_re;

    assign dmem_addr  = dptw_grant ? dptw_addr
                      : iptw_grant ? iptw_addr
                                   : cpu_dmem_addr;
    assign dmem_wdata = cpu_dmem_wdata;
    assign dmem_wstrb = (dptw_grant | iptw_grant) ? 4'b1111 : cpu_dmem_wstrb;
    assign dmem_we    = (dptw_grant | iptw_grant) ? 1'b0    : cpu_dmem_we;
    assign dmem_re    = (dptw_grant | iptw_grant) ? 1'b1    : cpu_dmem_re;
    assign dmem_lock  = (dptw_grant | iptw_grant) ? 1'b0    : cpu_dmem_lock;

    assign cpu_dmem_ready = dmem_ready & ~dptw_grant & ~iptw_grant;
    assign dptw_ready     = dmem_ready &  dptw_grant;
    assign iptw_ready     = dmem_ready &  iptw_grant;

    mem_wb mem_wb_inst (
        .clk        (clk),
        .rst        (rst),
        .alu_result (alu_result_m),
        .store_data (store_data_m),
        .link_pc    (link_pc_m),
        .rd_addr    (rd_addr_m),
        .reg_we_in  (reg_we_m),
        .mem_we_in  (mem_we_m),
        .mem_re_in  (mem_re_m),
        .wb_sel     (wb_sel_m),
        .funct3       (funct3_m),
        .is_atomic_in (is_atomic_m),
        .amo_funct5   (amo_funct5_m),
        .valid_in     (valid_m),
        .trap_take    (trap_take),
        .dmem_addr  (cpu_dmem_addr),
        .dmem_wdata (cpu_dmem_wdata),
        .dmem_wstrb (cpu_dmem_wstrb),
        .dmem_we    (cpu_dmem_we),
        .dmem_re    (cpu_dmem_re),
        .dmem_lock  (cpu_dmem_lock),
        .dmem_rdata (dmem_rdata),
        .dmem_ready (cpu_dmem_ready),
        .reg_we     (wb_reg_we),
        .reg_waddr  (wb_reg_addr),
        .reg_wdata  (wb_reg_data),
        .mem_stall  (mem_stall),
        .dbg_amo_read   (dbg_amo_read),
        .dbg_amo_write  (dbg_amo_write),
        .dbg_resv_valid (dbg_resv_valid)
    );

    // ------------------------------------------------------------------------
    // Control unit, decoding alongside stage 2
    // ------------------------------------------------------------------------
    control_unit control_unit_inst (
        .clk                (clk),
        .rst                (rst),
        .instruction        (instruction_d),
        .inst_valid         (valid_d),
        .mispredict         (mispredict),
        .mem_addr           (alu_result_d),
        .target_misaligned  (target_misaligned),
        .jump_target        (correct_pc),
        .branch_illegal     (branch_illegal),
        .misaligned_fetch   (misaligned_fetch),
        .mem_stall          (mem_stall),
        .muldiv_stall       (muldiv_stall),
        .fetch_stall        (fetch_stall),
        .cache_flush_busy   (cache_flush_busy),
        .fence_i_req        (fence_i_req),
        .sfence_req         (sfence_req),
        .pc                 (pc_d),
        .dxlate_stall       (dxlate_stall),
        .dmmu_fault         (dtlb_fault),
        .dmmu_cause         (dtlb_cause),
        .ifetch_fault       (ifetch_fault_d),
        .csr_exists         (csr_exists),
        .priv               (csr_priv),
        .mstatus_mie        (csr_mstatus_mie),
        .mstatus_sie        (csr_mstatus_sie),
        .mstatus_tvm        (csr_mstatus_tvm),
        .mstatus_tw         (csr_mstatus_tw),
        .mstatus_tsr        (csr_mstatus_tsr),
        .mip                (csr_mip),
        .mie                (csr_mie),
        .medeleg            (csr_medeleg),
        .mideleg            (csr_mideleg),
        .mcounteren         (csr_mcounteren),
        .scounteren         (csr_scounteren),
        .mtvec_value        (csr_mtvec),
        .stall_pc           (stall_pc),
        .stall_first_stage  (stall_if_id),
        .flush_first_stage  (flush_if_id),
        .stall_second_stage (stall_ex_mem),
        .flush_second_stage (flush_ex_mem),
        .alu_control        (alu_control),
        .alu_src_a          (alu_src_a),
        .alu_src_b          (alu_src_b),
        .imm_src            (imm_src),
        .wb_sel             (wb_sel),
        .reg_we             (ctl_reg_we),
        .mem_we             (ctl_mem_we),
        .mem_re             (ctl_mem_re),
        .is_branch          (is_branch),
        .is_jump            (is_jump),
        .is_jalr            (is_jalr),
        .is_muldiv          (is_muldiv),
        .is_atomic          (is_atomic),
        .pipeline_hold      (pipeline_hold),
        .is_csr             (is_csr),
        .csr_re             (csr_re),
        .csr_we             (csr_we),
        .csr_capture        (csr_capture),
        .csr_commit         (csr_commit),
        .trap_take          (trap_take),
        .trap_to_s          (trap_to_s),
        .trap_return        (trap_return),
        .trap_ret_s         (trap_ret_s),
        .trap_cause         (trap_cause_full),
        .trap_tval          (trap_tval),
        .halted             (halted),
        .trap_error         (trap_error),
        .ebreak_halt        (ebreak_halt),
        .trap_code_o        (trap_cause)
    );

endmodule
