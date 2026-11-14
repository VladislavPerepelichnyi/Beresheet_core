`include "definitions.vh"
`include "CSRdefinitions.vh"

// =============================================================================
// Control and Status Register file, M / S / U.
//
// Holds every privileged register the core implements, plus the current
// privilege mode, and answers one access per request. It does three things:
//
//   * storage, the read multiplexer, and `exists`
//   * the architectural state change on a trap and on an xRET
//   * the current privilege level, which it owns because a trap changes it
//
// It deliberately does NOT decide whether an access is legal. Writing a
// read-only CSR, reaching one from too low a privilege, and reading a counter
// the enable registers forbid are all decisions the control unit makes next to
// every other trap it raises. Keeping one place that decides "this instruction
// is illegal" is worth more than keeping each check next to its storage.
//
// It also does not decide *where* a trap goes. That needs medeleg / mideleg,
// which live here, so they are exported and the control unit combines them with
// the cause it already computed. The result comes back as `trap_to_s`.
//
// Three registers own no storage at all. sstatus, sie and sip are restricted
// *views* of mstatus, mie and mip - the spec is explicit that "reading any
// implemented field, or writing any writable field, of sip/sie effects a read
// or write of the homonymous field of mip/mie". Implementing them as separate
// state would be a bug waiting to happen.
// =============================================================================
module CSR_unit (
    input  wire clk,
    input  wire rst,

    // --- Access port, driven from Decode/Execute ---
    input  wire [11:0]           addr,
    input  wire                  re,        // this access reads  (Table 7)
    input  wire                  we,        // this access writes (Table 7)
    input  wire [`BUS_WIDTH-1:0] wdata,     // value to store, already modified
    output reg  [`BUS_WIDTH-1:0] rdata,
    output reg                   exists,    // addressed CSR is implemented
    // The read-modify-write must not see the PLIC's half of mip.SEIP. rdata
    // returns sw | hw, as the spec requires for rd, but CSRRS/CSRRC have to
    // modify the software bit alone (privileged spec, mip/SEIP). Set when the
    // access is to mip and that software bit is clear, so Decode/Execute can
    // take bit 9 out of the value it modifies.
    output wire                  rmw_seip_hw_only,

    // --- Hardware trap entry. Takes priority over a software CSR write in the
    //     same cycle, which cannot happen anyway: the trapping instruction is
    //     flushed rather than committed.
    input  wire                  trap_take,
    input  wire                  trap_to_s,    // delegated to supervisor mode
    input  wire [`BUS_WIDTH-1:0] trap_epc,     // PC of the trapping instruction
    input  wire [`BUS_WIDTH-1:0] trap_cause,   // full cause, interrupt bit included
    input  wire [`BUS_WIDTH-1:0] trap_tval,
    input  wire                  trap_return,  // MRET or SRET
    input  wire                  trap_ret_s,   // ...it was SRET

    // --- Counter inputs ---
    input  wire                  instret,   // one instruction retired

    // --- Real time, from the CLINT. `time` is defined as a read-only view of
    //     the CLINT's memory-mapped mtime, not a counter of its own.
    input  wire [63:0]           mtime,

    // --- Interrupt pins.
    //
    //     The machine trio is hardware-driven and read-only in mip: a timer
    //     interrupt is cleared by writing mtimecmp in the CLINT, an external one
    //     through the PLIC's claim/complete, a software one through msip.
    //
    //     irq_ext_s is the PLIC's second context. It is OR-ed into mip.SEIP
    //     alongside a software-writable bit, which is what the spec asks for:
    //     the value read is the logical OR of the two.
    input  wire                  irq_soft,
    input  wire                  irq_timer,
    input  wire                  irq_ext,
    input  wire                  irq_ext_s,

    // --- Exported to the control unit and pc_gen ---
    output wire [1:0]            priv_o,        // current privilege mode
    output wire [`BUS_WIDTH-1:0] mtvec_o,
    output wire [`BUS_WIDTH-1:0] stvec_o,
    output wire [`BUS_WIDTH-1:0] mepc_o,
    output wire [`BUS_WIDTH-1:0] sepc_o,
    output wire                  mstatus_mie_o,
    output wire                  mstatus_sie_o,
    output wire                  mstatus_tvm_o, // trap satp access from S
    output wire [`BUS_WIDTH-1:0] satp_o,        // to the MMUs
    output wire [1:0]            mstatus_mpp_o, // MPRV uses this as the
    output wire                  mstatus_mprv_o,//   effective mode for data
    output wire                  mstatus_sum_o, // permit S access to U pages
    output wire                  mstatus_mxr_o, // make executable readable
    output wire                  mstatus_tw_o,  // trap WFI outside M
    output wire                  mstatus_tsr_o, // trap SRET in S
    output wire [`BUS_WIDTH-1:0] mip_o,
    output wire [`BUS_WIDTH-1:0] mie_o,
    output wire [`BUS_WIDTH-1:0] medeleg_o,
    output wire [`BUS_WIDTH-1:0] mideleg_o,
    output wire [2:0]            mcounteren_o,
    output wire [2:0]            scounteren_o
);

    // ------------------------------------------------------------------------
    // Privilege mode.
    //
    // Reset to M, per the spec: a hart comes up in machine mode with no
    // interrupts enabled, because nothing else is set up yet.
    // ------------------------------------------------------------------------
    reg [1:0] priv;
    assign priv_o = priv;

    // ------------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------------
    // mstatus, one register per field. Two two-level stacks live here:
    // MIE/MPIE/MPP for machine mode and SIE/SPIE/SPP for supervisor mode. A
    // trap pushes one of them, the matching xRET pops it.
    reg        mstatus_mie,  mstatus_sie;
    reg        mstatus_mpie, mstatus_spie;
    reg [1:0]  mstatus_mpp;                 // 00 U, 01 S, 11 M
    reg        mstatus_spp;                 // 0 U, 1 S - S was never entered from M
    reg        mstatus_mprv;                // now real: see the MMU's eff_priv
    reg        mstatus_sum, mstatus_mxr;   // likewise
    reg [`BUS_WIDTH-1:0] satp;
    reg        mstatus_tvm, mstatus_tw, mstatus_tsr;

    reg [`BUS_WIDTH-1:0] mtvec, mscratch, mepc, mcause, mtval;
    reg [`BUS_WIDTH-1:0] stvec, sscratch, sepc, scause, stval;

    reg [`BUS_WIDTH-1:0] medeleg, mideleg;

    // Interrupt enables, one bit per implemented source.
    reg        mie_msie, mie_mtie, mie_meie;
    reg        mie_ssie, mie_stie, mie_seie;

    // Software-writable pending bits. The supervisor trio has no device behind
    // it - M-mode software raises and clears them, which is how OpenSBI hands a
    // timer tick to a kernel on a hart without Sstc.
    reg        mip_ssip, mip_stip, mip_seip_sw;

    reg [2:0]  mcounteren, scounteren;      // CY, TM, IR

    // ------------------------------------------------------------------------
    // Counters, 64 bits each even on RV32 (Zicntr, chapter 7). Software reads
    // them as two halves and re-reads the high half to detect a carry, which is
    // exactly why the spec insists on 64 bits.
    // ------------------------------------------------------------------------
    reg [63:0] cycle_ctr;
    reg [63:0] instret_ctr;

    // ------------------------------------------------------------------------
    // Assembled read values
    // ------------------------------------------------------------------------
    // Concatenations rather than shifted ORs, so the bit positions are readable
    // straight off the source and the widths are right by construction.
    //
    // SUM (18) and MXR (19) are real state now; see the MMU's permission
    // checker. The comment below is what they used to be.
    // SUM (18) and MXR (19) are read-only zero: they only mean anything once
    // address translation exists. FS, VS, XS and SD are zero because there is
    // no floating-point or vector state to track. UBE (6) is zero because this
    // hart is little-endian only.
    wire [`BUS_WIDTH-1:0] mstatus_val = {1'b0,           // 31    SD
                                         8'd0,           // 30:23
                                         mstatus_tsr,    // 22
                                         mstatus_tw,     // 21
                                         mstatus_tvm,    // 20
                                         mstatus_mxr,    // 19    MXR
                                         mstatus_sum,    // 18    SUM
                                         mstatus_mprv,   // 17
                                         2'd0,           // 16:15 XS
                                         2'd0,           // 14:13 FS
                                         mstatus_mpp,    // 12:11
                                         2'd0,           // 10:9  VS
                                         mstatus_spp,    //  8
                                         mstatus_mpie,   //  7
                                         1'b0,           //  6    UBE
                                         mstatus_spie,   //  5
                                         1'b0,           //  4
                                         mstatus_mie,    //  3
                                         1'b0,           //  2
                                         mstatus_sie,    //  1
                                         1'b0};          //  0

    // sstatus shows the supervisor half of the same register, nothing more.
    wire [`BUS_WIDTH-1:0] sstatus_val = mstatus_val & `SSTATUS_MASK;

    wire [`BUS_WIDTH-1:0] mie_val = {20'd0,              // 31:12
                                     mie_meie,           // 11
                                     1'b0,               // 10
                                     mie_seie,           //  9
                                     1'b0,               //  8
                                     mie_mtie,           //  7
                                     1'b0,               //  6
                                     mie_stie,           //  5
                                     1'b0,               //  4
                                     mie_msie,           //  3
                                     1'b0,               //  2
                                     mie_ssie,           //  1
                                     1'b0};              //  0

    // mip.SEIP reads as the OR of the software-writable bit and the PLIC's
    // supervisor context, which is what the spec specifies. Writes land on the
    // software bit alone - see the write port.
    wire [`BUS_WIDTH-1:0] mip_val = {20'd0,                    // 31:12
                                     irq_ext,                  // 11 MEIP
                                     1'b0,                     // 10
                                     mip_seip_sw | irq_ext_s,  //  9 SEIP
                                     1'b0,                     //  8
                                     irq_timer,                //  7 MTIP
                                     1'b0,                     //  6
                                     mip_stip,                 //  5 STIP
                                     1'b0,                     //  4
                                     irq_soft,                 //  3 MSIP
                                     1'b0,                     //  2
                                     mip_ssip,                 //  1 SSIP
                                     1'b0};                    //  0

    // An interrupt is visible in sip / maskable in sie only if it is delegated.
    // Everything else reads as zero there.
    wire [`BUS_WIDTH-1:0] sip_val = mip_val & mideleg;

    // Without this, OpenSBI's `csrs/csrc mip, MIP_STIP` on every timer tick
    // copied the PLIC's live SEIP into mip_seip_sw whenever a supervisor
    // external interrupt happened to be pending. SEIP then stayed set after
    // the device was serviced, the kernel's claim read 0, and it took the
    // interrupt again forever - a livelock in plic_handle_irq the first time
    // the UART interrupt raced a timer tick (serial8250_do_startup).
    assign rmw_seip_hw_only = (addr == `CSR_MIP) && !mip_seip_sw;
    wire [`BUS_WIDTH-1:0] sie_val = mie_val & mideleg;

    assign mtvec_o       = mtvec;
    assign stvec_o       = stvec;
    assign mepc_o        = mepc;
    assign sepc_o        = sepc;
    assign mstatus_mie_o = mstatus_mie;
    assign mstatus_sie_o = mstatus_sie;
    assign mstatus_tvm_o = mstatus_tvm;
    assign mstatus_tw_o  = mstatus_tw;
    assign mstatus_tsr_o = mstatus_tsr;
    assign mip_o         = mip_val;
    assign mie_o         = mie_val;
    assign medeleg_o     = medeleg;
    assign mideleg_o     = mideleg;
    assign mcounteren_o  = mcounteren;
    assign scounteren_o  = scounteren;

    // ------------------------------------------------------------------------
    // Read multiplexer, and the implemented-address decode.
    //
    // One case statement gives both, which keeps them from drifting apart: an
    // address that returns data here is exactly an address that reports
    // exists = 1. `re` does not gate the value, because no CSR in this file has
    // a read side effect - the spec notes standard CSRs never do.
    // ------------------------------------------------------------------------
    always @(*) begin
        exists = 1'b1;
        case (addr)
            // Unprivileged counters, read-only views of the same state
            `CSR_CYCLE:     rdata = cycle_ctr[31:0];
            `CSR_CYCLEH:    rdata = cycle_ctr[63:32];
            `CSR_TIME:      rdata = mtime[31:0];
            `CSR_TIMEH:     rdata = mtime[63:32];
            `CSR_INSTRET:   rdata = instret_ctr[31:0];
            `CSR_INSTRETH:  rdata = instret_ctr[63:32];

            // Machine counters, writable originals
            `CSR_MCYCLE:    rdata = cycle_ctr[31:0];
            `CSR_MCYCLEH:   rdata = cycle_ctr[63:32];
            `CSR_MINSTRET:  rdata = instret_ctr[31:0];
            `CSR_MINSTRETH: rdata = instret_ctr[63:32];

            // Machine information
            `CSR_MVENDORID: rdata = `MVENDORID_VALUE;
            `CSR_MARCHID:   rdata = `MARCHID_VALUE;
            `CSR_MIMPID:    rdata = `MIMPID_VALUE;
            `CSR_MHARTID:   rdata = `MHARTID_VALUE;
            `CSR_MCONFIGPTR: rdata = {`BUS_WIDTH{1'b0}};

            // Machine trap setup and handling
            `CSR_MSTATUS:   rdata = mstatus_val;
            `CSR_MISA:      rdata = `MISA_VALUE;
            // Mandatory, and read-only zero on a little-endian-only hart
            `CSR_MSTATUSH:  rdata = {`BUS_WIDTH{1'b0}};
            `CSR_MEDELEG:   rdata = medeleg;
            `CSR_MIDELEG:   rdata = mideleg;
            `CSR_MIE:       rdata = mie_val;
            `CSR_MTVEC:     rdata = mtvec;
            `CSR_MCOUNTEREN: rdata = {29'd0, mcounteren};
            `CSR_MSCRATCH:  rdata = mscratch;
            `CSR_MEPC:      rdata = mepc;
            `CSR_MCAUSE:    rdata = mcause;
            `CSR_MTVAL:     rdata = mtval;
            `CSR_MIP:       rdata = mip_val;

            // Supervisor trap setup and handling. sstatus, sie and sip are
            // views; the rest is real state.
            `CSR_SSTATUS:   rdata = sstatus_val;
            `CSR_SIE:       rdata = sie_val;
            `CSR_STVEC:     rdata = stvec;
            `CSR_SCOUNTEREN: rdata = {29'd0, scounteren};
            `CSR_SSCRATCH:  rdata = sscratch;
            `CSR_SEPC:      rdata = sepc;
            `CSR_SCAUSE:    rdata = scause;
            `CSR_STVAL:     rdata = stval;
            `CSR_SIP:       rdata = sip_val;

            `CSR_SATP:      rdata = satp;

            default: begin
                rdata  = {`BUS_WIDTH{1'b0}};
                exists = 1'b0;
            end
        endcase
    end

    // ------------------------------------------------------------------------
    // MPP is WARL: only 00 (U), 01 (S) and 11 (M) are supported modes, so a
    // write of the reserved 10 has to land somewhere legal. M is the safe
    // choice - it cannot grant a privilege the writer did not already have.
    // ------------------------------------------------------------------------
    function [1:0] legal_mpp(input [1:0] v);
        legal_mpp = (v == 2'b10) ? `M_MODE : v;
    endfunction

    // ------------------------------------------------------------------------
    // Write port, trap entry, trap return, counters
    // ------------------------------------------------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            priv         <= `M_MODE;
            mstatus_mie  <= 1'b0;
            mstatus_sie  <= 1'b0;
            mstatus_mpie <= 1'b0;
            mstatus_spie <= 1'b0;
            mstatus_mpp  <= `M_MODE;
            mstatus_spp  <= 1'b0;
            mstatus_mprv <= 1'b0;
            mstatus_sum  <= 1'b0;
            mstatus_mxr  <= 1'b0;
            satp         <= {`BUS_WIDTH{1'b0}};
            mstatus_tvm  <= 1'b0;
            mstatus_tw   <= 1'b0;
            mstatus_tsr  <= 1'b0;
            mtvec        <= {`BUS_WIDTH{1'b0}};
            mscratch     <= {`BUS_WIDTH{1'b0}};
            mepc         <= {`BUS_WIDTH{1'b0}};
            mcause       <= {`BUS_WIDTH{1'b0}};
            mtval        <= {`BUS_WIDTH{1'b0}};
            stvec        <= {`BUS_WIDTH{1'b0}};
            sscratch     <= {`BUS_WIDTH{1'b0}};
            sepc         <= {`BUS_WIDTH{1'b0}};
            scause       <= {`BUS_WIDTH{1'b0}};
            stval        <= {`BUS_WIDTH{1'b0}};
            medeleg      <= {`BUS_WIDTH{1'b0}};
            mideleg      <= {`BUS_WIDTH{1'b0}};
            mie_msie     <= 1'b0;
            mie_mtie     <= 1'b0;
            mie_meie     <= 1'b0;
            mie_ssie     <= 1'b0;
            mie_stie     <= 1'b0;
            mie_seie     <= 1'b0;
            mip_ssip     <= 1'b0;
            mip_stip     <= 1'b0;
            mip_seip_sw  <= 1'b0;
            mcounteren   <= 3'b000;
            scounteren   <= 3'b000;
            cycle_ctr    <= 64'd0;
            instret_ctr  <= 64'd0;
        end
        else begin
            // ----------------------------------------------------------------
            // Counters advance first, so an explicit write below overrides the
            // increment for that cycle rather than racing it.
            // ----------------------------------------------------------------
            cycle_ctr <= cycle_ctr + 64'd1;
            if (instret)
                instret_ctr <= instret_ctr + 64'd1;

            // ----------------------------------------------------------------
            // Trap entry, in one cycle, into whichever mode owns the trap.
            //
            // The two halves are exact mirrors, and the spec spells out that
            // they do not overlap: when a trap goes to S-mode, "the mcause,
            // mepc, and mtval registers and the MPP and MPIE fields of mstatus
            // are not written". Writing both would corrupt an outer M-mode
            // context that is still live.
            //
            // Interrupts are disabled on entry either way, which is what makes
            // a two-entry stack per mode sufficient: the handler cannot be
            // re-interrupted before it has saved anything.
            // ----------------------------------------------------------------
            if (trap_take) begin
                if (trap_to_s) begin
                    sepc         <= {trap_epc[`BUS_WIDTH-1:2], 2'b00};
                    scause       <= trap_cause;
                    stval        <= trap_tval;
                    // SPP is one bit because S-mode is only ever entered from
                    // S or U - a trap in M-mode is never delegated.
                    mstatus_spp  <= (priv != `U_MODE);
                    mstatus_spie <= mstatus_sie;
                    mstatus_sie  <= 1'b0;
                    priv         <= `S_MODE;
                end
                else begin
                    mepc         <= {trap_epc[`BUS_WIDTH-1:2], 2'b00};
                    mcause       <= trap_cause;
                    mtval        <= trap_tval;
                    mstatus_mpp  <= priv;
                    mstatus_mpie <= mstatus_mie;
                    mstatus_mie  <= 1'b0;
                    priv         <= `M_MODE;
                end
            end
            // ----------------------------------------------------------------
            // xRET pops the matching stack: xIE <- xPIE, xPIE <- 1, xPP <- the
            // least privileged supported mode, privilege <- xPP.
            //
            // Setting xPP to U looks like vandalism until you read the spec's
            // reason: it is a deliberate trap, so a handler that forgets to
            // reload xPP fails loudly instead of silently returning to the
            // wrong mode. It is now genuinely U rather than a no-op, because
            // there is finally somewhere lower to write.
            //
            // MPRV clears whenever the new mode is not M, which is always true
            // for SRET.
            // ----------------------------------------------------------------
            else if (trap_return) begin
                if (trap_ret_s) begin
                    priv         <= mstatus_spp ? `S_MODE : `U_MODE;
                    mstatus_sie  <= mstatus_spie;
                    mstatus_spie <= 1'b1;
                    mstatus_spp  <= 1'b0;          // U
                    mstatus_mprv <= 1'b0;
                end
                else begin
                    priv         <= mstatus_mpp;
                    mstatus_mie  <= mstatus_mpie;
                    mstatus_mpie <= 1'b1;
                    mstatus_mpp  <= `U_MODE;
                    if (mstatus_mpp != `M_MODE) mstatus_mprv <= 1'b0;
                end
            end
            else if (we) begin
                case (addr)
                    // Writable halves of the machine counters. Writing one half
                    // leaves the other alone.
                    `CSR_MCYCLE:    cycle_ctr[31:0]    <= wdata;
                    `CSR_MCYCLEH:   cycle_ctr[63:32]   <= wdata;
                    `CSR_MINSTRET:  instret_ctr[31:0]  <= wdata;
                    `CSR_MINSTRETH: instret_ctr[63:32] <= wdata;

                    `CSR_MSTATUS: begin
                        mstatus_sie  <= wdata[`MSTATUS_SIE_BIT];
                        mstatus_mie  <= wdata[`MSTATUS_MIE_BIT];
                        mstatus_spie <= wdata[`MSTATUS_SPIE_BIT];
                        mstatus_mpie <= wdata[`MSTATUS_MPIE_BIT];
                        mstatus_spp  <= wdata[`MSTATUS_SPP_BIT];
                        mstatus_mpp  <= legal_mpp(wdata[12:11]);
                        mstatus_mprv <= wdata[`MSTATUS_MPRV_BIT];
                        mstatus_sum  <= wdata[`MSTATUS_SUM_BIT];
                        mstatus_mxr  <= wdata[`MSTATUS_MXR_BIT];
                        mstatus_tvm  <= wdata[`MSTATUS_TVM_BIT];
                        mstatus_tw   <= wdata[`MSTATUS_TW_BIT];
                        mstatus_tsr  <= wdata[`MSTATUS_TSR_BIT];
                    end

                    // sstatus reaches only the supervisor fields of the same
                    // register. Writing it must not disturb MPP or MPIE, or a
                    // kernel would be able to rewrite the machine-mode context
                    // it was interrupted from.
                    `CSR_SSTATUS: begin
                        mstatus_sie  <= wdata[`MSTATUS_SIE_BIT];
                        mstatus_spie <= wdata[`MSTATUS_SPIE_BIT];
                        mstatus_spp  <= wdata[`MSTATUS_SPP_BIT];
                        // SUM and MXR are the supervisor's own, so sstatus
                        // writes them. MPRV, TVM, TW and TSR are not: they stay
                        // out of the mask and out of here.
                        mstatus_sum  <= wdata[`MSTATUS_SUM_BIT];
                        mstatus_mxr  <= wdata[`MSTATUS_MXR_BIT];
                    end

                    // Only the delegatable bits are writable; the rest read
                    // back zero, which is how software discovers the set.
                    `CSR_MEDELEG: medeleg <= wdata & `MEDELEG_MASK;
                    `CSR_MIDELEG: mideleg <= wdata & `MIDELEG_MASK;

                    // BASE is bits 31:2. MODE is forced to 0 (Direct), which
                    // WARL permits: only Direct is implemented, so reading back
                    // zero tells software the truth rather than accepting a
                    // vectored setting that would not be honoured.
                    `CSR_MTVEC: mtvec <= {wdata[`BUS_WIDTH-1:2], 2'b00};
                    `CSR_STVEC: stvec <= {wdata[`BUS_WIDTH-1:2], 2'b00};

                    `CSR_MSCRATCH: mscratch <= wdata;
                    `CSR_SSCRATCH: sscratch <= wdata;

                    // mepc and sepc hold only legal instruction addresses, so
                    // bits 1:0 read as zero on a core without compressed
                    // instructions.
                    `CSR_MEPC:   mepc   <= {wdata[`BUS_WIDTH-1:2], 2'b00};
                    `CSR_SEPC:   sepc   <= {wdata[`BUS_WIDTH-1:2], 2'b00};
                    `CSR_MCAUSE: mcause <= wdata;
                    `CSR_SCAUSE: scause <= wdata;
                    `CSR_MTVAL:  mtval  <= wdata;
                    `CSR_STVAL:  stval  <= wdata;

                    `CSR_MIE: begin
                        mie_ssie <= wdata[`IRQ_S_SOFT];
                        mie_msie <= wdata[`IRQ_M_SOFT];
                        mie_stie <= wdata[`IRQ_S_TIMER];
                        mie_mtie <= wdata[`IRQ_M_TIMER];
                        mie_seie <= wdata[`IRQ_S_EXT];
                        mie_meie <= wdata[`IRQ_M_EXT];
                    end

                    // Through sie, only delegated interrupts are writable -
                    // the others are read-only zero there, so a kernel cannot
                    // mask an interrupt that machine mode kept for itself.
                    `CSR_SIE: begin
                        if (mideleg[`IRQ_S_SOFT])  mie_ssie <= wdata[`IRQ_S_SOFT];
                        if (mideleg[`IRQ_S_TIMER]) mie_stie <= wdata[`IRQ_S_TIMER];
                        if (mideleg[`IRQ_S_EXT])   mie_seie <= wdata[`IRQ_S_EXT];
                    end

                    // Only the supervisor pending bits are software-writable.
                    // For SEIP the write lands on the software bit alone; the
                    // PLIC's contribution is OR-ed in at read time and cannot
                    // be cleared this way.
                    `CSR_MIP: begin
                        mip_ssip    <= wdata[`IRQ_S_SOFT];
                        mip_stip    <= wdata[`IRQ_S_TIMER];
                        mip_seip_sw <= wdata[`IRQ_S_EXT];
                    end

                    // Through sip, only SSIP. STIP and SEIP are written by
                    // machine mode on the kernel's behalf - that is the whole
                    // mechanism by which OpenSBI delivers sbi_set_timer.
                    `CSR_SIP: begin
                        if (mideleg[`IRQ_S_SOFT]) mip_ssip <= wdata[`IRQ_S_SOFT];
                    end

                    `CSR_MCOUNTEREN: mcounteren <= wdata[2:0];
                    `CSR_SCOUNTEREN: scounteren <= wdata[2:0];

                    // satp is real state now. Writing it changes what every
                    // address in S and U mode means, which is why the control
                    // unit turns this instruction into an implicit TLB flush -
                    // the entries cached under the old root are not merely
                    // stale, they belong to a different address space.
                    `CSR_SATP: satp <= wdata;

                    // Everything else is read-only or does not exist. The
                    // control unit has already raised an illegal instruction in
                    // that case, so reaching here means nothing should change.
                    default: ;
                endcase
            end
        end
    end

    /* verilator lint_off UNUSEDSIGNAL */
    // Reads never have side effects in this file, so `re` is not needed to
    // produce data. It is kept on the port because the control unit computes
    // it from Table 7 anyway and a future CSR with a read side effect will
    // need it.
    wire unused_re = re;
    // Stored so a kernel can read back what it wrote, but nothing consumes it:
    assign satp_o         = satp;
    assign mstatus_mpp_o  = mstatus_mpp;
    assign mstatus_mprv_o = mstatus_mprv;
    assign mstatus_sum_o  = mstatus_sum;
    assign mstatus_mxr_o  = mstatus_mxr;

    // MPRV redirects load/store privilege, and with no PMP and no translation
    // there is no protection for it to redirect.
    wire unused_mprv = mstatus_mprv;
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
