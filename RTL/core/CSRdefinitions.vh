`ifndef RISCV_CSR_DEFINITIONS_VH
`define RISCV_CSR_DEFINITIONS_VH

// =============================================================================
// CSR addresses, encodings and access rules.
//
// Sources, both in doc/isa/:
//   Unprivileged manual, chapter 6 "Zicsr"  - the six instructions and Table 7,
//                                             which decides read vs write
//   Unprivileged manual, chapter 7 "Zicntr" - cycle, time, instret
//   Privileged manual, section 2.1          - address mapping conventions
//   Privileged manual, Table 1              - privilege level encoding
//
// The include guard is deliberately not RISCV_DEFINITIONS_VH: definitions.vh
// already uses that name, and sharing it means whichever file is included
// second is skipped in its entirety, with no error anywhere.
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

// ---------------------------------------------------------------------------
// Address mapping conventions, Privileged manual section 2.1.
//
//   csr[11:10]  00, 01, 10 = read/write      11 = read-only
//   csr[9:8]    lowest privilege level that may access the CSR
//
// So the two access checks are pure functions of the address, which is why the
// control unit can make them without asking the CSR file anything.
// ---------------------------------------------------------------------------
`define CSR_IS_READ_ONLY(a) (a[11:10] == 2'b11)
`define CSR_MIN_PRIV(a)     (a[9:8])

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

// Also listed as mandatory. Zero means "no configuration data structure".
`define CSR_MCONFIGPTR 12'hF15

// ---------------------------------------------------------------------------
// Machine trap setup
// ---------------------------------------------------------------------------
`define CSR_MSTATUS   12'h300
`define CSR_MISA      12'h301
`define CSR_MIE       12'h304
`define CSR_MTVEC     12'h305

// mstatush is listed in the spec's own change log as "the mandatory RV32-only
// CSR". It carries MBE and SBE, the endianness controls; on a little-endian-only
// hart both are read-only zero, so the whole register is - but it must exist, or
// a probe gets an illegal instruction instead of an answer.
`define CSR_MSTATUSH  12'h310

// medeleg (0x302), mideleg (0x303) and mcounteren (0x306) are intentionally
// absent. The Privileged manual makes them conditional on a lower privilege
// mode existing, and this hart is M-mode only, so they must not exist and
// accesses to them must raise an illegal instruction. They arrive with S-mode.

// ---------------------------------------------------------------------------
// Machine trap handling. Storage exists now; the trap logic that writes mepc,
// mcause and mtval arrives in the next step.
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
// sstatus, sie and sip are not registers of their own: they are restricted
// *views* of mstatus, mie and mip. Reading or writing a field of one reads or
// writes the same bit of the other, which is why they appear in the read mux
// but own no storage.
//
// satp exists and is read-only zero. That is not a placeholder - the spec
// defines it as how a hart says "no translation modes are supported", and Linux
// reads it exactly that way. It becomes real state with the MMU.
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
// Trap delegation and counter enables.
//
// medeleg/mideleg only exist on a hart with S-mode - the spec is explicit that
// "in harts without S-mode, the medeleg and mideleg registers should not
// exist", which is why they arrive with S-mode rather than earlier.
//
// mcounteren has the same shape of rule from the other direction: "in harts
// with U-mode, the mcounteren must be implemented... in harts without U-mode,
// the mcounteren register should not exist".
// ---------------------------------------------------------------------------
`define CSR_MEDELEG    12'h302
`define CSR_MIDELEG    12'h303
`define CSR_MCOUNTEREN 12'h306

// ---------------------------------------------------------------------------
// mstatus field positions, for the subset an M-mode-only hart needs.
//
// MIE and MPIE are the two-level privilege stack: on a trap MPIE takes MIE's
// value and MIE clears, so a handler cannot be re-interrupted before it has
// saved anything. MRET reverses it.
// ---------------------------------------------------------------------------
`define MSTATUS_SIE_BIT  1
`define MSTATUS_MIE_BIT  3
`define MSTATUS_SPIE_BIT 5
`define MSTATUS_MPIE_BIT 7
`define MSTATUS_SPP_BIT  8         // one bit: 0 = U, 1 = S
`define MSTATUS_MPP_LSB  11        // two bits, 12:11
`define MSTATUS_MPRV_BIT 17
`define MSTATUS_SUM_BIT  18
`define MSTATUS_MXR_BIT  19
`define MSTATUS_TVM_BIT  20
`define MSTATUS_TW_BIT   21
`define MSTATUS_TSR_BIT  22

// Which mstatus bits sstatus may see and change. SUM and MXR belong in this
// mask too, but they only mean anything once address translation exists, so
// they read as zero until the MMU makes them real.
// MXR(19) and SUM(18) join the supervisor's view the moment translation is
// real: they are the kernel's controls, not the firmware's, and a kernel that
// cannot set SUM cannot copy to or from user memory.
`define SSTATUS_MASK 32'h000C_0122   // MXR(19) | SUM(18) | SPP(8) | SPIE(5) | SIE(1)

// ---------------------------------------------------------------------------
// mie / mip field positions, and the matching mcause codes.
//
// An interrupt cause is the bit position with mcause bit 31 set. Machine-mode
// priority order from the Privileged manual is MEI > MSI > MTI.
// ---------------------------------------------------------------------------
`define IRQ_S_SOFT  1
`define IRQ_M_SOFT  3
`define IRQ_S_TIMER 5
`define IRQ_M_TIMER 7
`define IRQ_S_EXT   9
`define IRQ_M_EXT   11

`define MCAUSE_IRQ_BIT 31

`define CAUSE_IRQ_S_SOFT  4'd1
`define CAUSE_IRQ_M_SOFT  4'd3
`define CAUSE_IRQ_S_TIMER 4'd5
`define CAUSE_IRQ_M_TIMER 4'd7
`define CAUSE_IRQ_S_EXT   4'd9
`define CAUSE_IRQ_M_EXT   4'd11

// ---------------------------------------------------------------------------
// Delegation masks: which bits of medeleg / mideleg are writable.
//
// The spec permits subsetting the delegatable traps, with software discovering
// the set by writing all ones and reading back. Two rules constrain it: no bit
// of medeleg may be read-only *one* (anything delegatable must also be able to
// stay undelegated), and no machine-level interrupt bit of mideleg may be
// read-only one.
//
// mideleg therefore allows only the three supervisor interrupts. The machine
// ones are read-only zero: an M-mode interrupt delegated to S-mode would be a
// trap moving to a lower privilege, which never happens.
//
// medeleg allows every exception this core can raise except ECALL-from-M, which
// is unreachable anyway because a trap taken in M-mode is never delegated. The
// three page-fault causes are included ahead of the MMU: they cannot fire yet,
// so allowing them changes no behaviour, and it means the MMU work does not
// begin by discovering that its faults cannot be delegated.
// ---------------------------------------------------------------------------
// satp. Sv32 defines exactly two modes - bare (0) and Sv32 (1) - so the whole
// register is writable and there is nothing to mask. WARL has nothing to do
// here, which is the difference between this and every other field above.
`define SATP_MODE_BIT 31

`define MIDELEG_MASK 32'h0000_0222   // SEI(9) | STI(5) | SSI(1)
`define MEDELEG_MASK 32'h0000_B35D   // store/instr/load page fault (15,13,12),
                                     // ECALL S(9) U(8), store misaligned(6),
                                     // load misaligned(4), breakpoint(3),
                                     // illegal(2), instr misaligned(0)

// Which mip bits software may write. The machine trio is hardware-driven and
// read-only: a timer interrupt is cleared by moving mtimecmp, an external one by
// claiming at the PLIC, a software one through the CLINT's msip. The supervisor
// trio has no such device behind it - M-mode software raises and clears them
// directly, which is how OpenSBI delivers a timer tick to a kernel without Sstc.
`define MIP_SW_MASK  32'h0000_0222   // SEIP(9) | STIP(5) | SSIP(1)

// Counter-enable bits, shared by mcounteren and scounteren.
`define CTREN_CY 0
`define CTREN_TM 1
`define CTREN_IR 2

// Exception causes added by the privileged modes.
// Sv32 page faults. Four bits is enough: 15 is the largest cause this core can
// raise, and mcause's remaining bits are zero for every one of them.
`define CAUSE_FETCH_PAGE_FAULT 4'd12
`define CAUSE_LOAD_PAGE_FAULT  4'd13
`define CAUSE_STORE_PAGE_FAULT 4'd15

`define CAUSE_ECALL_U     4'd8
`define CAUSE_ECALL_S     4'd9

// ---------------------------------------------------------------------------
// misa: MXL = 1 (RV32) in bits 31:30, plus one bit per extension letter.
// A is bit 0, I is bit 8, M is bit 12. Read-only here - the extension set is
// fixed by the hardware, and WARL permits an implementation to ignore writes.
//
// This register is not decoration. OpenSBI reads it to decide what the hart can
// do, and Linux's early boot checks it against what the kernel was built for -
// so an A implementation that does not advertise itself here is an A
// implementation nobody will use.
//
// ---------------------------------------------------------------------------
`define MISA_VALUE 32'h4014_1101    // RV32 + I + M + A + S + U

// Reported identity. 0 in mvendorid means "non-commercial implementation".
`define MVENDORID_VALUE 32'h0000_0000
`define MARCHID_VALUE   32'h0000_0000
`define MIMPID_VALUE    32'h0000_0003   // stage 3 of the roadmap
`define MHARTID_VALUE   32'h0000_0000   // single hart

`endif // RISCV_CSR_DEFINITIONS_VH
