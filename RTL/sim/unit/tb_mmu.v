// =============================================================================
// Unit testbench for the Sv32 MMU (data and fetch instances, shared tables).
//
// Page tables are built by hand in a local memory and each translation is
// checked directly against the privileged specification: bare and M-mode
// pass-through, two-level walks and megapages, R/W/X/U/A/D permissions, SUM,
// MXR and MPRV, reserved and misaligned PTEs, SFENCE.VMA and ASIDs, fault
// release when the address or mode changes under a held request, and walks
// against a memory with latency.
// =============================================================================
`timescale 1ns/1ps
`include "definitions.vh"
`include "CSRdefinitions.vh"

module tb_mmu;

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #5 clk = ~clk;

    integer errors = 0;
    integer checks = 0;

    // --- PTE flag bits ---
    localparam F_V = 8'h01, F_R = 8'h02, F_W = 8'h04, F_X = 8'h08,
               F_U = 8'h10, F_A = 8'h40, F_D = 8'h80;

    // --- physical memory holding the page tables ---
    // Root table at PA 0x1000 (PPN 1), leaf table at PA 0x2000 (PPN 2).
    reg [31:0] mem [0:4095];          // 16 KB, PA 0x0000 - 0x3FFC

    localparam SATP_ON  = 32'h8000_0001;   // MODE=Sv32, ASID=0, PPN=1

    // --- data-side MMU ---
    reg  [31:0] d_vaddr = 32'd0;
    reg         d_req = 1'b0, d_write = 1'b0;
    reg  [1:0]  d_priv = `M_MODE;
    reg  [1:0]  d_mpp  = `M_MODE;
    reg         d_mprv = 1'b0, d_sum = 1'b0, d_mxr = 1'b0;
    reg  [31:0] d_satp = 32'd0;
    reg         d_sfence = 1'b0;
    wire [31:0] d_paddr;
    wire        d_ready, d_fault;
    wire [3:0]  d_cause;
    wire [31:0] d_ptw_addr;
    wire        d_ptw_re;
    wire [31:0] d_stat_hits, d_stat_misses, d_stat_faults;

    // --- fetch-side MMU, same tables ---
    reg  [31:0] i_vaddr = 32'd0;
    reg         i_req = 1'b0;
    wire [31:0] i_paddr;
    wire        i_ready, i_fault;
    wire [3:0]  i_cause;
    wire [31:0] i_ptw_addr;
    wire        i_ptw_re;
    wire [31:0] i_stat_hits, i_stat_misses, i_stat_faults;

    // Page-table memory ports, with configurable latency (mem_lat)
    integer     mem_lat = 0;
    integer     d_lat = 0, i_lat = 0;
    reg         d_ptw_ready = 1'b0, i_ptw_ready = 1'b0;
    wire [31:0] d_ptw_rdata = mem[d_ptw_addr[13:2]];
    wire [31:0] i_ptw_rdata = mem[i_ptw_addr[13:2]];

    always @(posedge clk) begin
        if (rst) begin
            d_ptw_ready <= 1'b0; d_lat <= 0;
            i_ptw_ready <= 1'b0; i_lat <= 0;
        end else begin
            if (d_ptw_re && d_lat >= mem_lat) begin
                d_ptw_ready <= 1'b1; d_lat <= 0;
            end else if (d_ptw_re) begin
                d_ptw_ready <= 1'b0; d_lat <= d_lat + 1;
            end else begin
                d_ptw_ready <= 1'b0; d_lat <= 0;
            end

            if (i_ptw_re && i_lat >= mem_lat) begin
                i_ptw_ready <= 1'b1; i_lat <= 0;
            end else if (i_ptw_re) begin
                i_ptw_ready <= 1'b0; i_lat <= i_lat + 1;
            end else begin
                i_ptw_ready <= 1'b0; i_lat <= 0;
            end
        end
    end

    mmu #(.TLB_ENTRIES (16), .IS_FETCH (0)) dmmu (
        .clk (clk), .rst (rst),
        .vaddr (d_vaddr), .req_valid (d_req), .req_write (d_write),
        .priv_mode (d_priv), .mstatus_mpp (d_mpp), .mstatus_mprv (d_mprv),
        .mstatus_sum (d_sum), .mstatus_mxr (d_mxr),
        .satp_value (d_satp), .sfence_req (d_sfence),
        .paddr (d_paddr), .ready (d_ready),
        .page_fault (d_fault), .pf_cause (d_cause),
        .ptw_addr (d_ptw_addr), .ptw_re (d_ptw_re),
        .ptw_rdata (d_ptw_rdata), .ptw_ready (d_ptw_ready),
        .stat_hits (d_stat_hits), .stat_misses (d_stat_misses),
        .stat_faults (d_stat_faults)
    );

    mmu #(.TLB_ENTRIES (16), .IS_FETCH (1)) immu (
        .clk (clk), .rst (rst),
        .vaddr (i_vaddr), .req_valid (i_req), .req_write (1'b0),
        .priv_mode (d_priv), .mstatus_mpp (d_mpp), .mstatus_mprv (d_mprv),
        .mstatus_sum (d_sum), .mstatus_mxr (d_mxr),
        .satp_value (d_satp), .sfence_req (d_sfence),
        .paddr (i_paddr), .ready (i_ready),
        .page_fault (i_fault), .pf_cause (i_cause),
        .ptw_addr (i_ptw_addr), .ptw_re (i_ptw_re),
        .ptw_rdata (i_ptw_rdata), .ptw_ready (i_ptw_ready),
        .stat_hits (i_stat_hits), .stat_misses (i_stat_misses),
        .stat_faults (i_stat_faults)
    );

    // =========================================================================
    function [31:0] pte;
        input [21:0] ppn;
        input [7:0]  flags;
        begin
            pte = {ppn, 2'b00, flags};
        end
    endfunction

    integer guard;
    reg [31:0] got_pa;
    reg        got_fault;
    reg [3:0]  got_cause;
    integer    last_cycles;

    task automatic dxlate;
        input [31:0] va;
        input        wr;
        begin
            @(negedge clk);
            d_vaddr = va;
            d_write = wr;
            d_req   = 1'b1;
            guard   = 0;
            last_cycles = 0;
            got_pa    = 32'hxxxx_xxxx;
            got_fault = 1'bx;
            got_cause = 4'hx;
            while (guard < 600) begin
                @(posedge clk);
                guard = guard + 1;
                last_cycles = last_cycles + 1;
                if (d_ready) begin
                    got_pa    = d_paddr;
                    got_fault = d_fault;
                    got_cause = d_cause;
                    guard = 1000;
                end
            end
            @(negedge clk);
            d_req = 1'b0;
            if (guard < 1000) begin
                $display("  TIMEOUT translating 0x%08x", va);
                errors = errors + 1;
            end
            repeat (2) @(posedge clk);
        end
    endtask

    task automatic ixlate;
        input [31:0] va;
        begin
            @(negedge clk);
            i_vaddr = va;
            i_req   = 1'b1;
            guard   = 0;
            got_pa    = 32'hxxxx_xxxx;
            got_fault = 1'bx;
            got_cause = 4'hx;
            while (guard < 600) begin
                @(posedge clk);
                guard = guard + 1;
                if (i_ready) begin
                    got_pa    = i_paddr;
                    got_fault = i_fault;
                    got_cause = i_cause;
                    guard = 1000;
                end
            end
            @(negedge clk);
            i_req = 1'b0;
            if (guard < 1000) begin
                $display("  TIMEOUT fetching 0x%08x", va);
                errors = errors + 1;
            end
            repeat (2) @(posedge clk);
        end
    endtask

    task automatic want_pa;
        input [31:0] expect_pa;
        input [8*44-1:0] name;
        begin
            checks = checks + 1;
            if (got_fault !== 1'b0 || got_pa !== expect_pa) begin
                $display("  FAIL  %0s: pa=0x%08x fault=%b cause=%0d, wanted pa=0x%08x no fault",
                         name, got_pa, got_fault, got_cause, expect_pa);
                errors = errors + 1;
            end
        end
    endtask

    task automatic want_fault;
        input [3:0] expect_cause;
        input [8*44-1:0] name;
        begin
            checks = checks + 1;
            if (got_fault !== 1'b1 || got_cause !== expect_cause) begin
                $display("  FAIL  %0s: fault=%b cause=%0d, wanted fault with cause %0d",
                         name, got_fault, got_cause, expect_cause);
                errors = errors + 1;
            end
        end
    endtask

    task automatic sfence;
        begin
            @(negedge clk);
            d_sfence = 1'b1;
            @(posedge clk);
            @(negedge clk);
            d_sfence = 1'b0;
            repeat (2) @(posedge clk);
        end
    endtask

    // Reset the tables to a known good mapping:
    //   VA 0x0040_0000 (vpn1=1, vpn0=0) -> PA 0x8040_0000, RWX + A + D
    //   VA 0x0040_1000 (vpn1=1, vpn0=1) -> PA 0x8040_1000, same
    task automatic build_tables;
        integer k;
        begin
            for (k = 0; k < 4096; k = k + 1) mem[k] = 32'd0;
            // root[1] -> leaf table at PPN 2
            mem[(32'h1000 >> 2) + 1] = pte(22'd2, F_V);
            // leaf[0] and leaf[1]: supervisor pages, since most cases run in
            // S-mode
            mem[(32'h2000 >> 2) + 0] = pte(22'h80400, F_V|F_R|F_W|F_X|F_A|F_D);
            mem[(32'h2000 >> 2) + 1] = pte(22'h80401, F_V|F_R|F_W|F_X|F_A|F_D);
        end
    endtask

    integer h0;
    integer idx;

    initial begin
        $display("================================================================");
        $display(" Sv32 MMU unit test");
        $display("================================================================");

        build_tables;
        repeat (4) @(posedge clk);
        rst = 1'b0;
        repeat (2) @(posedge clk);

        // ------------------------------------------------------------------
        $display("\n-- bare mode is a wire --");
        d_satp = 32'd0;
        d_priv = `S_MODE;
        dxlate(32'h1234_5678, 1'b0);
        want_pa(32'h1234_5678, "satp.MODE=0 passes through");
        checks = checks + 1;
        if (last_cycles != 1) begin
            $display("  FAIL  bare mode took %0d cycles, must be 1", last_cycles);
            errors = errors + 1;
        end

        // M-mode never translates, even with satp armed.
        d_satp = SATP_ON;
        d_priv = `M_MODE;
        dxlate(32'h0040_0000, 1'b0);
        want_pa(32'h0040_0000, "M-mode does not translate");

        // ------------------------------------------------------------------
        $display("\n-- the walk --");
        d_priv = `S_MODE;
        dxlate(32'h0040_0000, 1'b0);
        want_pa(32'h8040_0000, "two-level walk");
        dxlate(32'h0040_1000, 1'b0);
        want_pa(32'h8040_1000, "second page, same table");

        // A resident entry must answer in one cycle, like bare mode.
        dxlate(32'h0040_0000, 1'b0);
        want_pa(32'h8040_0000, "TLB hit");
        checks = checks + 1;
        if (last_cycles != 1) begin
            $display("  FAIL  a TLB hit took %0d cycles, must be 1", last_cycles);
            errors = errors + 1;
        end

        dxlate(32'h0040_0000, 1'b1);
        want_pa(32'h8040_0000, "store to the same page");

        // ------------------------------------------------------------------
        $display("\n-- permissions --");
        // No W: a store faults, a load does not.
        build_tables;
        mem[(32'h2000 >> 2)] = pte(22'h80400, F_V|F_R|F_X|F_A|F_D);
        sfence;
        dxlate(32'h0040_0000, 1'b0);
        want_pa(32'h8040_0000, "load from a read-only page");
        dxlate(32'h0040_0000, 1'b1);
        want_fault(`CAUSE_STORE_PAGE_FAULT, "store to a read-only page");

        // No R: a load faults...
        build_tables;
        mem[(32'h2000 >> 2)] = pte(22'h80400, F_V|F_X|F_A|F_D);
        sfence;
        dxlate(32'h0040_0000, 1'b0);
        want_fault(`CAUSE_LOAD_PAGE_FAULT, "load from an execute-only page");
        // ...unless MXR says an executable page is readable.
        d_mxr = 1'b1;
        dxlate(32'h0040_0000, 1'b0);
        want_pa(32'h8040_0000, "MXR allows the load");
        d_mxr = 1'b0;

        // A and D are the software's job.
        build_tables;
        mem[(32'h2000 >> 2)] = pte(22'h80400, F_V|F_R|F_W|F_D);   // A=0
        sfence;
        dxlate(32'h0040_0000, 1'b0);
        want_fault(`CAUSE_LOAD_PAGE_FAULT, "A=0 faults on a load");

        build_tables;
        mem[(32'h2000 >> 2)] = pte(22'h80400, F_V|F_R|F_W|F_A);   // D=0
        sfence;
        dxlate(32'h0040_0000, 1'b0);
        want_pa(32'h8040_0000, "D=0 is fine for a load");
        dxlate(32'h0040_0000, 1'b1);
        want_fault(`CAUSE_STORE_PAGE_FAULT, "D=0 faults on a store");

        // ------------------------------------------------------------------
        $display("\n-- U, S and SUM --");
        build_tables;                                   // U=0 by default
        sfence;
        d_priv = `U_MODE;
        dxlate(32'h0040_0000, 1'b0);
        want_fault(`CAUSE_LOAD_PAGE_FAULT, "U-mode needs U=1");
        d_priv = `S_MODE;
        dxlate(32'h0040_0000, 1'b0);
        want_pa(32'h8040_0000, "S-mode reads a supervisor page");

        // A user page is off limits to S-mode until SUM says otherwise.
        build_tables;
        mem[(32'h2000 >> 2)] = pte(22'h80400, F_V|F_R|F_W|F_X|F_U|F_A|F_D);
        sfence;
        d_priv = `S_MODE;
        d_sum  = 1'b0;
        dxlate(32'h0040_0000, 1'b0);
        want_fault(`CAUSE_LOAD_PAGE_FAULT, "S-mode blocked from a user page");
        d_sum = 1'b1;
        dxlate(32'h0040_0000, 1'b0);
        want_pa(32'h8040_0000, "SUM lets it through");
        d_sum = 1'b0;

        // ------------------------------------------------------------------
        $display("\n-- MPRV --");
        // An M-mode data access with MPRV set translates as MPP. A fetch never
        // does, whatever MPRV says.
        build_tables;
        sfence;
        d_priv = `M_MODE;
        d_mpp  = `S_MODE;
        d_mprv = 1'b1;
        dxlate(32'h0040_0000, 1'b0);
        want_pa(32'h8040_0000, "MPRV translates an M-mode load");
        ixlate(32'h0040_0000);
        want_pa(32'h0040_0000, "MPRV never affects fetch");
        d_mprv = 1'b0;
        d_priv = `S_MODE;

        // ------------------------------------------------------------------
        $display("\n-- instruction fetch --");
        build_tables;
        sfence;
        ixlate(32'h0040_0000);
        want_pa(32'h8040_0000, "fetch through the same tables");

        build_tables;
        mem[(32'h2000 >> 2)] = pte(22'h80400, F_V|F_R|F_W|F_A|F_D);   // X=0
        sfence;
        ixlate(32'h0040_0000);
        want_fault(`CAUSE_FETCH_PAGE_FAULT, "fetch from a non-executable page");

        // SUM must not open a user page to a supervisor *fetch*.
        build_tables;
        mem[(32'h2000 >> 2)] = pte(22'h80400, F_V|F_R|F_W|F_X|F_U|F_A|F_D);
        sfence;
        d_priv = `S_MODE;
        d_sum  = 1'b1;
        ixlate(32'h0040_0000);
        want_fault(`CAUSE_FETCH_PAGE_FAULT, "SUM does not apply to fetch");
        d_sum = 1'b0;

        // ------------------------------------------------------------------
        $display("\n-- bad page table entries --");
        build_tables;
        mem[(32'h2000 >> 2)] = 32'd0;                                  // V=0
        sfence;
        dxlate(32'h0040_0000, 1'b0);
        want_fault(`CAUSE_LOAD_PAGE_FAULT, "invalid leaf");

        build_tables;
        mem[(32'h1000 >> 2) + 1] = 32'd0;                              // bad root
        sfence;
        dxlate(32'h0040_0000, 1'b0);
        want_fault(`CAUSE_LOAD_PAGE_FAULT, "invalid level-1 entry");

        // R=0 W=1 is reserved at every level, including with X set
        build_tables;
        mem[(32'h2000 >> 2)] = pte(22'h80400, F_V|F_W|F_X|F_A|F_D);
        sfence;
        dxlate(32'h0040_0000, 1'b0);
        want_fault(`CAUSE_LOAD_PAGE_FAULT, "reserved R=0 W=1 X=1");

        // With MXR the permission check alone would allow the load, so only
        // the walk-time rejection of the reserved encoding can fault it
        d_mxr = 1'b1;
        sfence;
        dxlate(32'h0040_0000, 1'b0);
        want_fault(`CAUSE_LOAD_PAGE_FAULT, "reserved encoding, MXR set");
        // ...and a store, where W=1 alone would otherwise permit it
        sfence;
        dxlate(32'h0040_0000, 1'b1);
        want_fault(`CAUSE_STORE_PAGE_FAULT, "reserved encoding, store");
        d_mxr = 1'b0;

        build_tables;
        mem[(32'h1000 >> 2) + 1] = pte(22'd2, F_V|F_W);
        sfence;
        dxlate(32'h0040_0000, 1'b0);
        want_fault(`CAUSE_LOAD_PAGE_FAULT, "reserved encoding at level 1");

        // A pointer where a leaf must be.
        build_tables;
        mem[(32'h2000 >> 2)] = pte(22'd3, F_V);
        sfence;
        dxlate(32'h0040_0000, 1'b0);
        want_fault(`CAUSE_LOAD_PAGE_FAULT, "pointer at the last level");

        // Beyond 4 GiB: nothing here can answer.
        build_tables;
        mem[(32'h2000 >> 2)] = pte(22'h380400, F_V|F_R|F_W|F_A|F_D);
        sfence;
        dxlate(32'h0040_0000, 1'b0);
        want_fault(`CAUSE_LOAD_PAGE_FAULT, "PPN above 4 GiB");

        // ------------------------------------------------------------------
        $display("\n-- a fault must not outlive translation --");
        // The fetch side holds req_valid continuously. After the trap switches
        // to M-mode (no translation) the fault must not persist, or every
        // fetch in the trap handler would fault too.
        build_tables;
        mem[(32'h2000 >> 2)] = 32'd0;          // unmapped
        sfence;
        d_priv = `S_MODE;
        ixlate(32'h0040_0000);
        want_fault(`CAUSE_FETCH_PAGE_FAULT, "fetch faults in S-mode");
        d_priv = `M_MODE;
        ixlate(32'h0040_0000);
        want_pa(32'h0040_0000, "and M-mode passes straight through");
        // Same for the data side
        d_priv = `S_MODE;
        dxlate(32'h0040_0000, 1'b0);
        want_fault(`CAUSE_LOAD_PAGE_FAULT, "load faults in S-mode");
        d_priv = `M_MODE;
        dxlate(32'h0040_0000, 1'b0);
        want_pa(32'h0040_0000, "and M-mode is unaffected");
        d_priv = `S_MODE;

        // ------------------------------------------------------------------
        $display("\n-- a fault belongs to one page, not to the MMU --");
        // With req_valid held, a latched fault must be released by a change of
        // address, or every later address would report the first fault.
        build_tables;
        mem[(32'h2000 >> 2) + 1] = 32'd0;      // leave page 1 unmapped
        sfence;
        d_priv = `S_MODE;
        ixlate(32'h0040_1000);
        want_fault(`CAUSE_FETCH_PAGE_FAULT, "fetch faults on the unmapped page");
        // A different page must still be walked and translate
        ixlate(32'h0040_0000);
        want_pa(32'h8040_0000, "a different page still translates");
        ixlate(32'h0040_1000);
        want_fault(`CAUSE_FETCH_PAGE_FAULT, "and the bad page still faults");
        // Same on the data side.
        dxlate(32'h0040_1000, 1'b0);
        want_fault(`CAUSE_LOAD_PAGE_FAULT, "load faults on the unmapped page");
        dxlate(32'h0040_0000, 1'b0);
        want_pa(32'h8040_0000, "and the good page still loads");

        // The same with the address changing under a continuously held
        // request, as the core's fetch side does (the tasks above drop
        // req_valid between accesses, which clears the fault by another route)
        build_tables;
        mem[(32'h2000 >> 2) + 1] = 32'd0;
        sfence;
        d_priv = `S_MODE;
        @(negedge clk);
        i_vaddr = 32'h0040_1000;
        i_req   = 1'b1;                    // and it stays high from here on
        guard = 0;
        while (guard < 600 && !(i_ready && i_fault)) begin
            @(posedge clk); guard = guard + 1;
        end
        checks = checks + 1;
        if (guard >= 600) begin
            $display("  FAIL  held request: no fault on the unmapped page");
            errors = errors + 1;
        end
        // Change the address without ever dropping the request.
        @(negedge clk);
        i_vaddr = 32'h0040_0000;
        guard = 0;
        while (guard < 600 && !(i_ready && !i_fault)) begin
            @(posedge clk); guard = guard + 1;
        end
        checks = checks + 1;
        if (guard >= 600) begin
            $display("  FAIL  held request: a new address never translated - the");
            $display("        latched fault is blocking every further walk");
            errors = errors + 1;
        end else if (i_paddr !== 32'h8040_0000) begin
            $display("  FAIL  held request: pa=0x%08x, wanted 0x80400000", i_paddr);
            errors = errors + 1;
        end
        @(negedge clk);
        i_req = 1'b0;
        repeat (2) @(posedge clk);

        // After the OS maps the page, the retried access must succeed. The
        // request drops in between, as the trap flushes the faulting
        // instruction.
        build_tables;
        mem[(32'h2000 >> 2) + 1] = 32'd0;      // page 1 unmapped for now
        sfence;
        d_priv = `S_MODE;
        dxlate(32'h0040_1000, 1'b1);
        want_fault(`CAUSE_STORE_PAGE_FAULT, "store faults on the unmapped page");
        // Populate it without SFENCE: an invalid entry is never cached
        mem[(32'h2000 >> 2) + 1] = pte(22'h80401, F_V|F_R|F_W|F_X|F_A|F_D);
        dxlate(32'h0040_1000, 1'b1);
        want_pa(32'h8040_1000, "and the retry now succeeds");
        // A resident entry takes precedence over any remembered fault
        dxlate(32'h0040_1000, 1'b0);
        want_pa(32'h8040_1000, "the resident entry keeps working");

        // The same with the fetch request held throughout: a latched fault
        // must not block the re-walk once the page is mapped
        build_tables;
        mem[(32'h2000 >> 2) + 1] = 32'd0;
        sfence;
        @(negedge clk);
        i_vaddr = 32'h0040_1000;
        i_req   = 1'b1;
        guard = 0;
        while (guard < 600 && !(i_ready && i_fault)) begin
            @(posedge clk); guard = guard + 1;
        end
        checks = checks + 1;
        if (guard >= 600) begin
            $display("  FAIL  held fetch: no fault on the unmapped page");
            errors = errors + 1;
        end
        // Map it while the request is still asserted and never dropped.
        mem[(32'h2000 >> 2) + 1] = pte(22'h80401, F_V|F_R|F_W|F_X|F_A|F_D);
        guard = 0;
        while (guard < 900 && !(i_ready && !i_fault)) begin
            @(posedge clk); guard = guard + 1;
        end
        checks = checks + 1;
        if (guard >= 900) begin
            $display("  FAIL  held fetch: the page is mapped now and still");
            $display("        faults - the latched fault is gating the re-walk");
            errors = errors + 1;
        end else if (i_paddr !== 32'h8040_1000) begin
            $display("  FAIL  held fetch: pa=0x%08x, wanted 0x80401000", i_paddr);
            errors = errors + 1;
        end
        @(negedge clk);
        i_req = 1'b0;
        repeat (2) @(posedge clk);

        // ------------------------------------------------------------------
        $display("\n-- megapages --");
        build_tables;
        // A 4 MiB leaf at level 1, aligned.
        mem[(32'h1000 >> 2) + 1] = pte(22'h80400, F_V|F_R|F_W|F_X|F_A|F_D);
        sfence;
        dxlate(32'h0040_0000, 1'b0);
        want_pa(32'h8040_0000, "megapage, offset 0");
        dxlate(32'h0040_1000, 1'b0);
        want_pa(32'h8040_1000, "megapage, next 4 KB");
        dxlate(32'h007F_F004, 1'b0);
        want_pa(32'h807F_F004, "megapage, last page");

        // Misaligned: the low ten PPN bits must be zero for a 4 MiB leaf.
        build_tables;
        mem[(32'h1000 >> 2) + 1] = pte(22'h80401, F_V|F_R|F_W|F_X|F_A|F_D);
        sfence;
        dxlate(32'h0040_0000, 1'b0);
        want_fault(`CAUSE_LOAD_PAGE_FAULT, "misaligned megapage");

        // ------------------------------------------------------------------
        $display("\n-- SFENCE.VMA and ASID --");
        build_tables;
        sfence;
        dxlate(32'h0040_0000, 1'b0);
        want_pa(32'h8040_0000, "mapped");
        // Without SFENCE.VMA the stale entry remains in use, as permitted
        mem[(32'h2000 >> 2)] = pte(22'h80500, F_V|F_R|F_W|F_X|F_A|F_D);
        dxlate(32'h0040_0000, 1'b0);
        want_pa(32'h8040_0000, "stale entry survives without a fence");
        sfence;
        dxlate(32'h0040_0000, 1'b0);
        want_pa(32'h8050_0000, "sfence forces a re-walk");

        // A different ASID must not match another address space's entries.
        h0 = d_stat_misses;
        d_satp = {1'b1, 9'd7, 22'd1};
        dxlate(32'h0040_0000, 1'b0);
        want_pa(32'h8050_0000, "other ASID walks its own tables");
        checks = checks + 1;
        if (d_stat_misses - h0 != 1) begin
            $display("  FAIL  ASID change did not miss (%0d misses)",
                     d_stat_misses - h0);
            errors = errors + 1;
        end
        d_satp = SATP_ON;

        // ------------------------------------------------------------------
        $display("\n-- against a slower memory --");
        mem_lat = 4;
        build_tables;
        sfence;
        dxlate(32'h0040_0000, 1'b0);
        want_pa(32'h8040_0000, "walk with latency");
        dxlate(32'h0040_1000, 1'b0);
        want_pa(32'h8040_1000, "second walk with latency");
        ixlate(32'h0040_0000);
        want_pa(32'h8040_0000, "fetch walk with latency");

        // ------------------------------------------------------------------
        $display("\n-- the TLB holds more than one entry --");
        mem_lat = 0;
        build_tables;
        // Eight pages fit in a 16-entry TLB: the second pass must all hit
        for (idx = 0; idx < 8; idx = idx + 1)
            mem[(32'h2000 >> 2) + idx] =
                pte(22'h80400 + idx[21:0], F_V|F_R|F_W|F_X|F_A|F_D);
        sfence;
        for (idx = 0; idx < 8; idx = idx + 1) begin
            dxlate(32'h0040_0000 + (idx << 12), 1'b0);
            want_pa(32'h8040_0000 + (idx << 12), "fill the TLB");
        end
        h0 = d_stat_misses;
        for (idx = 0; idx < 8; idx = idx + 1) begin
            dxlate(32'h0040_0000 + (idx << 12), 1'b0);
            want_pa(32'h8040_0000 + (idx << 12), "all eight still resident");
        end
        checks = checks + 1;
        if (d_stat_misses != h0) begin
            $display("  FAIL  %0d evictions with 8 entries in a 16-entry TLB",
                     d_stat_misses - h0);
            errors = errors + 1;
        end

        // ------------------------------------------------------------------
        $display("\n----------------------------------------------------------------");
        $display(" checks        : %0d", checks);
        $display(" dtlb          : %0d hits, %0d misses, %0d faults",
                 d_stat_hits, d_stat_misses, d_stat_faults);
        $display(" itlb          : %0d hits, %0d misses, %0d faults",
                 i_stat_hits, i_stat_misses, i_stat_faults);
        $display(" errors        : %0d", errors);
        $display("----------------------------------------------------------------");
        if (errors == 0) $display("*** MMU UNIT TEST PASSED ***");
        else             $display("*** MMU UNIT TEST FAILED ***");
        $finish;
    end

endmodule
