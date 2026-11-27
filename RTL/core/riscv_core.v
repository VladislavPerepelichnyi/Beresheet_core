`include "definitions.vh"

// =============================================================================
// RV32I core, 3-stage in-order pipeline.
//
//   Stage 1  Fetch                  pc_gen + BTB, instruction memory port
//   Stage 2  Decode and Execute     register file, immediate, ALU, branch,
//                                   RV32M multiply / divide, Zicsr CSR file
//   Stage 3  Memory and Writeback   load/store alignment, writeback mux
//
// Hazard handling:
//   RAW at distance 1  - the register file's write-through bypass; the Mem/WB
//                        stage drives the write port combinationally, so the
//                        instruction reading in stage 2 sees the new value.
//   RAW at distance >1 - already committed, ordinary read.
//   Load-use           - the data memory answers combinationally, so a load
//                        also resolves through the bypass with no bubble. If a
//                        cache or bus replaces it, it lowers `ready` and the
//                        control unit's mem_stall path inserts the bubbles.
//   Control            - BTB prediction in stage 1, resolution in stage 2,
//                        one-cycle penalty on a miss.
//   RV32M latency      - multiply and divide take more than a cycle, so the M
//                        unit holds the instruction in stage 2 and bubbles
//                        Mem/Writeback until its result is ready.
//   Fetch latency      - if the instruction memory is not ready, the PC holds
//                        and IF/ID takes a bubble, so stages 2 and 3 drain
//                        rather than re-executing.
//
// Memory interfaces are left external so the same core drives simulation
// memories today and a Wishbone/AXI4-Lite bridge later. Interrupt pins and the
// real-time counter come in from the CLINT the same way.
//
// Traps vector: a fault or a pending interrupt redirects the PC to mtvec in one
// cycle, records mepc/mcause/mtval, and pushes mstatus's interrupt-enable stack.
// MRET reverses it. See control_unit.v for the sequence.
// =============================================================================
module riscv_core #(
    // The two TLBs are deliberately different sizes, and the reason is where
    // each one sits.
    //
    // The data TLB is in Decode/Execute, on the end of the longest path in the
    // machine: a load returning from the cache, through writeback, through the
    // register file's write-through bypass, through the ALU, and only then into
    // the TLB. Measured on the board, a fully associative compare there costs
    // about 3.5 ns per doubling - 4 entries closes with 11% margin, 8 with 2.8%,
    // and 16 does not close at all.
    //
    // The instruction TLB starts from pc_f, which is a register, so it is on a
    // shorter path - but not a free one: it feeds the instruction cache's index
    // and tag compare, and it turned out to matter almost as much.
    //
    // Measured on the board, at 24 MHz with a 41.667 ns period:
    //
    //     DTLB  ITLB   longest path   real margin   setup violations
    //       16    16      49.49 ns      -5.58 ns          1357
    //        8     8      42.76 ns      +1.15 ns          1055
    //        4    16      42.38 ns      +1.53 ns          1007
    //        4     8      40.09 ns      +3.81 ns           265
    //        4     4      39.25 ns      +4.65 ns             0
    //        2     4      39.33 ns      +4.57 ns            31
    //
    // The data TLB is 2 and not 4, and the reason is variance rather than the
    // averages. After the walker gained its address guards, three synthesis
    // runs of near-identical logic at DTLB=4 gave 39.25, 40.59 and 41.80 ns -
    // a two-nanosecond band, because the design sits right at the edge of what
    // the router can place. Removing a *term* from the fault path made one run
    // measure worse, which is not something logic can do; it is noise.
    //
    // At DTLB=2 the same measurement lands at 39.33 ns with 31 violated
    // endpoints instead of 871, which is a result that means something. Two
    // entries is small, and it is affordable here precisely because a miss is
    // cheap: a two-level walk against a page table that is itself in the data
    // cache costs a handful of cycles, not the hundreds a cache miss costs.
    // One instruction never needs more than one data translation.
    //
    // 4 and 4 is chosen for the last column rather than the fourth. Zero
    // violations means the router met the *over-constrained* target everywhere,
    // which is repeatable; 265 violations means the reported worst path is
    // wherever the router happened to stop, and this router has been seen to
    // move by 3 ns between runs on identical RTL. 9.2% that might be 5% next
    // time is worth less than 11.2% that will still be 11.2%.
    //
    // Four entries is small, and the cost of missing is not large: a walk is
    // two reads of a page table that is itself cached, so a handful of cycles
    // rather than the hundreds a cache miss costs. Sv32 Linux maps the kernel
    // with 4 MiB megapages, so four instruction entries cover 16 MiB of text.
    //
    // The way to afford more is to shorten the trunk, not to shrink the TLB
    // further: a load-use interlock takes the register file's write-through
    // bypass out of that path and would leave room for both TLBs to grow. That
    // has been the standing next lever since the timing work two stages ago.
    parameter DTLB_ENTRIES = 2,
    parameter ITLB_ENTRIES = 4
)(
    input  wire clk,
    input  wire rst,

    // --- Instruction fetch port ---
    // Handshaked, so the fetch can sit behind a bus or a cache. imem_ready
    // tied high restores the original zero-latency behaviour.
    output wire [`BUS_WIDTH-1:0] imem_addr,
    output wire                  imem_req,
    input  wire [`BUS_WIDTH-1:0] imem_rdata,
    input  wire                  imem_ready,

    // --- Data port ---
    output wire [`BUS_WIDTH-1:0] dmem_addr,
    output wire [`BUS_WIDTH-1:0] dmem_wdata,
    output wire [3:0]            dmem_wstrb,
    output wire                  dmem_we,
    output wire                  dmem_re,
    output wire                  dmem_lock,       // RV32A: hold the bus across an RMW
    input  wire [`BUS_WIDTH-1:0] dmem_rdata,
    input  wire                  dmem_ready,

    // --- Interrupt inputs, from the CLINT (and the PLIC later) ---
    // MMU observation. Not memory mapped, so unconnected instances are
    // stripped on hardware and visible in simulation.
    output wire [31:0] dbg_dtlb_hits,
    output wire [31:0] dbg_dtlb_misses,
    output wire [31:0] dbg_itlb_hits,
    output wire [31:0] dbg_itlb_misses,
    output wire [31:0] dbg_dtlb_faults,
    output wire [31:0] dbg_itlb_faults,

    // Zifencei. fence_i_req asks the SoC to write the data cache back and
    // invalidate the instruction cache; cache_flush_busy is high from the
    // request until both are done. With no caches the SoC answers at once.
    output wire        fence_i_req,
    input  wire        cache_flush_busy,

    input  wire        irq_soft,
    input  wire        irq_timer,
    input  wire        irq_ext,        // PLIC context 0, machine mode
    input  wire        irq_ext_s,      // PLIC context 1, supervisor mode
    input  wire [63:0] mtime,          // for the `time` CSR

    // --- Status ---
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
    // Decode/Execute contents. A trap freezes the pipeline with the offending
    // instruction still here, so this is the PC to report.
    output wire [`BUS_WIDTH-1:0]      dbg_stage2_pc,
    output wire [`BUS_WIDTH-1:0]      dbg_stage2_instruction,
    output wire                       dbg_muldiv_stall,
    // Zicsr observation. The testbench uses these to check that the value
    // captured at the start of a CSR access is still the value committed at the
    // end - the atomicity guarantee the spec requires and that no amount of
    // reading final register values can see.
    output wire                       dbg_csr_capture,
    output wire                       dbg_csr_commit,
    output wire [`BUS_WIDTH-1:0]      dbg_csr_old,
    // RV32A observation. Same reasoning as the CSR pins: an atomic is a
    // multi-cycle operation whose intermediate state never appears in any
    // register, so the only way to check that it happens exactly once is to
    // watch the sequencer.
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
    wire [11:0] csr_addr;
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
    wire        trap_take, trap_to_s, trap_return, trap_ret_s, trap_is_irq;
    wire [`BUS_WIDTH-1:0] trap_cause_full, trap_tval;

    // Which vector and which return address, chosen by where the trap is going.
    // Both inputs are registers inside the CSR file, so this is one multiplexer
    // on already-settled values rather than anything on a critical path.
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
    // Instruction translation
    //
    // Sits between the PC and the bus. With satp.MODE clear, or in M-mode, it
    // is combinational and imem_addr is pc_f exactly as before.
    //
    // A fetch that faults never becomes a memory access at all: there is
    // nothing to fetch, so imem_req stays low and the fault travels forward as
    // a poisoned IF/ID slot instead.
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
        // The cause is fixed for a fetch, so the control unit names it
        // directly rather than carrying it forward.
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

    // Requested once translation has produced a usable address. While halted
    // the PC is frozen, so the same address is re-requested harmlessly rather
    // than needing a separate gate.
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
        .csr_addr          (csr_addr),
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
    // Data translation
    //
    // In Decode/Execute, not Mem/Writeback, and that placement is the whole
    // reason page faults come out precise: the address is already here for the
    // misaligned check, so a page fault joins the existing fault set and the
    // offending instruction never reaches stage 3. No new trap machinery.
    //
    // What crosses into stage 3 is therefore the *physical* address. For a load
    // or store the ALU result is only ever the address, so it is substituted
    // rather than carried alongside - one mux instead of a wider pipeline
    // register. Index and offset are below bit 12 and untranslated, so the
    // cache sees the same index either way.
    // ------------------------------------------------------------------------
    wire [`BUS_WIDTH-1:0] dtlb_paddr;
    wire                  dtlb_ready, dtlb_fault;
    wire [3:0]            dtlb_cause;
    wire [`BUS_WIDTH-1:0] dptw_addr;
    wire                  dptw_re;
    wire                  dptw_ready;

    // Not for an instruction whose fetch faulted. Its bits are whatever was
    // last on the bus, and they decode as anything - in the hang that found
    // this, `lw a5,48(s1)`. That phantom load asked the DTLB for an unmapped
    // page, faulted, asked again, and because the data walker has priority on
    // the shared port it starved the ITLB walk that stage 1's fetch needed.
    // The fetch-fault trap waits for that fetch (redirect_ok), so nothing ever
    // retired: Linux froze on the sret into busybox's first, not-yet-mapped
    // page. The trap logic already ignored the stall; the request itself has
    // to go too, or the walker keeps the port.
    wire dmem_op_d = (ctl_mem_re | ctl_mem_we) & ~ifetch_fault_d;

    mmu #(.TLB_ENTRIES (DTLB_ENTRIES), .IS_FETCH (0)) dmmu (
        .clk (clk), .rst (rst),
        .vaddr        (alu_result_d),
        .req_valid    (dmem_op_d & valid_d),
        .req_write    (ctl_mem_we),
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

    // Retirement is a single-cycle pulse on the cycle the instruction actually
    // completes. While mem_stall holds EX/MEM - which Wishbone requires, since
    // the master's outputs must stay stable until ACK - valid_m stays high, and
    // counting that as a retirement every cycle inflates the instruction count
    // and would make minstret wrong. This is the same distinction the RV32M
    // stall invariant checks for.
    assign retire_valid = valid_m & ~mem_stall;

    assign dbg_muldiv_stall       = muldiv_stall;
    assign dbg_csr_capture        = csr_capture;
    assign dbg_csr_commit         = csr_commit;

    // mtvec, mepc and mstatus.MIE are read out of the CSR file ready for the
    // trap logic that comes next: mtvec becomes a third PC source in pc_gen,
    // mepc the return address, and MIE the global interrupt gate. Nothing
    // consumes them yet.
    /* verilator lint_off UNUSEDSIGNAL */
    wire [`BUS_WIDTH-1:0] csr_unused = {20'd0, csr_addr} ^ {31'd0, trap_is_irq};
    /* verilator lint_on UNUSEDSIGNAL */
    assign dbg_stage2_pc          = pc_d;
    assign dbg_stage2_instruction = instruction_d;

    // ------------------------------------------------------------------------
    // Stage 3: Memory and Writeback
    // ------------------------------------------------------------------------
    wire mem_stall;

    // ------------------------------------------------------------------------
    // The data port is shared three ways
    //
    // A page table walk is an ordinary read of physical memory, so it goes out
    // through the same port and the same cache as everything else - page tables
    // benefit from being cached exactly as much as any other data.
    //
    // Priority: the CPU's own access first, then the data walk, then the
    // instruction walk. The data walker cannot actually contend with the CPU -
    // it only runs while its load or store is still in Decode/Execute and
    // stage 3 is bubbled - but the instruction walker can, because a fetch
    // stalls without stopping a load already in flight. Giving the older
    // instruction the port keeps that from starving anything.
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
        .trap_is_irq        (trap_is_irq),
        .trap_tval          (trap_tval),
        .halted             (halted),
        .trap_error         (trap_error),
        .ebreak_halt        (ebreak_halt),
        .trap_code_o        (trap_cause)
    );

endmodule
