`include "definitions.vh"
`include "CSRdefinitions.vh"
// =============================================================================
// Control unit: instruction decoder plus hazard and trap control.
//
// It decodes the instruction sitting in Decode/Execute, so it runs in parallel
// with that stage rather than being a stage of its own. Every control signal it
// produces is gated by `inst_valid`, which keeps a flushed slot from writing a
// register or a memory location.
//
// Trap handling here is deliberately minimal: RV32I has no CSRs yet, so a trap
// freezes the pipeline and raises a flag. mtvec / mepc / mcause routing arrives
// with Zicsr in stage 6 of the roadmap; the cause code is already reported on
// `trap_cause` so that plumbing is a matter of wiring, not redesign.
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

    // The PC of the instruction in Decode/Execute. Needed for mtval on an
    // instruction page fault, where the faulting address is the PC itself.
    input  wire [`BUS_WIDTH-1:0] pc,

    // --- From the MMUs ---
    // Data translation happens in Decode/Execute, where the address already is
    // for the misaligned check, so a page fault is precise through exactly the
    // machinery that was already here.
    input  wire                  dxlate_stall,   // translation not ready yet
    input  wire                  dmmu_fault,
    input  wire [3:0]            dmmu_cause,
    // A fetch that faulted arrives as a poisoned instruction: it never became
    // an instruction, so it is carried here with its own PC.
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
    output reg        csr_re,               // this access reads  (Table 7)
    output reg        csr_we,               // this access writes (Table 7)
    output wire       csr_capture,          // first of the two access cycles
    output wire       csr_commit,           // second of the two access cycles

    // --- Trap control, to the CSR file and pc_gen ---
    output reg                       trap_take,   // enter the handler this cycle
    output reg                       trap_to_s,   // ...delegated to supervisor mode
    output reg                       trap_return, // MRET or SRET
    output reg                       trap_ret_s,  // ...it was SRET
    output reg  [`BUS_WIDTH-1:0]     trap_cause,  // full mcause, interrupt bit included
    output wire                      trap_is_irq,
    output reg  [`BUS_WIDTH-1:0]     trap_tval,

    // --- Status, for the testbench and the board ---
    output reg        halted,                      // no forward progress possible
    output reg        trap_error,                  // a fault was taken
    output reg        ebreak_halt,                 // reserved, see below
    output reg  [3:0] trap_code_o                  // low bits of mcause, latched at halt
);

    // Declared here, above its first use in the decoder. A name used before it
    // is declared becomes an implicit net, which Verilator merges and Gowin
    // leaves undriven - the failure mode that cost a whole bring-up session.
    reg is_sfence;

    // Only two states are left. STATE_TRAP and STATE_HALT existed because a
    // fault had nowhere to go and the only available response was to freeze;
    // now a trap vectors, so the CSRs hold everything that needs remembering.
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

    // rd and rs1 decide whether a CSR access reads and/or writes (Table 7).
    // For the immediate forms the rs1 field is uimm, so the same bits answer
    // "is the mask zero".
    wire [4:0]  rd_field  = instruction[11:7];
    wire [4:0]  rs1_field = instruction[19:15];
    wire [4:0]  rs2_field = instruction[24:20];

    // RV32A. aq (bit 26) and rl (bit 25) are deliberately not decoded - see the
    // note in definitions.vh: this core already provides every ordering they
    // can ask for, so accepting them and doing nothing is correct rather than
    // lazy.
    wire [4:0]  funct5    = instruction[31:27];

    // The CSR specifier is the top 12 bits, same field as funct12. Only the
    // access-rule nibble is needed here; the address itself goes to the CSR
    // file from decode_exec.
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

            // RV32A. Chapter 13: LR/SC from Zalrsc, the fetch-and-op AMOs from
            // Zaamo. All of them address memory with rs1 alone, so the address
            // ALU adds a constant zero.
            //
            // Only the decode and the legality check live here. The
            // read-modify-write itself is sequenced in Mem/Writeback, next to
            // the memory port - see mem_wb.v for why it belongs there.
            `OPC_AMO: begin
                if (funct3 == `F3_AMO_W) begin
                    reg_we    = 1'b1;
                    wb_sel    = `WB_MEM;
                    imm_src   = `IMM_Z;
                    alu_src_b = `SRCB_IMM;
                    is_atomic = 1'b1;

                    case (funct5)
                        // LR is a load that also takes a reservation. rs2 is
                        // specified as 00000; a non-zero field is reserved,
                        // and trapping it now is cheaper than discovering
                        // later that something depended on it being ignored.
                        `F5_LR: begin
                            mem_re = 1'b1;
                            if (rs2_field != 5'd0) illegal_instruction = 1'b1;
                        end

                        // SC is a store that may not happen. mem_we is raised
                        // unconditionally here; Mem/Writeback withholds the
                        // actual bus write when the reservation has been lost.
                        // Raising it here is what makes a misaligned SC report
                        // cause 6 rather than cause 4.
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

            // FENCE / FENCE.TSO / PAUSE retire as NOPs: a 3-stage in-order core
            // with no store buffer is already sequentially consistent, and the
            // caches are physically indexed and coherent with themselves.
            //
            // FENCE.I (funct3 = 001) is different, and became different the
            // moment there were two caches. A program that writes instructions
            // - a boot loader copying a kernel into SDRAM, a kernel loading a
            // module - leaves them sitting dirty in the *data* cache while the
            // *instruction* cache is free to hold whatever was at those
            // addresses before. Neither cache is wrong on its own. FENCE.I is
            // the instruction that says "make them agree", and without it a
            // loader jumps into whatever the instruction cache happened to
            // have, which is usually the zeroes it was filled with.
            `OPC_MISC: begin
                // no datapath side effects; the flush is driven below
            end

            // SYSTEM covers ECALL and EBREAK (funct3 = 000) and the six Zicsr
            // read-modify-write instructions (funct3 != 000).
            `OPC_SYSTEM: begin
                case (funct3)
                    3'b000: begin
                        case (funct12)
                            `F12_ECALL, `F12_EBREAK: is_system = 1'b1;

                            // MRET is M-only. SRET needs S or M, and mstatus.TSR
                            // lets a hypervisor trap it out of S-mode - which is
                            // the entire purpose of that bit.
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

                            // WFI retires as a no-op. The spec explicitly
                            // allows that: it is a hint, and a hart is free to
                            // treat "wait for interrupt" as "carry on". A real
                            // power saving needs clock gating, which this core
                            // does not have; treating it as illegal instead
                            // would fault OpenSBI's idle loop for no benefit.
                            //
                            // mstatus.TW still has to be honoured: it exists so
                            // machine mode can stop a lower mode parking the
                            // hart indefinitely.
                            `F12_WFI: begin
                                if (mstatus_tw && priv != `M_MODE)
                                    illegal_instruction = 1'b1;
                            end

                            default: begin
                                // SFENCE.VMA is the one SYSTEM instruction told
                                // apart by funct7 rather than funct12, because
                                // its rs1 and rs2 are real operands.
                                //
                                // It invalidates the TLBs now. rs1 and rs2
                                // name an address and an ASID, and both are
                                // ignored: flushing more than was asked is
                                // always permitted, and the alternative is
                                // address-comparison logic in the TLB for a
                                // saving no kernel here will notice.
                                //
                                // TVM is honoured because that bit exists
                                // precisely to let machine mode intercept this.
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
                        // Swap. Always writes. Reads only if rd is not x0 -
                        // Table 7, and the spec is explicit that with rd = x0
                        // the instruction "shall not read the CSR and shall not
                        // cause any of the side effects that might occur on a
                        // CSR read".
                        is_csr = 1'b1;
                        reg_we = 1'b1;
                        csr_re = (rd_field != 5'd0);
                        csr_we = 1'b1;
                    end

                    `F3_CSRRS, `F3_CSRRSI,
                    `F3_CSRRC, `F3_CSRRCI: begin
                        // Set or clear bits. Always reads. Writes only if the
                        // mask is non-zero, where the mask is rs1 for the
                        // register forms and uimm for the immediate forms -
                        // the same instruction field either way.
                        //
                        // This is the rule that makes the counters readable:
                        // rdcycle is csrrs rd, cycle, x0, and with a zero mask
                        // there is no write, so no illegal-instruction
                        // exception for touching a read-only CSR.
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

    // An AMO is a read-modify-write, and the Privileged manual names cause 6
    // "Store/AMO address misaligned" - so a misaligned AMO must report 6 even
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
    // CSR access checks.
    //
    // All three raise an illegal instruction, per Privileged manual 2.1:
    // "Instructions that access a non-existent CSR are reserved. Attempts to
    // access a CSR without appropriate privilege level raise illegal-instruction
    // exceptions... Attempts to write a read-only register raise
    // illegal-instruction exceptions."
    //
    // These live here rather than in the CSR file so that every "this
    // instruction is illegal" decision is made in one place. The CSR file only
    // reports whether the address is implemented; the read-only and privilege
    // rules are pure functions of the address bits.
    //
    // The read-only check keys off csr_we, not off the instruction being a
    // write-capable opcode. That distinction is what lets csrrs rd, cycle, x0
    // read a read-only counter legally.
    // ------------------------------------------------------------------------
    wire csr_fault_missing = is_csr && !csr_exists;
    wire csr_fault_ro      = is_csr && csr_we && (csr_rw_bits == 2'b11);

    // Live now that there is more than one mode. The address encodes the lowest
    // privilege that may touch it, so this is the whole check.
    wire csr_fault_priv    = is_csr && (priv < csr_min_priv);

    // satp is readable and writable from S-mode, unless machine mode has set
    // TVM. That bit exists so a hypervisor can intercept a guest's attempts to
    // change its own translation.
    wire csr_fault_tvm     = is_csr && (funct12 == `CSR_SATP) &&
                             (priv == `S_MODE) && mstatus_tvm;

    // ------------------------------------------------------------------------
    // Counter access. cycle, time and instret are readable from M always, from
    // S only if the matching mcounteren bit is set, and from U only if both
    // mcounteren and scounteren allow it. Otherwise the access is illegal.
    //
    // This is why mcounteren had to arrive with U-mode rather than being
    // optional: without it there would be no way to deny a user process the
    // cycle counter, and the spec makes it mandatory for exactly that reason.
    // ------------------------------------------------------------------------
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
    // Trap collection. Priority follows the Privileged spec ordering.
    // ------------------------------------------------------------------------
    wire fault = illegal_instruction | branch_illegal | target_misaligned |
                 misaligned_fetch    | load_misaligned | store_misaligned |
                 dmmu_fault          | ifetch_fault    |
                 csr_fault;

    // ------------------------------------------------------------------------
    // Interrupts.
    //
    // Taken between instructions, never inside one. Three things must hold:
    //   * an interrupt is pending and enabled, and MIE is set
    //   * a valid instruction is in Decode/Execute, so there is a PC to record
    //     in mepc as "the instruction that has not run yet"
    //   * no multi-cycle operation is in flight. A CSR access is atomic and a
    //     divide is 34 cycles; interrupting either half-way would either
    //     commit part of an access or lose work with nothing to re-derive it
    //     from. `state == STATE_RUNNING` excludes the CSR commit cycle and
    //     !muldiv_stall excludes a divide in progress.
    //
    // The condition is combinational on mip, mie and mstatus, not registered.
    // The spec requires it be re-evaluated "immediately following the execution
    // of an xRET instruction or an explicit write to a CSR on which these
    // interrupt trap conditions expressly depend", so a handler that enables
    // interrupts and returns must be able to take a pending one at once.
    // ------------------------------------------------------------------------
    // Pending and enabled, split by where the interrupt is destined. mideleg
    // decides: a set bit sends that interrupt to supervisor mode.
    wire [`BUS_WIDTH-1:0] irq_active = mip & mie;
    wire [`BUS_WIDTH-1:0] irq_to_m   = irq_active & ~mideleg;
    wire [`BUS_WIDTH-1:0] irq_to_s   = irq_active &  mideleg;

    // The enable rule is asymmetric, and that asymmetry is the point: an
    // interrupt destined for a *higher* privilege than the one running is always
    // enabled, whatever that mode's xIE says. Machine mode cannot be locked out
    // of its own machine by a kernel that cleared MIE, because MIE only applies
    // while actually running in M.
    //
    //   to M:  (priv == M && MIE) || priv < M
    //   to S:  (priv == S && SIE) || priv < S       never while priv == M,
    //                                               because traps never move to
    //                                               a lower privilege
    wire m_irq_enabled = (priv == `M_MODE) ? mstatus_mie : 1'b1;
    wire s_irq_enabled = (priv == `S_MODE) ? mstatus_sie : (priv == `U_MODE);

    wire irq_m_any = (|irq_to_m) & m_irq_enabled;
    wire irq_s_any = (|irq_to_s) & s_irq_enabled;

    wire irq_boundary = inst_valid && !mem_stall && !muldiv_stall &&
                        (state == STATE_RUNNING);

    wire irq_any     = irq_m_any | irq_s_any;
    wire irq_pending = irq_any && irq_boundary;

    // "Interrupts to M-mode take priority over any interrupts to lower
    // privilege modes", so a machine-destined interrupt always wins.
    wire irq_dest_s = ~irq_m_any & irq_s_any;

    // Priority within each destination, from the Privileged manual. Machine
    // mode's list includes the supervisor interrupts, because an interrupt that
    // was *not* delegated is a machine interrupt: MEI, MSI, MTI, SEI, SSI, STI.
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
    // the instruction has not executed, so servicing the interrupt first and
    // re-executing afterwards is both correct and simpler than the reverse.
    assign trap_is_irq = irq_pending;

    // ------------------------------------------------------------------------
    // Cause and trap value
    // ------------------------------------------------------------------------
    always @(*) begin
        if (irq_pending) begin
            trap_code = irq_code;
        end
        // A fetch that could not be translated outranks everything an
        // instruction could be, and it has to: there *is* no instruction. The
        // bits sitting in the decoder are whatever the bus last returned, and
        // if they happen to decode as illegal - which random bits usually do -
        // then reporting cause 2 sends the handler to step over an instruction
        // that was never there. It steps into the same unmapped page, faults
        // again, and the machine spins on it forever.
        //
        // That is not hypothetical: it is exactly what this ordering did when
        // the check was placed one line lower.
        else if (ifetch_fault)                     trap_code = `CAUSE_FETCH_PAGE_FAULT;
        else if (illegal_instruction || branch_illegal || csr_fault)
                                                   trap_code = `CAUSE_ILLEGAL_INSTR;
        else if (target_misaligned || misaligned_fetch)
                                                   trap_code = `CAUSE_INSTR_MISALIGNED;
        else if (load_misaligned)                  trap_code = `CAUSE_LOAD_MISALIGNED;
        else if (store_misaligned)                 trap_code = `CAUSE_STORE_MISALIGNED;
        // After the alignment checks, and deliberately: the specification
        // orders a misaligned access ahead of a page fault, so an address that
        // is both must report cause 4 or 6, not 13 or 15.
        else if (dmmu_fault)                       trap_code = dmmu_cause;
        else if (is_system && funct12 == `F12_EBREAK)
                                                   trap_code = `CAUSE_BREAKPOINT;
        // ECALL reports which mode made the call: 8 from U, 9 from S, 11 from M.
        // That is how the SBI works at all - OpenSBI dispatches on cause 9 and
        // would never see a kernel's call if every ecall reported 11.
        else if (priv == `U_MODE)                  trap_code = `CAUSE_ECALL_U;
        else if (priv == `S_MODE)                  trap_code = `CAUSE_ECALL_S;
        else                                       trap_code = `CAUSE_ECALL_M;
    end

    // mcause: bit 31 marks an interrupt, the low bits carry the code. Driven
    // from the latch, because that is the cycle the CSR file writes it.
    always @(*) begin
        trap_cause = {trap_is_irq_q, {(`BUS_WIDTH-5){1'b0}}, trap_code_q};
    end

    // mtval carries the useful detail, which differs per cause. This saves the
    // handler from re-decoding the instruction or recomputing the address.
    //
    // Selected by the *latched* cause rather than by re-deriving which fault
    // fired, so it cannot disagree with mcause. The values themselves are
    // recomputed from stage 2, which is held, so they are the same values the
    // detect cycle saw - and they now come from registers rather than from the
    // bus, which is what makes this path short.
    always @(*) begin
        if (trap_is_irq_q)                            trap_tval = {`BUS_WIDTH{1'b0}};
        else case (trap_code_q)
            `CAUSE_ILLEGAL_INSTR:    trap_tval = instruction;
            `CAUSE_LOAD_MISALIGNED,
            `CAUSE_STORE_MISALIGNED: trap_tval = mem_addr;
            `CAUSE_INSTR_MISALIGNED: trap_tval = jump_target;
            // The faulting virtual address, which is what a page fault handler
            // needs: the data address for a load or store, and the instruction's
            // own PC when the fetch itself could not be translated.
            `CAUSE_LOAD_PAGE_FAULT:  trap_tval = mem_addr;
            `CAUSE_STORE_PAGE_FAULT: trap_tval = mem_addr;
            `CAUSE_FETCH_PAGE_FAULT: trap_tval = pc;
            default:                 trap_tval = {`BUS_WIDTH{1'b0}};
        endcase
    end

    // Stalls that outrank the RV32M unit. If one of these is active on the
    // cycle the result is ready, the unit holds the result rather than
    // returning to idle and losing it.
    assign pipeline_hold = xlate_stall || fence_stall ||
                           (state != STATE_RUNNING) || fault || is_system ||
                           is_mret || is_sret || trap_hold ||
                           mem_stall || fetch_stall;

    // ------------------------------------------------------------------------
    // Zicsr sequencing.
    //
    // A CSR access takes two cycles in Decode/Execute: capture the old value,
    // then store the modified one. Splitting it keeps the read and the write out
    // of the same clock edge, and lets the value that reaches rd be the same
    // snapshot the modify was computed from - which matters for the counters,
    // since they change every cycle.
    //
    // The pipeline is frozen around both cycles, which is what makes the
    // operation atomic: no other instruction can observe the CSR between the
    // read and the write.
    //
    // csr_start is gated on the higher-priority stalls for exactly the reason
    // the RV32M unit is. If the instruction ahead is a load still waiting on
    // the bus, its writeback has not happened, the register file's bypass is
    // off, and rs1 still reads the old value. Capturing then would apply a
    // stale mask.
    // ------------------------------------------------------------------------
    wire csr_req = is_csr & inst_valid;

    // Nothing above the CSR sequencer may be holding stage 2 when the access
    // finishes. This gates the commit only, not the start - see below for why
    // the start does not need it.
    wire csr_free = !mem_stall && !fetch_stall;

    // The capture waits for any memory access in flight to finish, and this
    // condition has a history worth recording.
    //
    // It is NOT about stale operands. The RV32M unit latches rs1 and rs2 when it
    // starts, so it must wait; this sequencer latches only the old CSR value and
    // reads the operand at commit, so operand freshness takes care of itself.
    // On that reasoning the guard was removed, and no test noticed.
    //
    // What it is actually about is ordering. A store in Mem/Writeback is still
    // in flight while the next instruction sits in Decode/Execute, so a CSR
    // capture that starts early can read a register whose value the store has
    // not yet produced. The concrete case: write the CLINT's msip, then read
    // mip. The write is on the bus; the capture sees mip.MSIP still clear, and
    // firmware concludes the device did not respond.
    //
    // !mem_stall alone is enough - a fetch in flight cannot change any CSR - so
    // this is narrower than the original guard and costs correspondingly less.
    // ...including a CSR access. An interrupt detected on a CSR instruction
    // would otherwise let the access start in the cycle after detection, and
    // commit a write the trap was supposed to prevent.
    wire csr_start = csr_req && (state == STATE_RUNNING) && !fault &&
                     !mem_stall && !trap_hold;

    // The commit is tied to the instruction leaving, not merely to being in
    // STATE_CSR. If something else is holding stage 2 - and with no I-cache
    // fetch_stall is asserted most cycles - the instruction cannot advance, and
    // committing anyway would write the CSR while the access stays in flight.
    // The write would then repeat on every held cycle: harmless for a swap or a
    // set, but it freezes mcycle at the written value for as long as the hold
    // lasts.
    assign csr_commit  = (state == STATE_CSR) && csr_free;
    assign csr_capture = csr_start;

    // Hold the pipeline through the capture phase. In the commit phase this is
    // low, so the instruction advances into Mem/Writeback carrying its result.
    wire csr_stall = csr_req && (state == STATE_RUNNING);

    // Wait for translation, unless the access is already going to trap. A
    // misaligned address outranks a page fault, so there is no point walking
    // the page tables for an access that is doomed either way - and doing so
    // would report the wrong cause.
    wire xlate_stall = dxlate_stall && !dmmu_fault &&
                       !load_misaligned && !store_misaligned && !ifetch_fault;

    // ------------------------------------------------------------------------
    // FENCE.I
    //
    // The handshake needs two edges, not one. Asking for a flush and then
    // waiting for busy to fall would let the instruction retire immediately:
    // busy is still low in the cycle the request is made, because nothing has
    // seen it yet. So the request is held until busy has been observed *high*,
    // and only then does its falling edge release the instruction.
    //
    // The SoC guarantees busy rises: with no caches at all it answers at once,
    // rather than leaving this waiting for something that will never happen.
    // ------------------------------------------------------------------------
    wire is_fence_i = (opcode == `OPC_MISC) && (funct3 == 3'b001) && inst_valid;

    reg fence_seen;
    always @(posedge clk or posedge rst) begin
        if (rst)                              fence_seen <= 1'b0;
        else if (!is_fence_i)                 fence_seen <= 1'b0;
        else if (cache_flush_busy)            fence_seen <= 1'b1;
    end

    // Ask while the instruction is here and the flush has not yet started -
    // but not while a data access is still on the bus.
    //
    // That last term is not defensive tidiness, it is the whole ordering
    // guarantee. FENCE.I sits in Decode/Execute while the store ahead of it is
    // still completing in Mem/Writeback. Requesting the flush there starts it
    // *before* the store has been applied, so the cache writes the line back
    // with the old contents, invalidates it, and only then takes the store -
    // which is now dirty again, after the flush that was supposed to publish
    // it. The store is the one thing FENCE.I existed to make visible, and it
    // ends up the one thing left behind.
    assign fence_i_req = is_fence_i && !fence_seen && !mem_stall;

    // One pulse, on the cycle the instruction actually retires. A TLB flush is
    // idempotent, so a wider pulse would be harmless - but a pulse that fires
    // while the instruction is still being held would flush repeatedly and, in
    // the satp case, flush before the new root had been written.
    wire csr_writes_satp = is_csr && csr_we && (funct12 == `CSR_SATP);
    assign sfence_req = (is_sfence && inst_valid && !pipeline_hold) ||
                        (csr_writes_satp && csr_commit);

    // Wait until it has both started and finished.
    wire fence_stall = is_fence_i && !(fence_seen && !cache_flush_busy);

    // ------------------------------------------------------------------------
    // Trap taking.
    //
    // A trap is no longer terminal. It is a single-cycle redirect:
    //
    //   cycle T   fault or interrupt seen on the instruction in stage 2
    //             -> flush IF/ID   kill the speculatively fetched next one
    //             -> flush EX/MEM  the offender never commits, while the older
    //                              instruction already in stage 3 finishes
    //                              normally at this edge - a precise trap
    //             -> PC <- mtvec, and the CSR file records mepc/mcause/mtval
    //                and pushes the privilege stack
    //   cycle T+1 the pipeline refills from the handler
    //
    // No state machine is needed, because nothing has to be remembered: the
    // architectural state lives in the CSRs from the moment the trap is taken.
    // The old STATE_TRAP existed only because there was nowhere to go.
    //
    // A trap must not begin a multi-cycle operation on the way out, so both the
    // CSR sequencer and the RV32M unit are suppressed when trap_take is high.
    // ------------------------------------------------------------------------
    wire fault_take = fault && inst_valid;

    // A redirect may only happen when no bus transaction is outstanding, and
    // this single condition covers two separate ways of corrupting one.
    //
    //   A store in flight. Taking the redirect flushes EX/MEM, which drops STB
    //   mid-transaction: the Wishbone rules are broken and the store is lost.
    //   The instruction in Mem/Writeback is also *older* than the one trapping,
    //   so precision requires it to finish regardless - a trap must never
    //   swallow work that already happened. Symptom: the handler hangs on its
    //   own first store.
    //
    //   A fetch in flight. Redirecting the PC changes imem_addr, and therefore
    //   ADR, while a fetch is still outstanding. The slave answers for whatever
    //   address it latched, and IF/ID accepts it as the instruction at the new
    //   PC. Symptom: the handler's first instruction is silently a word from
    //   somewhere else entirely - which is exactly how this was found.
    //
    // The existing mispredict path was already safe, because fetch_stall sits
    // above it in the stall chain and holds the PC. The trap path bypassed that
    // ordering and had to have the same protection stated explicitly.
    wire redirect_ok = !mem_stall && !fetch_stall;

    // ------------------------------------------------------------------------
    // Where the trap goes.
    //
    // For an interrupt, mideleg already decided. For an exception, medeleg does -
    // but only for a trap that happened in S-mode or U-mode. The spec is
    // explicit: "traps never transition from a more-privileged mode to a
    // less-privileged mode", so a fault taken while running in M is handled in M
    // however medeleg is set. Delegating illegal-instruction to S-mode and then
    // executing an illegal instruction in M-mode must not hand machine mode's
    // own fault to the kernel.
    //
    // Indexing medeleg by the cause code works because exception cause numbers
    // *are* the bit positions in medeleg. That is not a coincidence in the
    // encoding; it is what the register is for.
    // ------------------------------------------------------------------------
    wire exc_delegated = medeleg[{1'b0, trap_code}] && (priv != `M_MODE);

    // ------------------------------------------------------------------------
    // Trap taking, in two cycles.
    //
    // Detect in one cycle, act in the next. The reason is timing and nothing
    // else: deciding a trap is the tail of the longest chain in the design -
    // a load returning from the bus, bypassed to the ALU, added into an
    // address, checked for alignment, turned into a cause, and written to a
    // CSR, all in one cycle. Measured at 38.95 ns of a 39.27 ns budget, with
    // the trap half being the last 11.55 ns of it.
    //
    // Splitting it uses the mechanism this core already has three times over -
    // hold stage 2, bubble stage 3, act next cycle - which is how a CSR access,
    // an RV32M divide and an atomic all work. It adds no new pattern.
    //
    // What is latched is only the *decision* and the cause, not the trap value:
    //
    //   the decision took 30 ns to compute, so it has to be a register
    //   the cause is latched with it, because an interrupt can evaporate
    //     between the two cycles if its source deasserts - and then the cause
    //     would be recomputed as something else entirely
    //   the trap value is recomputed, because stage 2 is held, so every input
    //     to it is identical - and in the second cycle the load has already
    //     written the register file, so the recomputation starts from a
    //     register rather than from the bus. That is the whole point: the
    //     second cycle's path is short precisely because the first one
    //     finished.
    //
    // Both cycles require redirect_ok, exactly as the single-cycle version did.
    // Since the fetch re-requests while the PC is held, the take may wait a
    // cycle or two for a fetch to land. A trap taking three cycles instead of
    // one is invisible: the BIOS takes 64 of them in 420 000 instructions.
    // ------------------------------------------------------------------------
    reg        trap_pending;
    reg [3:0]  trap_code_q;
    reg        trap_is_irq_q;
    reg        trap_to_s_q;

    wire trap_condition = irq_pending || fault_take || (is_system && inst_valid);
    wire trap_detect    = trap_condition && redirect_ok && !trap_pending;

    // Held from detection until it can be taken.
    wire trap_hold = trap_detect || trap_pending;

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
        // An xRET must not execute while a trap is on its way in. Without this
        // an interrupt arriving on an MRET would let the MRET pop the privilege
        // stack in the detect cycle and then take the trap against the state it
        // had just changed.
        trap_return = (is_mret || is_sret) && inst_valid && redirect_ok &&
                      !trap_hold;
        trap_ret_s  = is_sret;
    end

    // ------------------------------------------------------------------------
    // Halt detection, for the testbench and the board.
    //
    // The core no longer stops on a fault, so "halted" now means the one
    // situation from which no forward progress is possible: a trap taken with
    // mtvec still zero. That is a jump to a null handler, which would loop
    // forever re-executing from address zero. Reporting it is far more useful
    // than letting the simulation spin, and it is also exactly the condition a
    // bare-metal test hits when it finishes with an ebreak and never installed
    // a handler - which is how the directed tests still signal completion.
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

    // The CSR sequencer's two-phase state, all that is left of the machine.
    always @(posedge clk or posedge rst) begin
        if (rst)                     state <= STATE_RUNNING;
        else if (trap_take)          state <= STATE_RUNNING;  // abort, nothing committed
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

        // Reported for the board and the testbench, not used to stop the core.
        halted      = null_vector_trap;
        trap_error  = null_vector_trap && (halt_code != `CAUSE_BREAKPOINT) &&
                                          (halt_code != `CAUSE_ECALL_M);
        ebreak_halt = null_vector_trap && (halt_code == `CAUSE_BREAKPOINT);
        trap_code_o = null_vector_trap ? halt_code :
                      trap_pending     ? trap_code_q : trap_code;

        if (halted) begin
            // A trap was taken with mtvec still zero, so the handler address is
            // null and there is nowhere useful to go. Freeze rather than spin.
            stall_pc           = 1'b1;
            stall_first_stage  = 1'b1;
            stall_second_stage = 1'b1;
        end
        else if (mem_stall) begin
            // An access is on the bus. Freeze everything, including EX/MEM, so
            // the transaction completes. This outranks the trap redirect for
            // the reason given above.
            stall_pc           = 1'b1;
            stall_first_stage  = 1'b1;
            stall_second_stage = 1'b1;
        end
        else if (trap_take || trap_return) begin
            // One cycle, and the whole redirect happens in it. Both pipeline
            // registers are flushed: IF/ID because the instruction fetched
            // speculatively after the offender is wrong, and EX/MEM so the
            // offender itself never commits. The instruction already in
            // Mem/Writeback finishes normally at this edge, which is what makes
            // the trap precise.
            //
            // stall_pc stays low: pc_gen is taking mtvec or mepc this cycle.
            flush_first_stage  = 1'b1;
            flush_second_stage = 1'b1;
        end
        else if (trap_hold) begin
            // Detected, not yet taken. Same shape as every other multi-cycle
            // hold in this core: keep the offending instruction in
            // Decode/Execute and bubble Mem/Writeback, so the older instruction
            // there commits exactly once and the offender never commits at all.
            stall_pc           = 1'b1;
            stall_first_stage  = 1'b1;
            flush_second_stage = 1'b1;
        end
        else if (csr_stall) begin
            // Capture cycle. Same shape as every other multi-cycle hold in this
            // core: keep the instruction in Decode/Execute and bubble
            // Mem/Writeback, so the instruction ahead commits exactly once.
            stall_pc           = 1'b1;
            stall_first_stage  = 1'b1;
            flush_second_stage = 1'b1;
        end
        else if (muldiv_stall) begin
            // A multiply or divide is still running. Hold it in Decode/Execute
            // and keep pushing bubbles into Mem/Writeback - the same shape as
            // the trap-detection cycle, and for the same reason: the older
            // instruction in Mem/Writeback must finish exactly once.
            stall_pc           = 1'b1;
            stall_first_stage  = 1'b1;
            flush_second_stage = 1'b1;
        end
        else if (xlate_stall) begin
            // A page table walk is in progress for the load or store in
            // Decode/Execute. Same shape as the RV32M, CSR and trap holds: keep
            // it in Decode/Execute and bubble Mem/Writeback.
            //
            // Bubbling stage 3 is not just for correctness here, it is what
            // makes the walk possible: the walker borrows the data port, and it
            // is only free because nothing is using it.
            stall_pc           = 1'b1;
            stall_first_stage  = 1'b1;
            flush_second_stage = 1'b1;
        end
        else if (fence_stall) begin
            // FENCE.I is waiting for the caches. Same shape as the RV32M and
            // trap stalls: hold stage 2, bubble stage 3, so the instruction
            // already in Mem/Writeback commits exactly once.
            stall_pc           = 1'b1;
            stall_first_stage  = 1'b1;
            flush_second_stage = 1'b1;
        end
        else if (fetch_stall) begin
            // The instruction memory has not answered yet.
            //
            // Hold IF/ID rather than bubbling it. Bubbling looks attractive - it
            // lets stages 2 and 3 drain while the fetch is outstanding - but it
            // silently discards a branch. A branch resolving in stage 2 asserts
            // mispredict for exactly the cycle it is there; if it advances while
            // stall_pc is blocking the redirect, the redirect is lost and
            // execution falls through the branch. Holding keeps the branch in
            // stage 2 asserting mispredict until the PC can act on it.
            //
            // Draining would not buy anything anyway: with one shared bus, a
            // data access in stage 3 cannot overlap an instruction fetch.
            //
            // Same shape as the RV32M and trap stalls: hold stage 2, bubble
            // stage 3, so the instruction already in Mem/Writeback commits
            // exactly once.
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
