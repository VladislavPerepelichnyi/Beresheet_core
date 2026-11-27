`include "definitions.vh"
`include "CSRdefinitions.vh"

// =============================================================================
// Control and Status Register file, M / S / U.
//
// Holds every implemented CSR, the 64-bit counters and the current privilege
// mode. Provides the read multiplexer and `exists`, the write port, and the
// architectural state change on trap entry and xRET.
//
// Legality checks (read-only, privilege, counter enables) and trap routing are
// decided by the control unit; this file only exports the state they need
// (medeleg/mideleg, the mstatus control bits, the counter enables).
//
// sstatus, sie and sip own no storage: they are restricted views of mstatus,
// mie and mip, as the spec defines them.
// =============================================================================
module CSR_unit (
    input  wire clk,
    input  wire rst,

    // --- Access port, driven from Decode/Execute ---
    input  wire [11:0]           addr,
    input  wire                  re,        // this access reads
    input  wire                  we,        // this access writes
    input  wire [`BUS_WIDTH-1:0] wdata,     // value to store, already modified
    output reg  [`BUS_WIDTH-1:0] rdata,
    output reg                   exists,    // addressed CSR is implemented
    // mip.SEIP reads as software bit | PLIC line, but CSRRS/CSRRC must modify
    // the software bit alone. High when the access is to mip and the software
    // bit is clear, so Decode/Execute removes bit 9 from the value it modifies.
    output wire                  rmw_seip_hw_only,

    // --- Trap entry and return. Trap entry takes priority over a CSR write
    //     in the same cycle (which the control unit never produces).
    input  wire                  trap_take,
    input  wire                  trap_to_s,    // delegated to supervisor mode
    input  wire [`BUS_WIDTH-1:0] trap_epc,     // PC of the trapping instruction
    input  wire [`BUS_WIDTH-1:0] trap_cause,   // full cause, interrupt bit included
    input  wire [`BUS_WIDTH-1:0] trap_tval,
    input  wire                  trap_return,  // MRET or SRET
    input  wire                  trap_ret_s,   // ...it was SRET

    // --- Counter inputs ---
    input  wire                  instret,   // one instruction retired

    // --- Real time from the CLINT; the `time` CSR is a read-only view of it.
    input  wire [63:0]           mtime,

    // --- Interrupt lines. MSIP, MTIP and MEIP are read-only in mip and are
    //     cleared at their device (CLINT msip / mtimecmp, PLIC claim).
    //     irq_ext_s, the PLIC's supervisor context, is OR-ed into mip.SEIP
    //     with a software-writable bit.
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
    // Privilege mode. Resets to M with interrupts disabled.
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
    reg        mstatus_spp;                 // 0 U, 1 S (S is never entered from M)
    reg        mstatus_mprv;                // data accesses use MPP's privilege
    reg        mstatus_sum, mstatus_mxr;    // MMU permission modifiers
    reg [`BUS_WIDTH-1:0] satp;
    reg        mstatus_tvm, mstatus_tw, mstatus_tsr;

    reg [`BUS_WIDTH-1:0] mtvec, mscratch, mepc, mcause, mtval;
    reg [`BUS_WIDTH-1:0] stvec, sscratch, sepc, scause, stval;

    reg [`BUS_WIDTH-1:0] medeleg, mideleg;

    // Interrupt enables, one bit per implemented source.
    reg        mie_msie, mie_mtie, mie_meie;
    reg        mie_ssie, mie_stie, mie_seie;

    // Software-writable supervisor pending bits. M-mode software raises them on
    // the kernel's behalf (e.g. OpenSBI's timer on a hart without Sstc).
    reg        mip_ssip, mip_stip, mip_seip_sw;

    reg [2:0]  mcounteren, scounteren;      // CY, TM, IR

    // ------------------------------------------------------------------------
    // Counters, 64 bits even on RV32 (Zicntr), read as two halves.
    // ------------------------------------------------------------------------
    reg [63:0] cycle_ctr;
    reg [63:0] instret_ctr;

    // ------------------------------------------------------------------------
    // Assembled read values
    // ------------------------------------------------------------------------
    // Written as concatenations so the bit positions read straight off the
    // source. FS, VS, XS and SD are zero (no floating-point or vector state);
    // UBE is zero (little-endian only).
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

    // mip.SEIP reads as the OR of the software bit and the PLIC's supervisor
    // context. Writes land on the software bit alone.
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

    // An interrupt is visible in sip / sie only if it is delegated; the rest
    // read as zero.
    wire [`BUS_WIDTH-1:0] sip_val = mip_val & mideleg;
    wire [`BUS_WIDTH-1:0] sie_val = mie_val & mideleg;

    // Without this, a csrs/csrc on mip (OpenSBI does one per timer tick) would
    // copy a pending PLIC SEIP into the software bit, leaving SEIP stuck after
    // the device is serviced.
    assign rmw_seip_hw_only = (addr == `CSR_MIP) && !mip_seip_sw;

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
    // One case statement gives both, so they cannot drift apart. `re` does not
    // gate the value: no CSR here has a read side effect.
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
            // Trap entry into the mode that owns the trap. Only that mode's
            // registers and mstatus fields are written; an S-mode trap must not
            // disturb a live M-mode context.
            // ----------------------------------------------------------------
            if (trap_take) begin
                if (trap_to_s) begin
                    sepc         <= {trap_epc[`BUS_WIDTH-1:2], 2'b00};
                    scause       <= trap_cause;
                    stval        <= trap_tval;
                    // SPP is one bit: a delegated trap comes from S or U.
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
            // xRET pops the matching stack: privilege <- xPP, xIE <- xPIE,
            // xPIE <- 1, xPP <- U (the least privileged mode). MPRV clears
            // whenever the new mode is not M, which is always true for SRET.
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

                    // BASE is bits 31:2. MODE is forced to 0: only Direct
                    // mode is implemented (WARL).
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
                    // machine mode on the kernel's behalf.
                    `CSR_SIP: begin
                        if (mideleg[`IRQ_S_SOFT]) mip_ssip <= wdata[`IRQ_S_SOFT];
                    end

                    `CSR_MCOUNTEREN: mcounteren <= wdata[2:0];
                    `CSR_SCOUNTEREN: scounteren <= wdata[2:0];

                    // Sv32 defines both MODE values, so satp is fully
                    // writable. The control unit flushes the TLBs on a write.
                    `CSR_SATP: satp <= wdata;

                    // Read-only or non-existent: the control unit has already
                    // raised an illegal instruction.
                    default: ;
                endcase
            end
        end
    end

    // To the MMUs
    assign satp_o         = satp;
    assign mstatus_mpp_o  = mstatus_mpp;
    assign mstatus_mprv_o = mstatus_mprv;
    assign mstatus_sum_o  = mstatus_sum;
    assign mstatus_mxr_o  = mstatus_mxr;

    /* verilator lint_off UNUSEDSIGNAL */
    // No CSR here has a read side effect, so `re` is unused. It stays on the
    // port as the spec-defined "this access reads" qualifier.
    wire unused_re = re;
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
