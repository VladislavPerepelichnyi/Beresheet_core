`include "definitions.vh"
`include "CSRdefinitions.vh"

// =============================================================================
// Stage 2: Decode and Execute.
//
// Reads the register file, builds the immediate, runs the ALU, and resolves
// every branch and jump. The control unit decodes the same instruction in
// parallel and supplies the select signals.
//
// The RV32M unit and the CSR file also live here. Both are multi-cycle and
// both return their result on the ordinary ALU result path, so EX/MEM and the
// writeback multiplexer need no extra source. A CSR access is a two-cycle
// read-modify-write: the old value is captured on the first cycle, the
// modified value is stored on the second, and the captured value reaches rd.
// =============================================================================
module decode_exec (
    input  wire clk,
    input  wire rst,

    // --- From IF/ID ---
    input  wire [`BUS_WIDTH-1:0] instruction_in,
    input  wire [`BUS_WIDTH-1:0] pc_in,
    input  wire [`BUS_WIDTH-1:0] predicted_pc_in,
    input  wire                  valid_in,

    // --- From the control unit ---
    input  wire [3:0]            alu_control,
    input  wire [1:0]            alu_src_a,        // rs1 / PC / zero
    input  wire                  alu_src_b,        // rs2 / immediate
    input  wire [2:0]            imm_src,
    input  wire                  is_branch,
    input  wire                  is_jump,
    input  wire                  is_jalr,
    input  wire                  is_muldiv,        // RV32M instruction
    input  wire                  pipeline_hold,    // a higher-priority stall is active

    // --- CSR control, from the control unit ---
    input  wire                  is_csr,           // a Zicsr instruction
    input  wire                  csr_re,           // this access reads
    input  wire                  csr_we,           // this access writes
    input  wire                  csr_capture,      // first of the two cycles
    input  wire                  csr_commit,       // second of the two cycles
    input  wire                  instret,          // an instruction retired

    // --- Trap entry, driven by the control unit ---
    input  wire                       trap_take,
    input  wire                       trap_to_s,
    input  wire [`BUS_WIDTH-1:0]      trap_cause,
    input  wire [`BUS_WIDTH-1:0]      trap_tval,
    input  wire                       trap_return,
    input  wire                       trap_ret_s,

    // --- From the CLINT and the PLIC ---
    input  wire [63:0]                mtime,
    input  wire                       irq_soft,
    input  wire                       irq_timer,
    input  wire                       irq_ext,      // PLIC context 0, M-mode
    input  wire                       irq_ext_s,    // PLIC context 1, S-mode

    // --- Register file write port, driven by Mem/Writeback ---
    input  wire                       wb_we,
    input  wire [`REG_ADDR_WIDTH-1:0] wb_rd_addr,
    input  wire [`BUS_WIDTH-1:0]      wb_wdata,

    // --- Testbench register inspection ---
    input  wire [`REG_ADDR_WIDTH-1:0] dbg_addr,
    output wire [`BUS_WIDTH-1:0]      dbg_data,

    // --- To Fetch: branch resolution ---
    output wire                  mispredict,
    output wire                  actual_taken,
    output wire [`BUS_WIDTH-1:0] correct_pc,
    output wire [`BUS_WIDTH-1:0] branch_pc,
    output wire                  target_misaligned, // instruction-address-misaligned
    output wire                  branch_illegal,    // reserved branch funct3
    output wire                  muldiv_stall,      // RV32M unit still working
    output wire                  csr_exists,        // addressed CSR is implemented
    output wire [1:0]            csr_priv,          // current privilege mode
    output wire [`BUS_WIDTH-1:0] csr_mtvec,         // machine vector, to pc_gen
    output wire [`BUS_WIDTH-1:0] csr_stvec,         // supervisor vector
    output wire [`BUS_WIDTH-1:0] csr_mepc,          // return address, to pc_gen
    output wire [`BUS_WIDTH-1:0] csr_sepc,
    output wire                  csr_mstatus_mie,
    output wire                  csr_mstatus_sie,
    output wire                  csr_mstatus_tvm,
    // For the MMUs: the root page table, and the four mstatus bits that change
    // what a translation is allowed to do.
    output wire [`BUS_WIDTH-1:0] csr_satp,
    output wire [1:0]            csr_mstatus_mpp,
    output wire                  csr_mstatus_mprv,
    output wire                  csr_mstatus_sum,
    output wire                  csr_mstatus_mxr,
    output wire                  csr_mstatus_tw,
    output wire                  csr_mstatus_tsr,
    output wire [`BUS_WIDTH-1:0] csr_mip,
    output wire [`BUS_WIDTH-1:0] csr_mie,
    output wire [`BUS_WIDTH-1:0] csr_medeleg,
    output wire [`BUS_WIDTH-1:0] csr_mideleg,
    output wire [2:0]            csr_mcounteren,
    output wire [2:0]            csr_scounteren,
    output wire [`BUS_WIDTH-1:0] dbg_csr_old,       // captured value, for the TB

    // --- To EX/MEM ---
    output wire [`BUS_WIDTH-1:0]      alu_result,
    output wire [`BUS_WIDTH-1:0]      store_data,   // rs2, for SB / SH / SW
    output wire [`BUS_WIDTH-1:0]      link_pc,      // pc + 4, for JAL / JALR
    output wire [`REG_ADDR_WIDTH-1:0] rd_addr_out
);

    wire [`REG_ADDR_WIDTH-1:0] rs1_addr = instruction_in[19:15];
    wire [`REG_ADDR_WIDTH-1:0] rs2_addr = instruction_in[24:20];
    wire [2:0]                 funct3   = instruction_in[14:12];

    wire [`BUS_WIDTH-1:0] rs1_data, rs2_data, imm_val;
    wire [`BUS_WIDTH-1:0] alu_out, muldiv_result;

    assign rd_addr_out = instruction_in[11:7];
    assign store_data  = rs2_data;
    assign link_pc     = pc_in + 32'd4;
    assign branch_pc   = pc_in;

    // ------------------------------------------------------------------------
    // Register file
    // ------------------------------------------------------------------------
    file_register reg_file_inst (
        .clk      (clk),
        .rst      (rst),
        .raddr1   (rs1_addr),
        .raddr2   (rs2_addr),
        .rdata1   (rs1_data),
        .rdata2   (rs2_data),
        .we       (wb_we),
        .waddr    (wb_rd_addr),
        .wdata    (wb_wdata),
        .dbg_addr (dbg_addr),
        .dbg_data (dbg_data)
    );
    // ------------------------------------------------------------------------
    // Immediate generator
    // ------------------------------------------------------------------------
    imm_gen imm_gen_inst (
        .inst    (instruction_in),
        .imm_src (imm_src),
        .imm     (imm_val)
    );

    // ------------------------------------------------------------------------
    // ALU with its operand multiplexers
    // ------------------------------------------------------------------------
    reg [`BUS_WIDTH-1:0] alu_a;
    always @(*) begin
        case (alu_src_a)
            `SRCA_PC:   alu_a = pc_in;                 // AUIPC
            `SRCA_ZERO: alu_a = {`BUS_WIDTH{1'b0}};    // LUI
            default:    alu_a = rs1_data;
        endcase
    end

    wire [`BUS_WIDTH-1:0] alu_b = (alu_src_b == `SRCB_IMM) ? imm_val : rs2_data;

    alu alu_inst (
        .a           (alu_a),
        .b           (alu_b),
        .alu_control (alu_control),
        .result      (alu_out)
    );

    // ------------------------------------------------------------------------
    // RV32M multiply / divide unit. The request is held for as long as the
    // instruction sits in this stage; the unit's stall decides when it leaves.
    // ------------------------------------------------------------------------
    muldiv muldiv_inst (
        .clk      (clk),
        .rst      (rst),
        .req      (is_muldiv & valid_in),
        .funct3   (funct3),
        .rs1_data (rs1_data),
        .rs2_data (rs2_data),
        .hold     (pipeline_hold),
        .stall    (muldiv_stall),
        .result   (muldiv_result)
    );

    // ------------------------------------------------------------------------
    // CSR file and the two-cycle read-modify-write
    // ------------------------------------------------------------------------
    // The CSR specifier is the top 12 bits of the instruction. The immediate
    // forms take a 5-bit zero-extended uimm from the rs1 field.
    wire [11:0] csr_addr = instruction_in[31:20];

    wire [`BUS_WIDTH-1:0] csr_operand =
        `CSR_IS_IMM(funct3) ? {{(`BUS_WIDTH-5){1'b0}}, rs1_addr} : rs1_data;

    wire [`BUS_WIDTH-1:0] csr_rdata;

    // Captured on the first cycle and held for the second, so the value written
    // back is derived from the same snapshot that reaches rd (the counters
    // change every cycle).
    reg [`BUS_WIDTH-1:0] csr_old;
    reg                  csr_old_seip_hw;   // see CSR_unit.rmw_seip_hw_only
    wire                 csr_rmw_seip_hw_only;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            csr_old         <= {`BUS_WIDTH{1'b0}};
            csr_old_seip_hw <= 1'b0;
        end
        else if (csr_capture) begin
            csr_old         <= csr_rdata;
            csr_old_seip_hw <= csr_rmw_seip_hw_only;
        end
    end

    // What the modify starts from: the captured value, except that mip.SEIP
    // contributes only its software-writable bit. rd still gets csr_old.
    wire [`BUS_WIDTH-1:0] csr_old_rmw =
        csr_old & ~({{(`BUS_WIDTH-1){1'b0}}, csr_old_seip_hw} << `IRQ_S_EXT);

    assign dbg_csr_old = csr_old;

    // The modify half, computed from the captured value.
    reg [`BUS_WIDTH-1:0] csr_new;
    always @(*) begin
        case (funct3)
            `F3_CSRRS, `F3_CSRRSI: csr_new = csr_old_rmw |  csr_operand;
            `F3_CSRRC, `F3_CSRRCI: csr_new = csr_old_rmw & ~csr_operand;
            default:               csr_new = csr_operand;   // CSRRW, CSRRWI
        endcase
    end

    CSR_unit csr_inst (
        .clk           (clk),
        .rst           (rst),
        .addr          (csr_addr),
        .re            (csr_re & csr_capture),
        .we            (csr_we & csr_commit),
        .wdata         (csr_new),
        .rdata         (csr_rdata),
        .exists        (csr_exists),
        .rmw_seip_hw_only (csr_rmw_seip_hw_only),
        .trap_take     (trap_take),
        // mepc records the instruction that trapped, or for an interrupt the
        // one that has not run yet. In this pipeline both are the stage-2 PC.
        .trap_epc      (pc_in),
        .trap_cause    (trap_cause),
        .trap_tval     (trap_tval),
        .trap_to_s     (trap_to_s),
        .trap_return   (trap_return),
        .trap_ret_s    (trap_ret_s),
        .instret       (instret),
        .mtime         (mtime),
        .irq_soft      (irq_soft),
        .irq_timer     (irq_timer),
        .irq_ext       (irq_ext),
        .irq_ext_s     (irq_ext_s),
        .priv_o        (csr_priv),
        .mtvec_o       (csr_mtvec),
        .stvec_o       (csr_stvec),
        .mepc_o        (csr_mepc),
        .sepc_o        (csr_sepc),
        .mstatus_mie_o (csr_mstatus_mie),
        .mstatus_sie_o (csr_mstatus_sie),
        .mstatus_tvm_o (csr_mstatus_tvm),
        .satp_o         (csr_satp),
        .mstatus_mpp_o  (csr_mstatus_mpp),
        .mstatus_mprv_o (csr_mstatus_mprv),
        .mstatus_sum_o  (csr_mstatus_sum),
        .mstatus_mxr_o  (csr_mstatus_mxr),
        .mstatus_tw_o  (csr_mstatus_tw),
        .mstatus_tsr_o (csr_mstatus_tsr),
        .mip_o         (csr_mip),
        .mie_o         (csr_mie),
        .medeleg_o     (csr_medeleg),
        .mideleg_o     (csr_mideleg),
        .mcounteren_o  (csr_mcounteren),
        .scounteren_o  (csr_scounteren)
    );

    // ------------------------------------------------------------------------
    // Stage result. The RV32M result is valid on the cycle muldiv_stall falls;
    // a CSR access returns the captured old value.
    // ------------------------------------------------------------------------
    assign alu_result = is_csr    ? csr_old       :
                        is_muldiv ? muldiv_result : alu_out;

    // ------------------------------------------------------------------------
    // Branch / jump resolution
    // ------------------------------------------------------------------------
    wire branch_cond;
    wire branch_illegal_raw;

    branch_unit branch_unit_inst (
        .funct3         (funct3),
        .rs1_data       (rs1_data),
        .rs2_data       (rs2_data),
        .take_branch    (branch_cond),
        .illegal_funct3 (branch_illegal_raw)
    );

    assign branch_illegal = is_branch & valid_in & branch_illegal_raw;

    // JALR adds the immediate to rs1; every other transfer adds it to the PC
    wire [`BUS_WIDTH-1:0] target_base = is_jalr ? rs1_data : pc_in;
    wire [`BUS_WIDTH-1:0] target_raw  = target_base + imm_val;

    // JALR clears bit 0 of the computed target (spec requirement)
    wire [`BUS_WIDTH-1:0] target_pc = is_jalr ? (target_raw & ~32'd1) : target_raw;

    assign actual_taken = is_jump | (is_branch & branch_cond);
    assign correct_pc   = actual_taken ? target_pc : (pc_in + 32'd4);

    // A misprediction is "the next fetch was not correct_pc". That covers both
    // directions and a BTB entry that aliased onto a non-branch instruction.
    assign mispredict = valid_in & (predicted_pc_in != correct_pc);

    // Raised on the jump or branch itself, as the spec requires, not on the
    // fetch of the target.
    assign target_misaligned = valid_in & actual_taken & (target_pc[1:0] != 2'b00);

endmodule
