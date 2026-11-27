`include "definitions.vh"
`include "CSRdefinitions.vh"

// =============================================================================
// Control unit: instruction decoder, hazard control and trap control.
//
// Decodes the instruction in Decode/Execute in parallel with that stage. Every
// control signal is gated by `inst_valid`, so a bubble has no side effects.
//
// It also owns every "this instruction is illegal" decision (including the
// CSR access rules), interrupt selection and delegation, the two-cycle trap
// sequence, the CSR access sequencer, the FENCE.I / SFENCE.VMA handshakes, and
// the stall/flush priority for the two pipeline registers.
// =============================================================================
module control_unit (
    input  wire clk,
    input  wire rst,

    // --- From IF/ID and Decode/Execute ---
    input  wire [`BUS_WIDTH-1:0] instruction,
    input  wire                  inst_valid,
    input  wire                  mispredict,
    input  wire [`BUS_WIDTH-1:0] mem_addr,        // ALU result of this instruction
    input  wire                  target_misaligned,
    input  wire [`BUS_WIDTH-1:0] jump_target,     // for mtval on a misaligned jump
    input  wire                  branch_illegal,

    // --- From Fetch ---
    input  wire                  misaligned_fetch,

    // --- From Mem/Writeback ---
    input  wire                  mem_stall,

    // --- From the RV32M unit in Decode/Execute ---
    input  wire                  muldiv_stall,

    // --- From Fetch ---
    input  wire                  fetch_stall,     // instruction memory not ready

    // PC of the instruction in Decode/Execute, for mtval on a fetch page fault
    input  wire [`BUS_WIDTH-1:0] pc,

    // --- From the MMUs ---
    // Data translation happens in Decode/Execute, so a data page fault joins
    // the other synchronous faults of the instruction there.
    input  wire                  dxlate_stall,   // translation not ready yet
    input  wire                  dmmu_fault,
    input  wire [3:0]            dmmu_cause,
    // The IF/ID slot carries a fetch page fault instead of an instruction
    input  wire                  ifetch_fault,

    // --- From the caches ---
    // High from the cycle a flush is asked for until both caches are done.
    input  wire                  cache_flush_busy,

    // --- From the CSR file in Decode/Execute ---
    input  wire                  csr_exists,      // addressed CSR is implemented
    input  wire [1:0]            priv,            // current privilege mode
    input  wire                  mstatus_mie,     // machine global interrupt enable
    input  wire                  mstatus_sie,     // supervisor global interrupt enable
    input  wire                  mstatus_tvm,     // trap satp access from S-mode
    input  wire                  mstatus_tw,      // trap WFI outside M-mode
    input  wire                  mstatus_tsr,     // trap SRET in S-mode
    input  wire [`BUS_WIDTH-1:0] mip,
    input  wire [`BUS_WIDTH-1:0] mie,
    input  wire [`BUS_WIDTH-1:0] medeleg,
    input  wire [`BUS_WIDTH-1:0] mideleg,
    input  wire [2:0]            mcounteren,
    input  wire [2:0]            scounteren,
    input  wire [`BUS_WIDTH-1:0] mtvec_value,     // to detect a null handler

    // --- Pipeline control ---
    output reg  stall_pc,
    output reg  stall_first_stage,                 // hold IF/ID
    output reg  flush_first_stage,                 // bubble into IF/ID
    output reg  stall_second_stage,                // hold EX/MEM
    output reg  flush_second_stage,                // bubble into EX/MEM

    // --- Datapath selects ---
    output reg  [3:0] alu_control,
    output reg  [1:0] alu_src_a,
    output reg        alu_src_b,
    output reg  [2:0] imm_src,
    output reg  [1:0] wb_sel,
    output reg        reg_we,
    output reg        mem_we,
    output reg        mem_re,
    output reg        is_branch,
    output reg        is_jump,
    output reg        is_jalr,
    output reg        is_muldiv,            // RV32M: route rs1/rs2 to the M unit
    output reg        is_atomic,            // RV32A: LR / SC / AMO, sequenced in stage 3
    output wire       pipeline_hold,        // a stall the M unit must wait out

    // Zifencei: FENCE.I asks for the data cache to be written back and the
    // instruction cache invalidated, and waits for both.
    output wire       fence_i_req,

    // Invalidate both TLBs. SFENCE.VMA asks for it; so does any write to satp,
    // because that changes which page tables the cached entries came from.
    output wire       sfence_req,

    // --- Zicsr control ---
    output reg        is_csr,               // a CSR instruction is in Decode/Execute
    output reg        csr_re,               // this access reads
    output reg        csr_we,               // this access writes
    output wire       csr_capture,          // first of the two access cycles
    output wire       csr_commit,           // second of the two access cycles

    // --- Trap control, to the CSR file and pc_gen ---
    output reg                       trap_take,   // enter the handler this cycle
    output reg                       trap_to_s,   // ...delegated to supervisor mode
    output reg                       trap_return, // MRET or SRET
    output reg                       trap_ret_s,  // ...it was SRET
    output reg  [`BUS_WIDTH-1:0]     trap_cause,  // full mcause, interrupt bit included
    output reg  [`BUS_WIDTH-1:0]     trap_tval,

    // --- Status, for the testbench and the board ---
    output reg        halted,                      // no forward progress possible
    output reg        trap_error,                  // halted on a fault (not EBREAK/ECALL)
    output reg        ebreak_halt,                 // halted by an EBREAK
    output reg  [3:0] trap_code_o                  // cause code; frozen once halted
);

    // Signals used before their defining statement are declared here. A name
    // used before its declaration becomes an implicit net, which Verilator
    // resolves but Gowin synthesis leaves undriven.
    reg  is_sfence;
    wire xlate_stall, fence_stall, trap_hold;
    reg  [3:0] trap_code_q;      // latched cause, see "Trap taking"
    reg        trap_is_irq_q;

    // CSR access sequencer: idle/capture, then commit
    localparam STATE_RUNNING = 1'b0;
    localparam STATE_CSR     = 1'b1;

    reg       state;
    reg       null_vector_trap;
    reg [3:0] halt_code;
    reg [3:0] trap_code;

    wire [6:0]  opcode  = instruction[6:0];
    wire [2:0]  funct3  = instruction[14:12];
    wire [6:0]  funct7  = instruction[31:25];
    wire [11:0] funct12 = instruction[31:20];

    // rd and rs1 decide whether a CSR access reads and/or writes. For the
    // immediate forms the rs1 field is uimm, so the same bits answer "is the
    // mask zero".
    wire [4:0]  rd_field  = instruction[11:7];
    wire [4:0]  rs1_field = instruction[19:15];
    wire [4:0]  rs2_field = instruction[24:20];

    // RV32A. aq (bit 26) and rl (bit 25) are accepted and ignored: this core
    // already provides every ordering they can request (see definitions.vh).
    wire [4:0]  funct5    = instruction[31:27];

    // The CSR specifier is the same field as funct12. Only the access-rule
    // bits are needed here (Privileged manual 2.1).
    wire [1:0]  csr_rw_bits   = funct12[11:10];   // 11 = read-only
    wire [1:0]  csr_min_priv  = funct12[9:8];     // lowest mode that may access

    // ------------------------------------------------------------------------
    // Main decoder
    // ------------------------------------------------------------------------
    reg illegal_instruction;
    reg is_system;                                 // ECALL / EBREAK
    reg is_mret;                                   // MRET
    reg is_sret;                                   // SRET

    always @(*) begin
        // Defaults: a NOP that writes nothing anywhere
        alu_control         = `ALU_ADD;
        alu_src_a           = `SRCA_RS1;
        alu_src_b           = `SRCB_RS2;
        imm_src             = `IMM_I;
        wb_sel              = `WB_ALU;
        reg_we              = 1'b0;
        mem_we              = 1'b0;
        mem_re              = 1'b0;
        is_branch           = 1'b0;
        is_jump             = 1'b0;
        is_jalr             = 1'b0;
        is_muldiv           = 1'b0;
        is_atomic           = 1'b0;
        is_system           = 1'b0;
        is_mret             = 1'b0;
        is_sret             = 1'b0;
        is_csr              = 1'b0;
        csr_re              = 1'b0;
        csr_we              = 1'b0;
        illegal_instruction = 1'b0;
        is_sfence           = 1'b0;

        case (opcode)
            // rd = imm << 12. Operand A is forced to zero because LUI has no
            // rs1 field: bits 19:15 belong to the immediate.
            `OPC_LUI: begin
                reg_we    = 1'b1;
                imm_src   = `IMM_U;
                alu_src_a = `SRCA_ZERO;
                alu_src_b = `SRCB_IMM;
            end

            // rd = pc + (imm << 12)
            `OPC_AUIPC: begin
                reg_we    = 1'b1;
                imm_src   = `IMM_U;
                alu_src_a = `SRCA_PC;
                alu_src_b = `SRCB_IMM;
            end

            // rd = pc + 4; pc = pc + imm
            `OPC_JAL: begin
                reg_we  = 1'b1;
                imm_src = `IMM_J;
                wb_sel  = `WB_PC4;
                is_jump = 1'b1;
            end

            // rd = pc + 4; pc = (rs1 + imm) & ~1
            `OPC_JALR: begin
                if (funct3 == 3'b000) begin
                    reg_we  = 1'b1;
                    imm_src = `IMM_I;
                    wb_sel  = `WB_PC4;
                    is_jump = 1'b1;
                    is_jalr = 1'b1;
                end
                else illegal_instruction = 1'b1;
            end

            // Comparison is done by branch_unit; the ALU is unused here
            `OPC_BRANCH: begin
                is_branch = 1'b1;
                imm_src   = `IMM_B;
            end

            // rd = mem[rs1 + imm]
            `OPC_LOAD: begin
                imm_src   = `IMM_I;
                alu_src_b = `SRCB_IMM;
                case (funct3)
                    `F3_LB, `F3_LH, `F3_LW, `F3_LBU, `F3_LHU: begin
                        reg_we = 1'b1;
                        mem_re = 1'b1;
                        wb_sel = `WB_MEM;
                    end
                    default: illegal_instruction = 1'b1;
                endcase
            end

            // mem[rs1 + imm] = rs2
            `OPC_STORE: begin
                imm_src   = `IMM_S;
                alu_src_b = `SRCB_IMM;
                case (funct3)
                    `F3_SB, `F3_SH, `F3_SW: mem_we = 1'b1;
                    default: illegal_instruction = 1'b1;
                endcase
            end

            `OPC_OP_IMM: begin
                reg_we    = 1'b1;
                imm_src   = `IMM_I;
                alu_src_b = `SRCB_IMM;
                case (funct3)
                    `F3_ADD_SUB: alu_control = `ALU_ADD;   // ADDI
                    `F3_SLT:     alu_control = `ALU_SLT;   // SLTI
                    `F3_SLTU:    alu_control = `ALU_SLTU;  // SLTIU
                    `F3_XOR:     alu_control = `ALU_XOR;   // XORI
                    `F3_OR:      alu_control = `ALU_OR;    // ORI
                    `F3_AND:     alu_control = `ALU_AND;   // ANDI
                    // Shift immediates reuse funct7 as an opcode extension
                    `F3_SLL: begin
                        alu_control = `ALU_SLL;            // SLLI
                        if (funct7 != `F7_BASE) illegal_instruction = 1'b1;
                    end
                    `F3_SRL_SRA: begin
                        case (funct7)
                            `F7_BASE: alu_control = `ALU_SRL;  // SRLI
                            `F7_ALT:  alu_control = `ALU_SRA;  // SRAI
                            default:  illegal_instruction = 1'b1;
                        endcase
                    end
                    default: illegal_instruction = 1'b1;
                endcase
            end

            `OPC_OP: begin
                reg_we = 1'b1;
                if (funct7 == `F7_MULDIV) begin
                    // RV32M. All eight funct3 values are defined, and the unit
                    // in Decode/Execute reads funct3 directly, so there is
                    // nothing further to select here.
                    is_muldiv = 1'b1;
                end
                else begin
                    case (funct3)
                        `F3_ADD_SUB: begin
                            case (funct7)
                                `F7_BASE: alu_control = `ALU_ADD;
                                `F7_ALT:  alu_control = `ALU_SUB;
                                default:  illegal_instruction = 1'b1;
                            endcase
                        end
                        `F3_SRL_SRA: begin
                            case (funct7)
                                `F7_BASE: alu_control = `ALU_SRL;
                                `F7_ALT:  alu_control = `ALU_SRA;
                                default:  illegal_instruction = 1'b1;
                            endcase
                        end
                        default: begin
                            // The remaining six are only defined for funct7 = 0
                            case (funct3)
                                `F3_SLL:  alu_control = `ALU_SLL;
                                `F3_SLT:  alu_control = `ALU_SLT;
                                `F3_SLTU: alu_control = `ALU_SLTU;
                                `F3_XOR:  alu_control = `ALU_XOR;
                                `F3_OR:   alu_control = `ALU_OR;
                                default:  alu_control = `ALU_AND;   // F3_AND
                            endcase
                            if (funct7 != `F7_BASE) illegal_instruction = 1'b1;
                        end
                    endcase
                end
            end

            // RV32A: LR/SC (Zalrsc) and the fetch-and-op AMOs (Zaamo). All
            // address memory with rs1 alone, so the address ALU adds zero.
            // Only decode and legality live here; the read-modify-write is
            // sequenced in Mem/Writeback, at the memory port.
            `OPC_AMO: begin
                if (funct3 == `F3_AMO_W) begin
                    reg_we    = 1'b1;
                    wb_sel    = `WB_MEM;
                    imm_src   = `IMM_Z;
                    alu_src_b = `SRCB_IMM;
                    is_atomic = 1'b1;

                    case (funct5)
                        // LR is a load that also takes a reservation. rs2
                        // must be 00000; other values are reserved and trap.
                        `F5_LR: begin
                            mem_re = 1'b1;
                            if (rs2_field != 5'd0) illegal_instruction = 1'b1;
                        end

                        // SC is a store that may not happen. mem_we is raised
                        // unconditionally (so a misaligned SC reports cause 6);
                        // Mem/Writeback withholds the bus write when the
                        // reservation has been lost.
                        `F5_SC: mem_we = 1'b1;

                        // The AMOs start with a read. The write half is issued
                        // by the sequencer, not from here.
                        `F5_AMOSWAP, `F5_AMOADD, `F5_AMOXOR, `F5_AMOAND,
                        `F5_AMOOR,   `F5_AMOMIN, `F5_AMOMAX,
                        `F5_AMOMINU, `F5_AMOMAXU: mem_re = 1'b1;

                        default: begin
                            illegal_instruction = 1'b1;
                            is_atomic           = 1'b0;
                            reg_we              = 1'b0;
                        end
                    endcase
                end
                else begin
                    // funct3 = 011 is the RV64 doubleword form; everything
                    // else is unallocated.
                    illegal_instruction = 1'b1;
                end
            end

            // FENCE / FENCE.TSO / PAUSE retire as NOPs: an in-order core with
            // no store buffer is already sequentially consistent.
            //
            // FENCE.I (funct3 = 001) has no datapath effect either, but must
            // make newly written instructions visible to fetch: the data cache
            // is written back and the instruction cache invalidated. That
            // handshake is driven below.
            `OPC_MISC: begin
            end

            // SYSTEM covers ECALL and EBREAK (funct3 = 000) and the six Zicsr
            // read-modify-write instructions (funct3 != 000).
            `OPC_SYSTEM: begin
                case (funct3)
                    3'b000: begin
                        case (funct12)
                            `F12_ECALL, `F12_EBREAK: is_system = 1'b1;

                            // MRET is M-only. SRET needs S or M; mstatus.TSR
                            // makes it illegal in S-mode.
                            `F12_MRET: begin
                                if (priv == `M_MODE) is_mret = 1'b1;
                                else illegal_instruction = 1'b1;
                            end

                            `F12_SRET: begin
                                if (priv == `M_MODE ||
                                    (priv == `S_MODE && !mstatus_tsr))
                                    is_sret = 1'b1;
                                else illegal_instruction = 1'b1;
                            end

                            // WFI retires as a no-op, which the spec permits.
                            // mstatus.TW still makes it illegal below M-mode.
                            `F12_WFI: begin
                                if (mstatus_tw && priv != `M_MODE)
                                    illegal_instruction = 1'b1;
                            end

                            default: begin
                                // SFENCE.VMA is identified by funct7 because
                                // its rs1 and rs2 are real operands. Both are
                                // ignored and the whole TLB is flushed, which
                                // the spec permits. mstatus.TVM makes it
                                // illegal in S-mode.
                                if (funct7 == `F7_SFENCE_VMA) begin
                                    if (priv == `M_MODE ||
                                        (priv == `S_MODE && !mstatus_tvm))
                                        is_sfence = 1'b1;
                                    else illegal_instruction = 1'b1;
                                end
                                else illegal_instruction = 1'b1;
                            end
                        endcase
                    end

                    `F3_CSRRW, `F3_CSRRWI: begin
                        // Swap. Always writes; reads only if rd is not x0.
                        is_csr = 1'b1;
                        reg_we = 1'b1;
                        csr_re = (rd_field != 5'd0);
                        csr_we = 1'b1;
                    end

                    `F3_CSRRS, `F3_CSRRSI,
                    `F3_CSRRC, `F3_CSRRCI: begin
                        // Set or clear bits. Always reads; writes only if the
                        // mask field (rs1 or uimm) is non-zero. This is what
                        // makes `csrrs rd, cycle, x0` a legal read of a
                        // read-only CSR.
                        is_csr = 1'b1;
                        reg_we = 1'b1;
                        csr_re = 1'b1;
                        csr_we = (rs1_field != 5'd0);
                    end

                    default: illegal_instruction = 1'b1;
                endcase
            end

            default: illegal_instruction = 1'b1;
        endcase

        // A bubble must never have side effects
        if (!inst_valid) begin
            reg_we              = 1'b0;
            mem_we              = 1'b0;
            mem_re              = 1'b0;
            is_branch           = 1'b0;
            is_jump             = 1'b0;
            is_jalr             = 1'b0;
            is_muldiv           = 1'b0;
            is_atomic           = 1'b0;
            is_system           = 1'b0;
            is_mret             = 1'b0;
            is_sret             = 1'b0;
            is_csr              = 1'b0;
            csr_re              = 1'b0;
            csr_we              = 1'b0;
            illegal_instruction = 1'b0;
        end
    end

    // ------------------------------------------------------------------------
    // Address alignment checks
    // ------------------------------------------------------------------------
    reg load_misaligned, store_misaligned;

    // A misaligned AMO reports cause 6 ("Store/AMO address misaligned") even
    // though its first bus access is a read. LR is a plain load and reports 4.
    wire amo_is_rmw = is_atomic && (funct5 != `F5_LR);

    always @(*) begin
        load_misaligned  = 1'b0;
        store_misaligned = 1'b0;
        if (mem_re || mem_we) begin
            // Halfword accesses need bit 0 clear, word accesses need bits 1:0 clear
            case (funct3)
                `F3_LH, `F3_LHU: begin   // also covers F3_SH, same funct3
                    load_misaligned  = mem_re & mem_addr[0];
                    store_misaligned = mem_we & mem_addr[0];
                end
                `F3_LW: begin            // also covers F3_SW and every atomic
                    load_misaligned  = mem_re & ~amo_is_rmw &
                                       (mem_addr[1:0] != 2'b00);
                    store_misaligned = (mem_we | amo_is_rmw) &
                                       (mem_addr[1:0] != 2'b00);
                end
                default: ;               // byte accesses are always aligned
            endcase
        end
    end

    // ------------------------------------------------------------------------
    // CSR access checks (Privileged manual 2.1). Each raises an illegal
    // instruction: a non-existent CSR, a write to a read-only CSR, an access
    // from too low a privilege, satp from S-mode with TVM set, and a counter
    // the enable registers hide.
    //
    // The CSR file only reports whether the address is implemented; the other
    // rules are functions of the address bits and live here. The read-only
    // check keys off csr_we (an actual write), not off the opcode.
    // ------------------------------------------------------------------------
    wire csr_fault_missing = is_csr && !csr_exists;
    wire csr_fault_ro      = is_csr && csr_we && (csr_rw_bits == 2'b11);
    wire csr_fault_priv    = is_csr && (priv < csr_min_priv);
    wire csr_fault_tvm     = is_csr && (funct12 == `CSR_SATP) &&
                             (priv == `S_MODE) && mstatus_tvm;

    // Counter access: cycle, time and instret are readable from M always, from
    // S if the mcounteren bit is set, and from U if both mcounteren and
    // scounteren allow it.
    reg       ctr_is_shared;                 // one of the three unprivileged views
    reg [1:0] ctr_bit;
    always @(*) begin
        ctr_is_shared = 1'b1;
        case (funct12)
            `CSR_CYCLE,   `CSR_CYCLEH:   ctr_bit = `CTREN_CY;
            `CSR_TIME,    `CSR_TIMEH:    ctr_bit = `CTREN_TM;
            `CSR_INSTRET, `CSR_INSTRETH: ctr_bit = `CTREN_IR;
            default: begin
                ctr_bit       = 2'd0;
                ctr_is_shared = 1'b0;
            end
        endcase
    end

    wire ctr_allowed = (priv == `M_MODE) ? 1'b1 :
                       (priv == `S_MODE) ? mcounteren[ctr_bit]
                                         : (mcounteren[ctr_bit] & scounteren[ctr_bit]);

    wire csr_fault_ctr = is_csr && ctr_is_shared && !ctr_allowed;

    wire csr_fault = csr_fault_missing | csr_fault_ro | csr_fault_priv |
                     csr_fault_tvm     | csr_fault_ctr;

    // ------------------------------------------------------------------------
    // Any synchronous exception. Cause priority is resolved below.
    // ------------------------------------------------------------------------
    wire fault = illegal_instruction | branch_illegal | target_misaligned |
                 misaligned_fetch    | load_misaligned | store_misaligned |
                 dmmu_fault          | ifetch_fault    |
                 csr_fault;

    // ------------------------------------------------------------------------
    // Interrupts.
    //
    // Taken between instructions: a valid instruction must be in
    // Decode/Execute (its PC becomes xepc) and no multi-cycle operation may be
    // in flight (a memory access, an RV32M operation, or a CSR commit).
    //
    // The condition is combinational on mip, mie and mstatus so a pending
    // interrupt is taken immediately after the xRET or CSR write that enables
    // it, as the spec requires.
    // ------------------------------------------------------------------------
    // Pending and enabled, split by destination: a set mideleg bit sends that
    // interrupt to supervisor mode.
    wire [`BUS_WIDTH-1:0] irq_active = mip & mie;
    wire [`BUS_WIDTH-1:0] irq_to_m   = irq_active & ~mideleg;
    wire [`BUS_WIDTH-1:0] irq_to_s   = irq_active &  mideleg;

    // An interrupt destined for a higher privilege than the current one is
    // always enabled; xIE only applies while running in mode x.
    //
    //   to M:  (priv == M && MIE) || priv < M
    //   to S:  (priv == S && SIE) || priv < S       never while priv == M
    wire m_irq_enabled = (priv == `M_MODE) ? mstatus_mie : 1'b1;
    wire s_irq_enabled = (priv == `S_MODE) ? mstatus_sie : (priv == `U_MODE);

    wire irq_m_any = (|irq_to_m) & m_irq_enabled;
    wire irq_s_any = (|irq_to_s) & s_irq_enabled;

    wire irq_boundary = inst_valid && !mem_stall && !muldiv_stall &&
                        (state == STATE_RUNNING);

    wire irq_any     = irq_m_any | irq_s_any;
    wire irq_pending = irq_any && irq_boundary;

    // Interrupts to M-mode take priority over those to lower modes.
    wire irq_dest_s = ~irq_m_any & irq_s_any;

    // Priority within each destination (Privileged manual): MEI, MSI, MTI, SEI,
    // SSI, STI. Undelegated supervisor interrupts are taken in M-mode.
    reg [3:0] irq_code;
    always @(*) begin
        if (irq_dest_s) begin
            if      (irq_to_s[`IRQ_S_EXT])   irq_code = `CAUSE_IRQ_S_EXT;
            else if (irq_to_s[`IRQ_S_SOFT])  irq_code = `CAUSE_IRQ_S_SOFT;
            else                             irq_code = `CAUSE_IRQ_S_TIMER;
        end
        else begin
            if      (irq_to_m[`IRQ_M_EXT])   irq_code = `CAUSE_IRQ_M_EXT;
            else if (irq_to_m[`IRQ_M_SOFT])  irq_code = `CAUSE_IRQ_M_SOFT;
            else if (irq_to_m[`IRQ_M_TIMER]) irq_code = `CAUSE_IRQ_M_TIMER;
            else if (irq_to_m[`IRQ_S_EXT])   irq_code = `CAUSE_IRQ_S_EXT;
            else if (irq_to_m[`IRQ_S_SOFT])  irq_code = `CAUSE_IRQ_S_SOFT;
            else                             irq_code = `CAUSE_IRQ_S_TIMER;
        end
    end

    // An interrupt outranks a synchronous exception on the same instruction:
    // the instruction has not executed and simply re-executes afterwards.
    wire trap_is_irq = irq_pending;

    // ------------------------------------------------------------------------
    // Cause and trap value
    // ------------------------------------------------------------------------
    always @(*) begin
        if (irq_pending) begin
            trap_code = irq_code;
        end
        // A fetch page fault outranks every other exception: there is no
        // instruction, and the bits in the decoder are meaningless (they may
        // well decode as illegal).
        else if (ifetch_fault)                     trap_code = `CAUSE_FETCH_PAGE_FAULT;
        else if (illegal_instruction || branch_illegal || csr_fault)
                                                   trap_code = `CAUSE_ILLEGAL_INSTR;
        else if (target_misaligned || misaligned_fetch)
                                                   trap_code = `CAUSE_INSTR_MISALIGNED;
        else if (load_misaligned)                  trap_code = `CAUSE_LOAD_MISALIGNED;
        else if (store_misaligned)                 trap_code = `CAUSE_STORE_MISALIGNED;
        // A misaligned access is reported ahead of a page fault, as the spec
        // orders them.
        else if (dmmu_fault)                       trap_code = dmmu_cause;
        else if (is_system && funct12 == `F12_EBREAK)
                                                   trap_code = `CAUSE_BREAKPOINT;
        // ECALL reports the calling mode: 8 from U, 9 from S, 11 from M.
        else if (priv == `U_MODE)                  trap_code = `CAUSE_ECALL_U;
        else if (priv == `S_MODE)                  trap_code = `CAUSE_ECALL_S;
        else                                       trap_code = `CAUSE_ECALL_M;
    end

    // mcause: bit 31 marks an interrupt, the low bits carry the code. Driven
    // from the latched cause, in the cycle the CSR file writes it.
    always @(*) begin
        trap_cause = {trap_is_irq_q, {(`BUS_WIDTH-5){1'b0}}, trap_code_q};
    end

    // mtval, selected by the latched cause so it cannot disagree with mcause.
    // The values are recomputed from stage 2, which is held, so they equal what
    // the detect cycle saw.
    always @(*) begin
        if (trap_is_irq_q)                            trap_tval = {`BUS_WIDTH{1'b0}};
        else case (trap_code_q)
            `CAUSE_ILLEGAL_INSTR:    trap_tval = instruction;
            `CAUSE_LOAD_MISALIGNED,
            `CAUSE_STORE_MISALIGNED: trap_tval = mem_addr;
            `CAUSE_INSTR_MISALIGNED: trap_tval = jump_target;
            // Page faults report the faulting virtual address: the data
            // address, or the PC for a fetch.
            `CAUSE_LOAD_PAGE_FAULT:  trap_tval = mem_addr;
            `CAUSE_STORE_PAGE_FAULT: trap_tval = mem_addr;
            `CAUSE_FETCH_PAGE_FAULT: trap_tval = pc;
            default:                 trap_tval = {`BUS_WIDTH{1'b0}};
        endcase
    end

    // Stalls that outrank the RV32M unit. It does not start while one is
    // active (operands may not be final) and holds a finished result until
    // they clear.
    assign pipeline_hold = xlate_stall || fence_stall ||
                           (state != STATE_RUNNING) || fault || is_system ||
                           is_mret || is_sret || trap_hold ||
                           mem_stall || fetch_stall;

    // ------------------------------------------------------------------------
    // Zicsr sequencing.
    //
    // A CSR access takes two cycles in Decode/Execute: capture the old value,
    // then store the modified one, with the pipeline frozen around both so the
    // access is atomic.
    // ------------------------------------------------------------------------
    wire csr_req = is_csr & inst_valid;

    // Nothing else may be holding stage 2 when the access commits.
    wire csr_free = !mem_stall && !fetch_stall;

    // The capture waits for any data access in flight to finish, so a CSR read
    // observes the effect of an older store (e.g. a write to the CLINT's msip
    // followed by a read of mip). It also waits out a detected trap, which must
    // not be followed by a CSR write.
    wire csr_start = csr_req && (state == STATE_RUNNING) && !fault &&
                     !mem_stall && !trap_hold;

    // The commit is tied to the instruction actually leaving stage 2. If it
    // were held, the write would repeat on every held cycle (freezing mcycle at
    // the written value, for example).
    assign csr_commit  = (state == STATE_CSR) && csr_free;
    assign csr_capture = csr_start;

    // Hold the pipeline through the capture phase. In the commit phase this is
    // low, so the instruction advances into Mem/Writeback carrying its result.
    wire csr_stall = csr_req && (state == STATE_RUNNING);

    // Wait for translation, unless the access is already going to trap with a
    // higher-priority cause (misaligned address, fetch page fault).
    assign xlate_stall = dxlate_stall && !dmmu_fault &&
                         !load_misaligned && !store_misaligned && !ifetch_fault;

    // ------------------------------------------------------------------------
    // FENCE.I handshake. busy is still low in the cycle the request is made, so
    // the request is held until busy has been seen high, and the instruction is
    // released when it falls again. The SoC must raise busy for at least one
    // cycle even when it has no caches.
    // ------------------------------------------------------------------------
    wire is_fence_i = (opcode == `OPC_MISC) && (funct3 == 3'b001) && inst_valid;

    reg fence_seen;
    always @(posedge clk or posedge rst) begin
        if (rst)                              fence_seen <= 1'b0;
        else if (!is_fence_i)                 fence_seen <= 1'b0;
        else if (cache_flush_busy)            fence_seen <= 1'b1;
    end

    // Request only once no data access is on the bus: the store ahead of
    // FENCE.I must reach the data cache before the flush starts, or it would
    // be left dirty after the write-back it was meant to be part of.
    assign fence_i_req = is_fence_i && !fence_seen && !mem_stall;

    // TLB flush, pulsed on the cycle SFENCE.VMA leaves stage 2 or a satp write
    // commits, so it never precedes the new root being written.
    wire csr_writes_satp = is_csr && csr_we && (funct12 == `CSR_SATP);
    assign sfence_req = (is_sfence && inst_valid && !pipeline_hold) ||
                        (csr_writes_satp && csr_commit);

    // Wait until the flush has both started and finished.
    assign fence_stall = is_fence_i && !(fence_seen && !cache_flush_busy);

    // ------------------------------------------------------------------------
    // Trap taking: the redirect conditions.
    // ------------------------------------------------------------------------
    wire fault_take = fault && inst_valid;

    // A trap entry or xRET may only redirect when no bus transaction is
    // outstanding. A store in Mem/Writeback is older than the trapping
    // instruction and must complete (flushing EX/MEM would drop STB
    // mid-transaction), and changing the PC under an outstanding fetch would
    // deliver the old address's data as the handler's first instruction.
    wire redirect_ok = !mem_stall && !fetch_stall;

    // Where an exception goes: medeleg, indexed by cause, delegates it to
    // S-mode, but only for traps taken from S or U. A trap never moves to a
    // less-privileged mode. Interrupts are routed by mideleg above.
    wire exc_delegated = medeleg[{1'b0, trap_code}] && (priv != `M_MODE);

    // ------------------------------------------------------------------------
    // Trap taking, in two cycles.
    //
    //   detect  a fault, interrupt or ECALL/EBREAK is seen on the instruction
    //           in stage 2. The decision, the cause and the destination mode
    //           are latched; stage 2 is held and stage 3 bubbled.
    //   take    PC <- xtvec, the CSR file records xepc/xcause/xtval and pushes
    //           the privilege stack, and both pipeline registers are flushed.
    //           The older instruction in stage 3 has already completed, so the
    //           trap is precise.
    //
    // The split is for timing: the trap decision ends the longest path in the
    // design (load data -> bypass -> ALU address -> alignment -> cause). The
    // cause is latched because an interrupt may deassert between the two
    // cycles; the trap value is recomputed from the held stage 2.
    // ------------------------------------------------------------------------
    reg        trap_pending;
    reg        trap_to_s_q;

    wire trap_condition = irq_pending || fault_take || (is_system && inst_valid);
    wire trap_detect    = trap_condition && redirect_ok && !trap_pending;

    // Held from detection until it can be taken.
    assign trap_hold = trap_detect || trap_pending;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            trap_pending  <= 1'b0;
            trap_code_q   <= 4'd0;
            trap_is_irq_q <= 1'b0;
            trap_to_s_q   <= 1'b0;
        end
        else if (trap_detect) begin
            trap_pending  <= 1'b1;
            trap_code_q   <= trap_code;
            trap_is_irq_q <= trap_is_irq;
            trap_to_s_q   <= trap_is_irq ? irq_dest_s : exc_delegated;
        end
        else if (trap_take) begin
            trap_pending  <= 1'b0;
        end
    end

    always @(*) begin
        trap_take   = trap_pending && redirect_ok;
        trap_to_s   = trap_to_s_q;
        // An xRET must not execute while a trap is on its way in, or it would
        // pop the privilege stack that the trap is about to push.
        trap_return = (is_mret || is_sret) && inst_valid && redirect_ok &&
                      !trap_hold;
        trap_ret_s  = is_sret;
    end

    // ------------------------------------------------------------------------
    // Halt detection, for the testbench and the board.
    //
    // "Halted" means a trap was taken to M-mode with mtvec still zero: a null
    // handler, from which no progress is possible. The core freezes rather
    // than spin. This is also how the bare-metal directed tests signal
    // completion: they end with an EBREAK or ECALL and install no handler.
    // ------------------------------------------------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            null_vector_trap <= 1'b0;
            halt_code        <= 4'd0;
        end
        else if (trap_take && !null_vector_trap && !trap_to_s &&
                 (mtvec_value == {`BUS_WIDTH{1'b0}})) begin
            null_vector_trap <= 1'b1;
            halt_code        <= trap_code;
        end
    end

    // CSR sequencer state. A trap aborts it before anything is committed.
    always @(posedge clk or posedge rst) begin
        if (rst)                     state <= STATE_RUNNING;
        else if (trap_take)          state <= STATE_RUNNING;
        else if (state == STATE_RUNNING) state <= csr_start ? STATE_CSR : STATE_RUNNING;
        else                         state <= csr_commit ? STATE_RUNNING : STATE_CSR;
    end

    // ------------------------------------------------------------------------
    // Stall and flush generation
    // ------------------------------------------------------------------------
    always @(*) begin
        stall_pc           = 1'b0;
        stall_first_stage  = 1'b0;
        flush_first_stage  = 1'b0;
        stall_second_stage = 1'b0;
        flush_second_stage = 1'b0;

        // Status outputs for the board and the testbench.
        halted      = null_vector_trap;
        trap_error  = null_vector_trap && (halt_code != `CAUSE_BREAKPOINT) &&
                                          (halt_code != `CAUSE_ECALL_M);
        ebreak_halt = null_vector_trap && (halt_code == `CAUSE_BREAKPOINT);
        trap_code_o = null_vector_trap ? halt_code :
                      trap_pending     ? trap_code_q : trap_code;

        if (halted) begin
            // Null trap vector: freeze.
            stall_pc           = 1'b1;
            stall_first_stage  = 1'b1;
            stall_second_stage = 1'b1;
        end
        else if (mem_stall) begin
            // An access is on the bus. Freeze everything, including EX/MEM, so
            // the transaction completes; this outranks the trap redirect.
            stall_pc           = 1'b1;
            stall_first_stage  = 1'b1;
            stall_second_stage = 1'b1;
        end
        else if (trap_take || trap_return) begin
            // Redirect. IF/ID drops the instruction fetched after the
            // offender and EX/MEM keeps the offender from committing. stall_pc
            // stays low: pc_gen takes the vector or the return address.
            flush_first_stage  = 1'b1;
            flush_second_stage = 1'b1;
        end
        else if (trap_hold) begin
            // The multi-cycle holds below all share one shape: keep the
            // instruction in Decode/Execute and bubble Mem/Writeback, so the
            // older instruction there commits exactly once.
            //
            // Trap detected, not yet taken.
            stall_pc           = 1'b1;
            stall_first_stage  = 1'b1;
            flush_second_stage = 1'b1;
        end
        else if (csr_stall) begin
            // CSR capture cycle.
            stall_pc           = 1'b1;
            stall_first_stage  = 1'b1;
            flush_second_stage = 1'b1;
        end
        else if (muldiv_stall) begin
            // A multiply or divide is still running.
            stall_pc           = 1'b1;
            stall_first_stage  = 1'b1;
            flush_second_stage = 1'b1;
        end
        else if (xlate_stall) begin
            // A page-table walk for the load or store in Decode/Execute. The
            // bubble in stage 3 also frees the data port for the walker.
            stall_pc           = 1'b1;
            stall_first_stage  = 1'b1;
            flush_second_stage = 1'b1;
        end
        else if (fence_stall) begin
            // FENCE.I is waiting for the caches.
            stall_pc           = 1'b1;
            stall_first_stage  = 1'b1;
            flush_second_stage = 1'b1;
        end
        else if (fetch_stall) begin
            // The instruction fetch has not completed. Stage 2 is held rather
            // than drained: a branch there asserts mispredict only while it is
            // in stage 2, so letting it advance while the PC is stalled would
            // lose the redirect.
            stall_pc           = 1'b1;
            stall_first_stage  = 1'b1;
            flush_second_stage = 1'b1;
        end
        else if (mispredict) begin
            // Kill the wrongly fetched instruction; the branch itself carries on.
            flush_first_stage = 1'b1;
        end
    end

endmodule
