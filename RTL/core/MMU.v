`include "definitions.vh"
`include "CSRdefinitions.vh"
/* verilator lint_off DECLFILENAME */
// =============================================================================
// Sv32 Memory Management Unit.
//
// Vlad's draft (RTL/core/drafts/MMU_draft.v) set the structure and this keeps
// it: a two-level hardware page table walker, a small fully associative TLB, a
// permission checker with SUM and MXR, and software-managed A and D bits. What
// was left as comments is written out here - the TLB lookup, the TLB fill, the
// physical address, and the faults.
//
// Instantiated twice: once for instruction fetch and once for data. IS_FETCH
// picks which permission bit matters and which cause to report.
//
// --- Bare mode is a wire, not a state machine ------------------------------
//
// When satp.MODE is 0, or the effective privilege is M, this module is
// combinational: paddr is vaddr and ready is the request itself. That is not an
// optimisation, it is the difference between the machine still working and the
// machine getting slower for OpenSBI, the BIOS and every M-mode trap handler
// the moment an MMU is added. Translation costs nothing until it is switched on.
//
// --- Decisions worth knowing about ----------------------------------------
//
// * A and D are software managed. A leaf with A=0, or a store to a leaf with
//   D=0, raises a page fault and the kernel sets the bit. That is the draft's
//   choice and the specification allows it. The alternative is a hardware
//   read-modify-write on the PTE, which needs an atomic on the walker's port
//   and is a great deal more machinery for a behaviour Linux already handles.
//
// * Physical addresses are 32 bits. Sv32 PTEs carry a 22-bit PPN, so the
//   architectural physical address is 34 bits; this machine's bus is 32. A leaf
//   whose PPN sets either of the top two bits points outside anything that
//   exists here, so it is reported as a page fault rather than quietly aliased
//   onto real memory. Silently mapping a wrong page is the worse failure.
//
// * Replacement is round robin. The draft's comment suggested PLRU and this is
//   the agreed change: a 16-entry fully associative PLRU is a fifteen-bit tree
//   and four levels of logic sitting on the address path, which is exactly the
//   path the timing margin was bought for, and for a TLB this small the
//   difference in hit rate is not measurable. One counter, one increment.
//
// * MPRV is honoured for data accesses, because OpenSBI uses it - an M-mode
//   access with MPRV set translates as though it came from MPP. Never for
//   instruction fetch, which the specification is explicit about.
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

    // --- Walker port. Physical, and the same request/ready shape as the
    //     core's data port, so it can share the data cache. ----------------
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

    // --- PTE bits (Vlad's names kept) ---------------------------------------
    localparam PTE_V = 0;
    localparam PTE_R = 1;
    localparam PTE_W = 2;
    localparam PTE_X = 3;
    localparam PTE_U = 4;
    localparam PTE_A = 6;
    localparam PTE_D = 7;

    // Is translation happening at all?
    //
    // MPRV makes an M-mode data access behave as though it came from MPP. It
    // must not affect instruction fetch: the specification says fetches always
    // use the real current privilege, and honouring MPRV there would translate
    // the firmware's own code out from under it.
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

    // Round robin victim: the next entry to be overwritten, advanced once per
    // fill. Nothing about a hit disturbs it, which is the whole appeal - a hit
    // costs a compare and nothing else.
    reg [$clog2(TLB_ENTRIES)-1:0] victim;

    integer i;

    reg                            hit;
    reg [7:0]                      check_flags;   // the draft's name
    reg [19:0]                     hit_ppn;
    reg                            hit_mega;

    always @(*) begin
        hit         = 1'b0;
        check_flags = 8'h00;
        hit_ppn     = 20'd0;
        hit_mega    = 1'b0;

        for (i = 0; i < TLB_ENTRIES; i = i + 1) begin
            // A megapage entry covers 4 MiB, so only VPN1 is compared. ASID
            // must match too: entries from another address space are not ours,
            // which is what lets a context switch avoid flushing.
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
    // Permission checker. Vlad's logic, with the declarations moved out of the
    // always block - Verilog-2001 wants them before the statements, and this
    // project builds with -Wall on two toolchains that disagree about the rest.
    // =========================================================================
    reg access_allowed;
    reg priv_ok, perm_ok, ad_ok;

    always @(*) begin
        priv_ok = 1'b0;
        perm_ok = 1'b0;
        ad_ok   = 1'b0;

        if (check_flags[PTE_V]) begin
            // Privilege. U-mode needs U=1; S-mode may touch a user page only
            // with SUM set, and never for instruction fetch - SUM applies to
            // loads and stores alone, which is the whole point of it.
            if (eff_priv == `U_MODE)
                priv_ok = check_flags[PTE_U];
            else if (eff_priv == `S_MODE)
                priv_ok = (!check_flags[PTE_U]) ||
                          (mstatus_sum && (IS_FETCH == 0));
            else
                priv_ok = 1'b1;      // unreachable: M-mode does not get here

            // R/W/X. MXR lets a load read an execute-only page; it says nothing
            // about fetching, and nothing about stores.
            if (IS_FETCH)
                perm_ok = check_flags[PTE_X];
            else if (req_write)
                perm_ok = check_flags[PTE_W];
            else
                perm_ok = check_flags[PTE_R] ||
                          (mstatus_mxr && check_flags[PTE_X]);

            // A and D are the software's to set. A store needs both.
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
    // A held request must not be counted once per cycle it is held.
    reg        hit_d;
    reg        walk_fault;      // the walk ended in a fault
    reg [19:0] fault_vpn;       // ...for this virtual page, and only this one

    // The page this walk is for, latched when it starts.
    //
    // A walk takes many cycles and the address on the input can change during
    // them - the instruction side never drops its request, it just moves the PC.
    // Using the live vpn to index the page table and to tag the filled entry
    // then mixes two addresses together: the entry goes in under the new page
    // number carrying the old page's translation, which is silent corruption
    // rather than a fault. So the walk owns its address from the moment it
    // starts, and abandons itself if the request moves on.
    reg [19:0] walk_vpn;
    reg [19:0] fill_ppn;
    reg [7:0]  fill_flags;
    reg        fill_mega;

    // A PTE is a pointer when it is valid and has none of R, W or X. R=0 with
    // W=1 is a reserved encoding at any level and is a fault, whether or not X
    // is set - the draft's test also required X=0, which let the R=0 W=1 X=1
    // encoding through as a leaf.
    wire pte_v       = ptw_rdata[PTE_V];
    wire pte_bad_rw  = !ptw_rdata[PTE_R] && ptw_rdata[PTE_W];
    wire pte_is_leaf = ptw_rdata[PTE_R] || ptw_rdata[PTE_X];
    // Above 4 GiB: nothing here can answer, so it is not a mapping.
    wire pte_too_big = |ptw_rdata[31:30];

    // A megapage's PPN must be aligned to its own size. An unaligned superpage
    // is a page fault, not something to round off.
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
            // Counted here, in the one block that drives these registers.
            //
            // This started as a separate always block, which Verilator accepted
            // and Gowin rejected outright: "Net 'stat_hits[31]' is constantly
            // driven from multiple places". Two clocked blocks assigning the
            // same register is not a style question, it is two drivers.
            hit_d <= xlate_on && req_valid && hit;
            if (xlate_on && req_valid && hit && !hit_d)
                stat_hits <= stat_hits + 32'd1;

            // SFENCE.VMA outranks everything, including a walk in progress: the
            // page tables it refers to have already changed, so a walk based on
            // them is reading stale memory and its result must not be kept.
            if (sfence_req) begin
                for (i = 0; i < TLB_ENTRIES; i = i + 1)
                    tlb_valid[i] <= 1'b0;
                ptw_state  <= STATE_IDLE;
                ptw_re     <= 1'b0;
                walk_fault <= 1'b0;
            end else begin
                // A fault belongs to one virtual page, and is held only while
                // that page is the one being asked for, translation is on, and
                // a request is outstanding.
                //
                // All three conditions are load bearing, and the vpn one is the
                // subtlest. The instruction side holds req_valid high forever -
                // there is always a fetch in progress - so without it, the
                // first walk fault in supervisor mode is the last walk this MMU
                // ever does: walk_fault blocks the state machine from starting
                // another, so every later address reports the *first* address's
                // fault.
                //
                // Linux walks straight into it. Its trampoline maps only the
                // kernel's virtual range, so the fetch right after `csrw satp`
                // faults on the physical PC by design, and the trap vector it
                // set for exactly that purpose points at the virtual address.
                // With the fault stuck, that vector's own fetch reported the
                // same fault, and the kernel spun on stvec forever with nothing
                // retiring - having done everything right.
                if (!req_valid || !xlate_on || (vpn != fault_vpn))
                    walk_fault <= 1'b0;

                case (ptw_state)
                STATE_IDLE: begin
                    // Not gated on walk_fault, and that is the whole point.
                    //
                    // Using the latched fault as a gate makes it permanent: the
                    // walk cannot start, so the TLB never fills, so there is no
                    // hit to outrank the fault, so it is reported again. A page
                    // that faults once can then never be translated again.
                    //
                    // Linux dies on this. Its linear map is built with 4 KB
                    // pages, and any page that faulted even once - during the
                    // switch off the trampoline, before the final tables are
                    // live - is lost for good. It fell over in slab init on a
                    // load from a page whose PTE was present, readable and
                    // marked accessed.
                    //
                    // So a fault is a *result* here, never a gate. The cost is
                    // re-walking while a fault goes unconsumed, which is
                    // bounded and self-healing: the consumer latches the fault
                    // the first cycle it can act, and until then the worst that
                    // happens is the page table being read again.
                    if (xlate_on && req_valid && !hit) begin
                        // satp.PPN * 4096 + VPN1 * 4, in 32 bits. OR rather
                        // than ADD: the PPN occupies bits 31:12 and the index
                        // bits 11:2, so they cannot overlap and there is no
                        // carry to propagate. One less adder on the walk.
                        ptw_addr    <= {satp_ppn[19:0], 12'd0} |
                                       {20'd0, vpn1, 2'b00};
                        walk_vpn    <= vpn;
                        ptw_re      <= 1'b1;
                        ptw_state   <= STATE_FETCH_L1;
                        stat_misses <= stat_misses + 32'd1;
                        // Whatever was remembered about this page is now being
                        // re-established from the page table itself.
                        walk_fault  <= 1'b0;
                    end
                end

                STATE_FETCH_L1: begin
                    // The request moved to another page; this walk is answering a
                    // question nobody is asking any more.
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
                                // Store only the part of the PPN the megapage
                                // actually fixes. The low ten bits come from
                                // the virtual address, and they have to be
                                // taken at *use* time: one entry covers 1 024
                                // pages, so baking in the VPN0 of whichever
                                // access happened to miss first makes every
                                // other page in the megapage resolve to that
                                // one. Which is what it did.
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
                    // The request moved to another page; this walk is answering a
                    // question nobody is asking any more.
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
                    // A walk just succeeded for this page, so any fault
                    // remembered for it is stale. Without this the page can
                    // never be translated again: the entry goes into the TLB,
                    // hits, permits the access - and the latched fault is still
                    // reported over the top of it.
                    walk_fault <= 1'b0;
                    // One cycle to install the entry, then back to the lookup,
                    // which now hits. Same shape as the cache's fill: one
                    // comparison path instead of two.
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
    // A permission failure on a resident entry is a fault with no walk: the
    // translation is known, it is simply not allowed.
    wire perm_fault = xlate_on && req_valid && hit && !access_allowed;

    // Gated here as well as at the register because the register clears on the
    // *next* edge: the cycle the trap is taken is the cycle privilege changes,
    // and the cycle a new address arrives is the cycle it must be walked, so
    // both have to be right in the cycle itself.
    // A resident entry outranks a remembered fault, and that ordering is the
    // whole difference between Linux booting and Linux looping.
    //
    // A page fault is not final: the kernel handles it, populates the mapping,
    // and returns to *retry the same instruction*. Reporting the old fault on
    // that retry means the handler runs, fixes nothing it can observe, returns,
    // and faults again - forever. It showed up as the kernel spinning in its
    // printk ring buffer with scause 15 on an ordinary `sw ra, 28(sp)` to a
    // stack page whose TLB entry was present and writable.
    // ~hit used to be here as well. It is redundant: fault_vpn already scopes
    // the fault to one page, and a walk that fills that page's entry clears the
    // fault on its way. Dropping it takes the TLB compare's result off this
    // path, which is worth having - the whole term sits on the end of
    // alu_result_d, the longest path in the machine.
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
    // satp.PPN above 4 GiB cannot be reached on this bus, and the PTE's upper
    // bits are consumed by the checks above rather than the address.
    wire _unused = |{satp_ppn[21:20], ptw_rdata[`BUS_WIDTH-1:8]};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
