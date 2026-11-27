`ifndef RISCV_CSR_DEFINITIONS_VH
`define RISCV_CSR_DEFINITIONS_VH

// =============================================================================
// CSR addresses, privileged-architecture encodings and implementation values.
//
// References:
//   Unprivileged manual, "Zicsr"  - the six CSR instructions and the rule
//                                   deciding whether an access reads or writes
//   Unprivileged manual, "Zicntr" - cycle, time, instret
//   Privileged manual, 2.1        - CSR address mapping conventions
//
// The include guard must differ from definitions.vh's: sharing one would make
// whichever header is included second silently disappear.
// =============================================================================

// ---------------------------------------------------------------------------
// Privilege levels, Privileged manual Table 1.
// Level 2 (10) is reserved, which is why S is 01 and not 10.
// ---------------------------------------------------------------------------
`define U_MODE 2'b00
`define S_MODE 2'b01
`define M_MODE 2'b11

// ---------------------------------------------------------------------------
// CSR instruction funct3, under opcode SYSTEM. funct3 = 000 is ECALL/EBREAK.
// The immediate forms take a 5-bit zero-extended uimm from the rs1 field.
// ---------------------------------------------------------------------------
`define F3_CSRRW  3'b001
`define F3_CSRRS  3'b010
`define F3_CSRRC  3'b011
`define F3_CSRRWI 3'b101
`define F3_CSRRSI 3'b110
`define F3_CSRRCI 3'b111

// Bit 2 of funct3 separates register forms from immediate forms
`define CSR_IS_IMM(f3) (f3[2])

// Address mapping conventions (Privileged manual 2.1), used by the control
// unit's access checks:
//   csr[11:10]  00, 01, 10 = read/write      11 = read-only
//   csr[9:8]    lowest privilege level that may access the CSR

// ---------------------------------------------------------------------------
// Unprivileged counters and timers (Zicntr). Read-only, hence 0xC__.
// 64 bits wide even on RV32, read as two halves.
// ---------------------------------------------------------------------------
`define CSR_CYCLE     12'hC00
`define CSR_TIME      12'hC01
`define CSR_INSTRET   12'hC02
`define CSR_CYCLEH    12'hC80
`define CSR_TIMEH     12'hC81
`define CSR_INSTRETH  12'hC82

// ---------------------------------------------------------------------------
// Machine information registers. Read-only.
// ---------------------------------------------------------------------------
`define CSR_MVENDORID 12'hF11
`define CSR_MARCHID   12'hF12
`define CSR_MIMPID    12'hF13
`define CSR_MHARTID   12'hF14

// Zero means "no configuration data structure".
`define CSR_MCONFIGPTR 12'hF15

// ---------------------------------------------------------------------------
// Machine trap setup
// ---------------------------------------------------------------------------
`define CSR_MSTATUS   12'h300
`define CSR_MISA      12'h301
`define CSR_MIE       12'h304
`define CSR_MTVEC     12'h305

// mstatush is mandatory on RV32. It holds only the endianness controls MBE and
// SBE, which are read-only zero on a little-endian hart, but it must exist so a
// probe reads zero instead of trapping.
`define CSR_MSTATUSH  12'h310

// ---------------------------------------------------------------------------
// Machine trap handling
// ---------------------------------------------------------------------------
`define CSR_MSCRATCH  12'h340
`define CSR_MEPC      12'h341
`define CSR_MCAUSE    12'h342
`define CSR_MTVAL     12'h343
`define CSR_MIP       12'h344

// ---------------------------------------------------------------------------
// Machine counters. mcycle and minstret are the writable originals; the 0xC__
// addresses above are read-only views of the same counters.
//
// There is deliberately no mtime here: the real-time counter is memory mapped
// in the CLINT, not a CSR. Only `time` at 0xC01 reads it.
// ---------------------------------------------------------------------------
`define CSR_MCYCLE    12'hB00
`define CSR_MINSTRET  12'hB02
`define CSR_MCYCLEH   12'hB80
`define CSR_MINSTRETH 12'hB82

// ---------------------------------------------------------------------------
// Supervisor-level CSRs.
//
// sstatus, sie and sip own no storage: they are restricted views of mstatus,
// mie and mip.
// ---------------------------------------------------------------------------
`define CSR_SSTATUS    12'h100
`define CSR_SIE        12'h104
`define CSR_STVEC      12'h105
`define CSR_SCOUNTEREN 12'h106
`define CSR_SSCRATCH   12'h140
`define CSR_SEPC       12'h141
`define CSR_SCAUSE     12'h142
`define CSR_STVAL      12'h143
`define CSR_SIP        12'h144
`define CSR_SATP       12'h180

// ---------------------------------------------------------------------------
// Trap delegation and counter enables. The spec requires medeleg/mideleg on a
// hart with S-mode and mcounteren on a hart with U-mode.
// ---------------------------------------------------------------------------
`define CSR_MEDELEG    12'h302
`define CSR_MIDELEG    12'h303
`define CSR_MCOUNTEREN 12'h306

// ---------------------------------------------------------------------------
// mstatus field positions. MPP is the two-bit field 12:11.
//
// xIE/xPIE/xPP form a per-mode stack: on a trap xPIE takes xIE's value and
// xIE clears, so a handler cannot be re-interrupted before it has saved
// anything. xRET reverses it.
// ---------------------------------------------------------------------------
`define MSTATUS_SIE_BIT  1
`define MSTATUS_MIE_BIT  3
`define MSTATUS_SPIE_BIT 5
`define MSTATUS_MPIE_BIT 7
`define MSTATUS_SPP_BIT  8         // one bit: 0 = U, 1 = S
`define MSTATUS_MPRV_BIT 17
`define MSTATUS_SUM_BIT  18
`define MSTATUS_MXR_BIT  19
`define MSTATUS_TVM_BIT  20
`define MSTATUS_TW_BIT   21
`define MSTATUS_TSR_BIT  22

// The mstatus bits visible through sstatus. SUM and MXR are the kernel's
// translation controls: without SUM it cannot copy to or from user memory.
`define SSTATUS_MASK 32'h000C_0122   // MXR(19) | SUM(18) | SPP(8) | SPIE(5) | SIE(1)

// ---------------------------------------------------------------------------
// mie / mip field positions, and the matching mcause codes.
//
// An interrupt's cause code equals its bit position, reported with mcause
// bit 31 set.
// ---------------------------------------------------------------------------
`define IRQ_S_SOFT  1
`define IRQ_M_SOFT  3
`define IRQ_S_TIMER 5
`define IRQ_M_TIMER 7
`define IRQ_S_EXT   9
`define IRQ_M_EXT   11

`define CAUSE_IRQ_S_SOFT  4'd1
`define CAUSE_IRQ_M_SOFT  4'd3
`define CAUSE_IRQ_S_TIMER 4'd5
`define CAUSE_IRQ_M_TIMER 4'd7
`define CAUSE_IRQ_S_EXT   4'd9
`define CAUSE_IRQ_M_EXT   4'd11

// ---------------------------------------------------------------------------
// Delegation masks: which bits of medeleg / mideleg are writable. Software
// discovers the delegatable set by writing all ones and reading back.
//
// mideleg allows only the three supervisor interrupts; machine interrupts are
// never delegated. medeleg allows every exception this core can raise except
// ECALL-from-M, which cannot be delegated because a trap taken in M-mode always
// stays in M-mode.
// ---------------------------------------------------------------------------
`define MIDELEG_MASK 32'h0000_0222   // SEI(9) | STI(5) | SSI(1)
`define MEDELEG_MASK 32'h0000_B35D   // store/instr/load page fault (15,13,12),
                                     // ECALL S(9) U(8), store misaligned(6),
                                     // load misaligned(4), breakpoint(3),
                                     // illegal(2), instr misaligned(0)

// Counter-enable bits, shared by mcounteren and scounteren.
`define CTREN_CY 0
`define CTREN_TM 1
`define CTREN_IR 2

// Exception causes added by the privileged modes and the Sv32 MMU. Four bits
// suffice: 15 is the largest cause this core raises.
`define CAUSE_FETCH_PAGE_FAULT 4'd12
`define CAUSE_LOAD_PAGE_FAULT  4'd13
`define CAUSE_STORE_PAGE_FAULT 4'd15

`define CAUSE_ECALL_U     4'd8
`define CAUSE_ECALL_S     4'd9

// ---------------------------------------------------------------------------
// misa: MXL = 1 (RV32) in bits 31:30, plus one bit per extension letter
// (A = 0, I = 8, M = 12, S = 18, U = 20). Read-only: the extension set is fixed,
// and WARL permits ignoring writes. OpenSBI and Linux both read it to discover
// what the hart supports. Z* extensions have no misa bit.
// ---------------------------------------------------------------------------
`define MISA_VALUE 32'h4014_1101    // RV32 + I + M + A + S + U

// Reported identity. 0 in mvendorid means "non-commercial implementation".
`define MVENDORID_VALUE 32'h0000_0000
`define MARCHID_VALUE   32'h0000_0000
`define MIMPID_VALUE    32'h0000_0003   // implementation revision
`define MHARTID_VALUE   32'h0000_0000   // single hart

`endif // RISCV_CSR_DEFINITIONS_VH
