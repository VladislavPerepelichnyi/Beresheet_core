`include "definitions.vh"
`include "CSRdefinitions.vh"
/* verilator lint_off DECLFILENAME */
// =============================================================================
// Sv32 Memory Management Unit.
//
// The structure: a two-level hardware page-table walker, a small fully
// associative TLB with ASID tags, and a permission checker with SUM and MXR.
// Instantiated twice, for instruction fetch and for data; IS_FETCH selects
// which permission bit is checked and which page-fault cause is reported.
//
// When satp.MODE is 0, or the effective privilege is M, the module is purely
// combinational (paddr = vaddr, ready = request), so M-mode code pays nothing.
//
// Design choices:
// * A and D are managed by software: a leaf with A=0, or a store to a leaf
//   with D=0, raises a page fault and the kernel sets the bit (permitted by
//   the spec, and handled by Linux).
// * Physical addresses are 32 bits. A leaf whose 22-bit PPN sets either of the
//   top two bits is reported as a page fault rather than aliased onto memory.
// * Round-robin replacement: one counter, nothing on the hit path.
// * MPRV applies to data accesses only, never to instruction fetch.
// =============================================================================
module mmu #(
    parameter TLB_ENTRIES = 16,
    parameter IS_FETCH    = 0     // 1: check X, report cause 12
)(
    input  wire clk,
    input  wire rst,

    // --- CPU side ---------------------------------------------------------
    input  wire [`BUS_WIDTH-1:0] vaddr,
    input  wire                  req_valid,
    input  wire                  req_write,     // ignored when IS_FETCH
    input  wire [1:0]            priv_mode,
    input  wire [1:0]            mstatus_mpp,
    input  wire                  mstatus_mprv,
    input  wire                  mstatus_sum,
    input  wire                  mstatus_mxr,
    input  wire [`BUS_WIDTH-1:0] satp_value,
    input  wire                  sfence_req,    // invalidate the whole TLB

    // --- CPU side answer --------------------------------------------------
    // ready means "this cycle the answer is here": either paddr is usable or
    // page_fault is set. The consumer stalls until it sees this.
    output wire [`BUS_WIDTH-1:0] paddr,
    output wire                  ready,
    output wire                  page_fault,
    output wire [3:0]            pf_cause,

    // --- Walker port: physical, same request/ready shape as the core's
    //     data port, so walks go through the data cache. -------------------
    output reg  [`BUS_WIDTH-1:0] ptw_addr,
    output reg                   ptw_re,
    input  wire [`BUS_WIDTH-1:0] ptw_rdata,
    input  wire                  ptw_ready,

    // --- Observation ------------------------------------------------------
    output reg  [31:0] stat_hits,
    output reg  [31:0] stat_misses,
    output reg  [31:0] stat_faults
);

    // --- satp ---------------------------------------------------------------
    wire        satp_mode = satp_value[31];
    wire [8:0]  satp_asid = satp_value[30:22];
    wire [21:0] satp_ppn  = satp_value[21:0];

    // --- Sv32 virtual address -----------------------------------------------
    wire [9:0]  vpn1     = vaddr[31:22];
    wire [9:0]  vpn0     = vaddr[21:12];
    wire [11:0] page_off = vaddr[11:0];
    wire [19:0] vpn      = vaddr[31:12];

    // --- PTE bits -----------------------------------------------------------
    localparam PTE_V = 0;
    localparam PTE_R = 1;
    localparam PTE_W = 2;
    localparam PTE_X = 3;
    localparam PTE_U = 4;
    localparam PTE_A = 6;
    localparam PTE_D = 7;

    // Is translation on? MPRV makes an M-mode data access translate as though
    // it came from MPP; instruction fetch always uses the current privilege.
    wire [1:0] eff_priv = (IS_FETCH == 0) && (priv_mode == `M_MODE) && mstatus_mprv
                          ? mstatus_mpp : priv_mode;
    wire       xlate_on = satp_mode && (eff_priv != `M_MODE);

    // =========================================================================
    // TLB. Fully associative, TLB_ENTRIES deep.
    // =========================================================================
    reg [19:0] tlb_vpn   [0:TLB_ENTRIES-1];
    reg [19:0] tlb_ppn   [0:TLB_ENTRIES-1];   // 20 bits: see the header note
    reg [8:0]  tlb_asid  [0:TLB_ENTRIES-1];
    reg [7:0]  tlb_flags [0:TLB_ENTRIES-1];
    reg        tlb_mega  [0:TLB_ENTRIES-1];   // 4 MiB leaf, matched on VPN1 only
    reg        tlb_valid [0:TLB_ENTRIES-1];

    // Round-robin victim: the next entry to overwrite, advanced once per fill.
    reg [$clog2(TLB_ENTRIES)-1:0] victim;

    integer i;

    reg                            hit;
    reg [7:0]                      check_flags;   // flags of the hit entry
    reg [19:0]                     hit_ppn;
    reg                            hit_mega;

    always @(*) begin
        hit         = 1'b0;
        check_flags = 8'h00;
        hit_ppn     = 20'd0;
        hit_mega    = 1'b0;

        for (i = 0; i < TLB_ENTRIES; i = i + 1) begin
            // A megapage entry covers 4 MiB, so only VPN1 is compared. The
            // ASID must match, so a context switch need not flush.
            if (tlb_valid[i] && (tlb_asid[i] == satp_asid) &&
                (tlb_mega[i] ? (tlb_vpn[i][19:10] == vpn1)
                             : (tlb_vpn[i]        == vpn))) begin
                hit         = 1'b1;
                check_flags = tlb_flags[i];
                hit_ppn     = tlb_ppn[i];
                hit_mega    = tlb_mega[i];
            end
        end
    end

    // =========================================================================
    // Permission checker, on the flags of the hit entry
    // =========================================================================
    reg access_allowed;
    reg priv_ok, perm_ok, ad_ok;

    always @(*) begin
        priv_ok = 1'b0;
        perm_ok = 1'b0;
        ad_ok   = 1'b0;

        if (check_flags[PTE_V]) begin
            // Privilege. U-mode needs U=1; S-mode may access a user page only
            // with SUM set, and never fetch from one.
            if (eff_priv == `U_MODE)
                priv_ok = check_flags[PTE_U];
            else if (eff_priv == `S_MODE)
                priv_ok = (!check_flags[PTE_U]) ||
                          (mstatus_sum && (IS_FETCH == 0));
            else
                priv_ok = 1'b1;      // unreachable: M-mode does not get here

            // R/W/X. MXR lets a load read an execute-only page.
            if (IS_FETCH)
                perm_ok = check_flags[PTE_X];
            else if (req_write)
                perm_ok = check_flags[PTE_W];
            else
                perm_ok = check_flags[PTE_R] ||
                          (mstatus_mxr && check_flags[PTE_X]);

            // Software-managed A and D: every access needs A, a store also D.
            if (!IS_FETCH && req_write) ad_ok = check_flags[PTE_A] && check_flags[PTE_D];
            else                        ad_ok = check_flags[PTE_A];
        end

        access_allowed = check_flags[PTE_V] && priv_ok && perm_ok && ad_ok;
    end

    // =========================================================================
    // Walker
    // =========================================================================
    localparam STATE_IDLE     = 2'd0;
    localparam STATE_FETCH_L1 = 2'd1;
    localparam STATE_FETCH_L0 = 2'd2;
    localparam STATE_FILL     = 2'd3;

    reg [1:0]  ptw_state;
    reg        hit_d;           // a held request is counted as one hit
    reg        walk_fault;      // the walk ended in a fault
    reg [19:0] fault_vpn;       // ...for this virtual page only

    // The page this walk is for, latched when it starts. The requested address
    // can change during a walk (the fetch side just moves the PC), so the walk
    // must index and tag with its own copy, and abandons itself if the request
    // moves to another page.
    reg [19:0] walk_vpn;
    reg [19:0] fill_ppn;
    reg [7:0]  fill_flags;
    reg        fill_mega;

    // A valid PTE with R=X=0 is a pointer, otherwise a leaf. R=0 with W=1 is a
    // reserved encoding at any level and faults, whatever X is.
    wire pte_v       = ptw_rdata[PTE_V];
    wire pte_bad_rw  = !ptw_rdata[PTE_R] && ptw_rdata[PTE_W];
    wire pte_is_leaf = ptw_rdata[PTE_R] || ptw_rdata[PTE_X];
    // PPN above the 32-bit physical address space
    wire pte_too_big = |ptw_rdata[31:30];

    // A megapage's PPN must be aligned to 4 MiB, otherwise it is a page fault.
    wire pte_mega_misaligned = |ptw_rdata[19:10];

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            ptw_state  <= STATE_IDLE;
            ptw_re     <= 1'b0;
            ptw_addr   <= {`BUS_WIDTH{1'b0}};
            walk_fault <= 1'b0;
            fault_vpn  <= 20'd0;
            walk_vpn   <= 20'd0;
            hit_d      <= 1'b0;
            victim     <= {$clog2(TLB_ENTRIES){1'b0}};
            fill_ppn   <= 20'd0;
            fill_flags <= 8'h00;
            fill_mega  <= 1'b0;
            stat_hits   <= 32'd0;
            stat_misses <= 32'd0;
            stat_faults <= 32'd0;
            for (i = 0; i < TLB_ENTRIES; i = i + 1) begin
                tlb_valid[i] <= 1'b0;
                tlb_mega[i]  <= 1'b0;
            end
        end else begin
            // Hit statistics, counted once per held request
            hit_d <= xlate_on && req_valid && hit;
            if (xlate_on && req_valid && hit && !hit_d)
                stat_hits <= stat_hits + 32'd1;

            // SFENCE.VMA flushes the TLB and abandons any walk in progress,
            // whose result may come from the old page tables.
            if (sfence_req) begin
                for (i = 0; i < TLB_ENTRIES; i = i + 1)
                    tlb_valid[i] <= 1'b0;
                ptw_state  <= STATE_IDLE;
                ptw_re     <= 1'b0;
                walk_fault <= 1'b0;
            end else begin
                // A walk fault belongs to one virtual page. It is held only while
                // that page is still requested with translation on; the fetch
                // side never drops req_valid, so the vpn check is what lets a
                // fault on one page not leak onto the next.
                if (!req_valid || !xlate_on || (vpn != fault_vpn))
                    walk_fault <= 1'b0;

                case (ptw_state)
                STATE_IDLE: begin
                    // Deliberately not gated on walk_fault: a page that faulted
                    // once must be walked again after the kernel fixes its PTE.
                    // While a fault is pending but not yet consumed, the cost
                    // is only a repeated walk.
                    if (xlate_on && req_valid && !hit) begin
                        // satp.PPN * 4096 + VPN1 * 4. The fields do not
                        // overlap, so OR replaces the adder.
                        ptw_addr    <= {satp_ppn[19:0], 12'd0} |
                                       {20'd0, vpn1, 2'b00};
                        walk_vpn    <= vpn;
                        ptw_re      <= 1'b1;
                        ptw_state   <= STATE_FETCH_L1;
                        stat_misses <= stat_misses + 32'd1;
                        walk_fault  <= 1'b0;
                    end
                end

                STATE_FETCH_L1: begin
                    // Abandon the walk if the request moved to another page
                    if (req_valid && (vpn != walk_vpn)) begin
                        ptw_re    <= 1'b0;
                        ptw_state <= STATE_IDLE;
                    end else if (ptw_ready) begin
                        ptw_re <= 1'b0;
                        if (!pte_v || pte_bad_rw) begin
                            walk_fault  <= 1'b1;
                            fault_vpn   <= vpn;
                            stat_faults <= stat_faults + 32'd1;
                            ptw_state   <= STATE_IDLE;
                        end else if (pte_is_leaf) begin
                            // Leaf at level 1: a 4 MiB megapage.
                            if (pte_mega_misaligned || pte_too_big) begin
                                walk_fault  <= 1'b1;
                                fault_vpn   <= vpn;
                                stat_faults <= stat_faults + 32'd1;
                                ptw_state   <= STATE_IDLE;
                            end else begin
                                // Store only PPN[1]. The low ten bits come
                                // from VPN0 of each access at lookup time,
                                // since one entry covers 1024 pages.
                                fill_ppn   <= {ptw_rdata[29:20], 10'd0};
                                fill_flags <= ptw_rdata[7:0];
                                fill_mega  <= 1'b1;
                                ptw_state  <= STATE_FILL;
                            end
                        end else begin
                            // Pointer: PTE.PPN * 4096 + VPN0 * 4.
                            ptw_addr  <= {ptw_rdata[29:10], 12'd0} |
                                         {20'd0, walk_vpn[9:0], 2'b00};
                            ptw_re    <= 1'b1;
                            ptw_state <= STATE_FETCH_L0;
                        end
                    end
                end

                STATE_FETCH_L0: begin
                    // Abandon the walk if the request moved to another page
                    if (req_valid && (vpn != walk_vpn)) begin
                        ptw_re    <= 1'b0;
                        ptw_state <= STATE_IDLE;
                    end else if (ptw_ready) begin
                        ptw_re <= 1'b0;
                        // A pointer at the last level has nowhere left to go.
                        if (!pte_v || pte_bad_rw || !pte_is_leaf || pte_too_big) begin
                            walk_fault  <= 1'b1;
                            fault_vpn   <= vpn;
                            stat_faults <= stat_faults + 32'd1;
                            ptw_state   <= STATE_IDLE;
                        end else begin
                            fill_ppn   <= ptw_rdata[29:10];
                            fill_flags <= ptw_rdata[7:0];
                            fill_mega  <= 1'b0;
                            ptw_state  <= STATE_FILL;
                        end
                    end
                end

                STATE_FILL: begin
                    // A successful walk clears any fault remembered for the
                    // page. The entry is installed, and the lookup then hits.
                    walk_fault <= 1'b0;
                    tlb_vpn  [victim] <= walk_vpn;
                    tlb_ppn  [victim] <= fill_ppn;
                    tlb_asid [victim] <= satp_asid;
                    tlb_flags[victim] <= fill_flags;
                    tlb_mega [victim] <= fill_mega;
                    tlb_valid[victim] <= 1'b1;
                    victim            <= victim + 1'b1;
                    ptw_state         <= STATE_IDLE;
                end

                default: ptw_state <= STATE_IDLE;
                endcase
            end
        end
    end

    // =========================================================================
    // The answer
    // =========================================================================
    // A permission failure on a resident entry faults without a walk.
    wire perm_fault = xlate_on && req_valid && hit && !access_allowed;

    // A remembered walk fault is re-qualified combinationally, because the
    // register only clears on the next edge: privilege and address may change
    // in the very cycle the answer is used. It is not gated by ~hit, which
    // keeps the TLB compare off this timing-critical path; a successful walk
    // for the page clears the fault anyway.
    assign page_fault = perm_fault |
                        (walk_fault & req_valid & xlate_on & (vpn == fault_vpn));
    assign ready      = req_valid & (!xlate_on | hit | page_fault);

    assign pf_cause   = IS_FETCH  ? `CAUSE_FETCH_PAGE_FAULT
                      : req_write ? `CAUSE_STORE_PAGE_FAULT
                                  : `CAUSE_LOAD_PAGE_FAULT;

    // A megapage supplies the top ten PPN bits; the rest of the physical page
    // number is VPN0, straight from the virtual address.
    assign paddr = xlate_on ? {hit_mega ? {hit_ppn[19:10], vpn0} : hit_ppn,
                               page_off}
                            : vaddr;

    /* verilator lint_off UNUSEDSIGNAL */
    // satp.PPN bits 21:20 address beyond this 32-bit bus; the PTE's upper bits
    // are consumed by the checks above, not by the address.
    wire _unused = |{satp_ppn[21:20], ptw_rdata[`BUS_WIDTH-1:8]};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
