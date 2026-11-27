`ifndef RISCV_DEFINITIONS_VH
`define RISCV_DEFINITIONS_VH

// =============================================================================
// This file contains definitions for the RV32IMA opcodes described in the RISC-V Unprivileged ISA Manual 
// (specifically the "RV32/64G Instruction Set Listings"),
// control codes for `alu.v`, `imm_gen.v`, and other modules,
// as well as RV32I exception causes and 
// definitions for instructions related to virtual memory and traps.
// =============================================================================

// ---------------------------------------------------------------------------
// Datapath sizes
// ---------------------------------------------------------------------------
`define BUS_WIDTH      32
`define REG_ADDR_WIDTH 5
`define REG_NUM        32

// Reset vector. Must match ORIGIN() in the linker script.
`define PC_INIT_VALUE  32'h0000_0000

// Branch Target Buffer (BTB) index width: 2**BTB_IDX_WIDTH entries
`define BTB_IDX_WIDTH 6

// Canonical NOP: addi x0, x0, 0
`define I_NOP 32'h0000_0013

// ---------------------------------------------------------------------------
// Opcodes (instruction[6:0])
// ---------------------------------------------------------------------------
`define OPC_LOAD   7'b0000011   // LB  LH  LW  LBU LHU
`define OPC_OP_IMM 7'b0010011   // ADDI SLTI SLTIU XORI ORI ANDI SLLI SRLI SRAI
`define OPC_AUIPC  7'b0010111
`define OPC_STORE  7'b0100011   // SB SH SW
`define OPC_OP     7'b0110011   // ADD SUB SLL SLT SLTU XOR SRL SRA OR AND, RV32M
`define OPC_LUI    7'b0110111
`define OPC_BRANCH 7'b1100011   // BEQ BNE BLT BGE BLTU BGEU
`define OPC_JALR   7'b1100111
`define OPC_JAL    7'b1101111
`define OPC_MISC   7'b0001111   // FENCE, FENCE.TSO, PAUSE
`define OPC_SYSTEM 7'b1110011   // ECALL, EBREAK
`define OPC_AMO    7'b0101111   // RV32A: LR.W, SC.W, AMO*.W

// ---------------------------------------------------------------------------
// funct3 fields (instruction[14:12])
// ---------------------------------------------------------------------------
// Branches
`define F3_BEQ  3'b000
`define F3_BNE  3'b001
`define F3_BLT  3'b100
`define F3_BGE  3'b101
`define F3_BLTU 3'b110
`define F3_BGEU 3'b111
// Loads
`define F3_LB   3'b000
`define F3_LH   3'b001
`define F3_LW   3'b010
`define F3_LBU  3'b100
`define F3_LHU  3'b101
// Stores
`define F3_SB   3'b000
`define F3_SH   3'b001
`define F3_SW   3'b010
// RV32M, opcode OP with funct7 = 0000001 (manual page 587)
`define F3_MUL    3'b000
`define F3_MULH   3'b001
`define F3_MULHSU 3'b010
`define F3_MULHU  3'b011
`define F3_DIV    3'b100
`define F3_DIVU   3'b101
`define F3_REM    3'b110
`define F3_REMU   3'b111
// RV32A width, chapter 13. Only .W exists on RV32; funct3 = 011 is .D (RV64).
`define F3_AMO_W  3'b010

// OP / OP-IMM ALU selects
`define F3_ADD_SUB 3'b000
`define F3_SLL     3'b001
`define F3_SLT     3'b010
`define F3_SLTU    3'b011
`define F3_XOR     3'b100
`define F3_SRL_SRA 3'b101
`define F3_OR      3'b110
`define F3_AND     3'b111

// ---------------------------------------------------------------------------
// funct7 fields (instruction[31:25]) and SYSTEM funct12 (instruction[31:20])
// ---------------------------------------------------------------------------
`define F7_BASE   7'b0000000    // ADD SLL SLT SLTU XOR SRL OR AND, SLLI SRLI
`define F7_ALT    7'b0100000    // SUB, SRA, SRAI
`define F7_MULDIV 7'b0000001    // RV32M multiply and divide
`define F12_ECALL  12'h000
`define F12_EBREAK 12'h001
// MRET is the SYSTEM instruction that returns from a machine-mode trap. It
// shares funct3 = 000 with ECALL and EBREAK and is told apart by funct12.
`define F12_MRET   12'h302
// WFI hints that the hart has nothing to do until an interrupt arrives. The
// spec permits implementing it as a no-op, which is what happens here.
`define F12_WFI    12'h105
// SRET returns from a supervisor-mode trap. Same funct3 as the others; told
// apart by funct12 like MRET.
`define F12_SRET   12'h102
// SFENCE.VMA is the exception to that pattern: rs1 and rs2 carry an address and
// an ASID, so only funct7 identifies it.
`define F7_SFENCE_VMA 7'b0001001

// ---------------------------------------------------------------------------
// RV32A funct5 (instruction[31:27]).
//
// Bits 26 and 25 are aq and rl, the acquire/release ordering hints. They are
// decoded but carry no behaviour here: a single-hart in-order core with no
// store buffer is already sequentially consistent, so every
// ordering these bits can request is already provided. They must still be
// *accepted* rather than trapped, because that is how real code is compiled -
// amoswap.w.aq is what a lock acquire looks like.x
// ---------------------------------------------------------------------------
`define F5_LR       5'b00010
`define F5_SC       5'b00011
`define F5_AMOSWAP  5'b00001
`define F5_AMOADD   5'b00000
`define F5_AMOXOR   5'b00100
`define F5_AMOAND   5'b01100
`define F5_AMOOR    5'b01000
`define F5_AMOMIN   5'b10000
`define F5_AMOMAX   5'b10100
`define F5_AMOMINU  5'b11000
`define F5_AMOMAXU  5'b11100

// ---------------------------------------------------------------------------
// ALU operation select (alu_control)
// ---------------------------------------------------------------------------
`define ALU_ADD  4'b0000
`define ALU_SUB  4'b0001
`define ALU_AND  4'b0010
`define ALU_OR   4'b0011
`define ALU_XOR  4'b0100
`define ALU_SLL  4'b0101
`define ALU_SRL  4'b0110
`define ALU_SRA  4'b0111
`define ALU_SLT  4'b1000
`define ALU_SLTU 4'b1001

// ---------------------------------------------------------------------------
// Immediate format select (imm_src)
// ---------------------------------------------------------------------------
`define IMM_I 3'd0
`define IMM_S 3'd1
`define IMM_B 3'd2
`define IMM_J 3'd3
`define IMM_U 3'd4
// A constant zero. The atomics address memory with rs1 alone - the AMO format
// is R-type and has no immediate field - so the address ALU needs a zero on
// operand B rather than a slice of the instruction.
`define IMM_Z 3'd5

// ---------------------------------------------------------------------------
// ALU operand source select
// ---------------------------------------------------------------------------
`define SRCA_RS1  2'd0          // register rs1
`define SRCA_PC   2'd1          // program counter (AUIPC)
`define SRCA_ZERO 2'd2          // constant 0 (LUI)

`define SRCB_RS2 1'b0
`define SRCB_IMM 1'b1

// ---------------------------------------------------------------------------
// Writeback source select (wb_sel)
// ---------------------------------------------------------------------------
`define WB_ALU 2'd0             // ALU result
`define WB_MEM 2'd1             // data loaded from memory
`define WB_PC4 2'd2             // return address, for JAL / JALR

// ---------------------------------------------------------------------------
// Trap causes, mcause encoding from the Privileged ISA. Only the subset the
// RV32I stage can raise is listed; the rest arrives with Zicsr.
// ---------------------------------------------------------------------------
`define CAUSE_INSTR_MISALIGNED 4'd0
`define CAUSE_ILLEGAL_INSTR    4'd2
`define CAUSE_BREAKPOINT       4'd3
`define CAUSE_LOAD_MISALIGNED  4'd4
`define CAUSE_STORE_MISALIGNED 4'd6
`define CAUSE_ECALL_M          4'd11

`endif
