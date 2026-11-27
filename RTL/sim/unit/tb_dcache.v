// =============================================================================
// Unit testbench for the VIPT data cache.
//
// Some of what a cache has to get right is invisible from software, for the
// same reason the PLIC's claim atomicity was: the evidence is a cycle wide, or
// it is a side effect that a correct-looking result hides.
//
//   * ready asserted exactly once per request. Serve a request twice and a
//     store writes the array twice - which, being idempotent, changes nothing
//     you can read back. The machine then runs one access behind forever.
//   * an eviction putting the *right* line back. Write back the wrong tag and
//     the data lands somewhere else in memory; every later read of the line you
//     meant to save still hits in the cache and returns the correct value.
//   * byte strobes surviving a fill. A cache that ignores them looks perfect
//     until two bytes of one word are written by different instructions.
//   * MMIO never being cached. A cached UART would simply drop characters.
//
// The memory model answers with a settable latency, because a cache that only
// works against zero-latency memory is the same trap this project has already
// hit twice.
// =============================================================================
`timescale 1ns/1ps
`include "definitions.vh"

module tb_dcache;

    localparam CACHEABLE_BASE = 32'h8000_0000;
    localparam CACHEABLE_SIZE = 32'h0001_0000;   // 64 KB is plenty to thrash
    localparam LINE_SIZE      = 64;
    localparam WORDS_PER_LINE = LINE_SIZE / 4;

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #5 clk = ~clk;

    integer errors = 0;
    integer checks = 0;

    // --- CPU side ---
    reg  [31:0] cpu_addr  = 32'd0;
    reg  [31:0] cpu_wdata = 32'd0;
    reg  [3:0]  cpu_wstrb = 4'b1111;
    reg         cpu_we    = 1'b0;
    reg         cpu_re    = 1'b0;
    reg         flush_req = 1'b0;
    wire [31:0] cpu_rdata;
    wire        cpu_ready;
    wire        flush_busy;

    // --- Memory side ---
    wire [31:0] mem_addr, mem_wdata;
    wire [3:0]  mem_wstrb;
    wire        mem_we, mem_re, mem_lock;
    reg  [31:0] mem_rdata = 32'd0;
    reg         mem_ready = 1'b0;

    wire [31:0] stat_hits, stat_misses, stat_evictions, stat_uncached;

    cache_vipt #(
        .CACHE_SIZE     (4096),
        .LINE_SIZE      (LINE_SIZE),
        .WAY_NUM        (4),
        .CACHEABLE_BASE  (CACHEABLE_BASE),
        .CACHEABLE_SIZE  (CACHEABLE_SIZE),
        // A second window, at the other end of the map, so the two-region
        // decode is exercised rather than assumed. On the real SoC this is the
        // boot block RAM.
        .CACHEABLE2_BASE (32'h0000_0000),
        .CACHEABLE2_SIZE (32'h0000_8000)
    ) dut (
        .clk (clk), .rst (rst),
        .cpu_addr (cpu_addr), .cpu_paddr (cpu_addr),
        .cpu_wdata (cpu_wdata), .cpu_wstrb (cpu_wstrb),
        .cpu_we (cpu_we), .cpu_re (cpu_re), .cpu_lock (1'b0),
        .cpu_rdata (cpu_rdata), .cpu_ready (cpu_ready),
        .flush_req (flush_req), .flush_busy (flush_busy),
        .mem_addr (mem_addr), .mem_wdata (mem_wdata), .mem_wstrb (mem_wstrb),
        .mem_we (mem_we), .mem_re (mem_re), .mem_lock (mem_lock),
        .mem_rdata (mem_rdata), .mem_ready (mem_ready),
        .stat_hits (stat_hits), .stat_misses (stat_misses),
        .stat_evictions (stat_evictions), .stat_uncached (stat_uncached)
    );

    // =========================================================================
    // Memory model. Two disjoint spaces so a cacheable and an uncacheable
    // address can never alias in the model and hide a bug in the decode.
    // =========================================================================
    reg [31:0] dram [0:16383];        // 64 KB at CACHEABLE_BASE
    reg [31:0] bram [0:8191];         // 32 KB at 0x0000_0000, the second window
    reg [31:0] mmio [0:15];           // 64 B  at 0x1000_0000
    integer    mem_lat = 2;           // bus latency, in cycles
    integer    lat_cnt = 0;
    integer    mem_writes = 0;
    integer    mem_reads  = 0;

    wire        is_dram   = (mem_addr[31:28] == 4'h8);
    wire        is_bram   = (mem_addr[31:28] == 4'h0);
    wire [13:0] dram_idx  = mem_addr[15:2];
    wire [12:0] bram_idx  = mem_addr[14:2];
    wire [3:0]  mmio_idx  = mem_addr[5:2];

    always @(posedge clk) begin
        if (rst) begin
            mem_ready <= 1'b0;
            lat_cnt   <= 0;
        end else if (mem_re || mem_we) begin
            if (lat_cnt >= mem_lat) begin
                mem_ready <= 1'b1;
                lat_cnt   <= 0;
                if (mem_we) begin
                    mem_writes = mem_writes + 1;
                    if (is_dram) begin
                        if (mem_wstrb[0]) dram[dram_idx][ 7: 0] <= mem_wdata[ 7: 0];
                        if (mem_wstrb[1]) dram[dram_idx][15: 8] <= mem_wdata[15: 8];
                        if (mem_wstrb[2]) dram[dram_idx][23:16] <= mem_wdata[23:16];
                        if (mem_wstrb[3]) dram[dram_idx][31:24] <= mem_wdata[31:24];
                    end else if (is_bram) begin
                        if (mem_wstrb[0]) bram[bram_idx][ 7: 0] <= mem_wdata[ 7: 0];
                        if (mem_wstrb[1]) bram[bram_idx][15: 8] <= mem_wdata[15: 8];
                        if (mem_wstrb[2]) bram[bram_idx][23:16] <= mem_wdata[23:16];
                        if (mem_wstrb[3]) bram[bram_idx][31:24] <= mem_wdata[31:24];
                    end else begin
                        if (mem_wstrb[0]) mmio[mmio_idx][ 7: 0] <= mem_wdata[ 7: 0];
                        if (mem_wstrb[1]) mmio[mmio_idx][15: 8] <= mem_wdata[15: 8];
                        if (mem_wstrb[2]) mmio[mmio_idx][23:16] <= mem_wdata[23:16];
                        if (mem_wstrb[3]) mmio[mmio_idx][31:24] <= mem_wdata[31:24];
                    end
                end else begin
                    mem_reads = mem_reads + 1;
                end
            end else begin
                mem_ready <= 1'b0;
                lat_cnt   <= lat_cnt + 1;
            end
        end else begin
            mem_ready <= 1'b0;
            lat_cnt   <= 0;
        end
    end

    // Read data is combinational, as it is on the real bus.
    always @(*) mem_rdata = is_dram ? dram[dram_idx]
                          : is_bram ? bram[bram_idx]
                                    : mmio[mmio_idx];

    // =========================================================================
    // Structural invariant: ready may only be asserted while a request is
    // outstanding. This is the one that catches a request being served twice -
    // the second answer arrives after the CPU has moved on, and no amount of
    // checking returned data can see it.
    // =========================================================================
    reg outstanding = 1'b0;
    integer stray_ready = 0;

    always @(posedge clk) begin
        if (!rst) begin
            if (cpu_ready && !outstanding && !(cpu_re || cpu_we)) begin
                stray_ready = stray_ready + 1;
                $display("  INVARIANT FAIL: ready with no request outstanding, t=%0t", $time);
                errors = errors + 1;
            end
        end
    end

    // =========================================================================
    // Access tasks. They mimic the core exactly: hold the request until ready
    // is seen at a rising edge, then drop it on that same edge.
    // =========================================================================
    integer last_cycles = 0;

    task automatic cpu_access;
        input        we;
        input [31:0] a;
        input [3:0]  be;
        input [31:0] wd;
        output [31:0] rd;
        integer guard;
        begin
            @(negedge clk);
            cpu_addr  = a;
            cpu_wdata = wd;
            cpu_wstrb = be;
            cpu_re    = ~we;
            cpu_we    =  we;
            outstanding = 1'b1;
            rd    = 32'hxxxx_xxxx;
            guard = 0;
            last_cycles = 0;

            while (guard < 4000) begin
                @(posedge clk);
                guard = guard + 1;
                last_cycles = last_cycles + 1;
                if (cpu_ready) begin
                    rd = cpu_rdata;
                    guard = 5000;         // leave the loop
                end
            end

            @(negedge clk);
            cpu_re = 1'b0;
            cpu_we = 1'b0;
            outstanding = 1'b0;

            if (guard < 5000) begin
                $display("  TIMEOUT waiting for ready, addr=0x%08x", a);
                errors = errors + 1;
            end

            // A second answer, if the request was served twice, lands here.
            @(posedge clk);
            @(posedge clk);
        end
    endtask

    task automatic rd_check;
        input [31:0] a;
        input [31:0] want;
        input [8*40-1:0] name;
        reg   [31:0] got;
        begin
            cpu_access(1'b0, a, 4'b1111, 32'd0, got);
            checks = checks + 1;
            if (got !== want) begin
                $display("  FAIL  %0s: [0x%08x] = 0x%08x, expected 0x%08x",
                         name, a, got, want);
                errors = errors + 1;
            end
        end
    endtask

    task automatic wr;
        input [31:0] a;
        input [3:0]  be;
        input [31:0] d;
        reg   [31:0] dummy;
        begin
            cpu_access(1'b1, a, be, d, dummy);
        end
    endtask

    task automatic expect_eq;
        input [31:0] got;
        input [31:0] want;
        input [8*48-1:0] name;
        begin
            checks = checks + 1;
            if (got !== want) begin
                $display("  FAIL  %0s: got %0d, expected %0d", name, got, want);
                errors = errors + 1;
            end
        end
    endtask

    // =========================================================================
    integer i;
    integer m0, e0, h0;

    initial begin
        $display("================================================================");
        $display(" cache_vipt unit test");
        $display("================================================================");

        for (i = 0; i < 16384; i = i + 1) dram[i] = 32'hA0000000 + i;
        for (i = 0; i < 8192;  i = i + 1) bram[i] = 32'hC0000000 + i;
        for (i = 0; i < 16;    i = i + 1) mmio[i] = 32'hB0000000 + i;

        repeat (4) @(posedge clk);
        rst = 1'b0;
        repeat (2) @(posedge clk);

        // ------------------------------------------------------------------
        $display("\n-- fills and hits --");
        m0 = stat_misses;
        rd_check(CACHEABLE_BASE + 32'h0000, 32'hA0000000, "first word, cold miss");
        expect_eq(stat_misses - m0, 1, "one miss");

        // The rest of that line must now hit: this is what a 64-byte line buys.
        h0 = stat_hits;
        for (i = 1; i < WORDS_PER_LINE; i = i + 1)
            rd_check(CACHEABLE_BASE + i*4, 32'hA0000000 + i, "rest of the line");
        expect_eq(stat_hits - h0, WORDS_PER_LINE-1, "the whole line hit");
        expect_eq(stat_misses - m0, 1, "no further misses inside the line");

        // A hit costs two cycles: address in, data out.
        rd_check(CACHEABLE_BASE + 32'h0004, 32'hA0000001, "hit again");
        expect_eq(last_cycles, 2, "a hit takes two cycles");

        // ------------------------------------------------------------------
        $display("\n-- writes, dirty tracking, byte strobes --");
        wr(CACHEABLE_BASE + 32'h0008, 4'b1111, 32'hDEADBEEF);
        rd_check(CACHEABLE_BASE + 32'h0008, 32'hDEADBEEF, "write hit reads back");

        // Byte and halfword stores must leave their neighbours alone. A cache
        // that drops wstrb passes every test above and fails here.
        wr(CACHEABLE_BASE + 32'h000C, 4'b1111, 32'h11223344);
        wr(CACHEABLE_BASE + 32'h000C, 4'b0001, 32'h000000FF);
        rd_check(CACHEABLE_BASE + 32'h000C, 32'h112233FF, "sb keeps the other 3 bytes");
        wr(CACHEABLE_BASE + 32'h000C, 4'b1100, 32'hAAAA0000);
        rd_check(CACHEABLE_BASE + 32'h000C, 32'hAAAA33FF, "sh keeps the low half");

        // Nothing has been written back yet - the line is dirty in the cache.
        expect_eq(dram[3], 32'hA0000003, "memory still holds the old word");

        // ------------------------------------------------------------------
        $display("\n-- eviction puts the right line back --");
        // Five distinct lines in the same set: index bits are addr[9:6], so
        // stepping by 1 KB keeps the index and changes the tag.
        e0 = stat_evictions;
        for (i = 1; i <= 4; i = i + 1)
            rd_check(CACHEABLE_BASE + i*32'h400, 32'hA0000000 + (i*32'h400)/4,
                     "fill another way");
        expect_eq(stat_evictions - e0, 1, "the fifth line evicted one");

        // The dirty words must have reached memory, at their own addresses.
        expect_eq(dram[2], 32'hDEADBEEF, "evicted word 2 landed in memory");
        expect_eq(dram[3], 32'hAAAA33FF, "evicted word 3 landed in memory");
        expect_eq(dram[0], 32'hA0000000, "clean words unchanged");

        // And reading it back now must miss and refill from memory.
        rd_check(CACHEABLE_BASE + 32'h0008, 32'hDEADBEEF, "refilled after eviction");

        // ------------------------------------------------------------------
        $display("\n-- MMIO is never cached --");
        m0 = stat_uncached;
        mmio[0] = 32'h1111_1111;
        rd_check(32'h1000_0000, 32'h1111_1111, "uncached read");
        // Change it behind the cache's back. A cached copy would be returned
        // instead, which is exactly how a cached device register goes wrong.
        mmio[0] = 32'h2222_2222;
        rd_check(32'h1000_0000, 32'h2222_2222, "uncached read sees the new value");
        wr(32'h1000_0004, 4'b1111, 32'h3333_3333);
        expect_eq(mmio[1], 32'h3333_3333, "uncached write reached memory at once");
        expect_eq(stat_uncached - m0, 3, "three uncached accesses counted");

        // ------------------------------------------------------------------
        $display("\n-- the second cacheable window --");
        // Block RAM at the other end of the map. It has to be cached like any
        // other memory: leaving it out is what made the machine slower with a
        // cache than without one, because the BIOS lives there.
        m0 = stat_misses;
        rd_check(32'h0000_0000, 32'hC0000000, "second window, cold miss");
        expect_eq(stat_misses - m0, 1, "one miss for the whole line");
        // Counted from here: a miss ends by returning to the lookup, which then
        // hits, so the cold read scores a hit of its own.
        h0 = stat_hits;
        rd_check(32'h0000_0004, 32'hC0000001, "and the rest of its line hits");
        expect_eq(stat_hits - h0, 1, "the neighbour hit");
        wr(32'h0000_0010, 4'b1111, 32'h600D_600D);
        rd_check(32'h0000_0010, 32'h600D_600D, "written back in the second window");
        expect_eq(bram[4], 32'hC0000004, "still dirty, not yet in memory");

        // ------------------------------------------------------------------
        $display("\n-- flush writes everything back --");
        wr(CACHEABLE_BASE + 32'h0100, 4'b1111, 32'hCAFEF00D);
        wr(CACHEABLE_BASE + 32'h0800, 4'b1111, 32'h5A5A5A5A);
        @(negedge clk);
        flush_req = 1'b1;
        @(posedge clk);
        while (!flush_busy) @(posedge clk);
        while (flush_busy)  @(posedge clk);
        @(negedge clk);
        flush_req = 1'b0;
        expect_eq(bram[4], 32'h600D_600D, "flush reached the second window too");
        expect_eq(dram[32'h100/4], 32'hCAFEF00D, "flush wrote back line A");
        expect_eq(dram[32'h800/4], 32'h5A5A5A5A, "flush wrote back line B");

        // Everything is invalid now, so the next access must miss.
        m0 = stat_misses;
        rd_check(CACHEABLE_BASE + 32'h0100, 32'hCAFEF00D, "read after flush");
        expect_eq(stat_misses - m0, 1, "flush invalidated the line");

        // ------------------------------------------------------------------
        $display("\n-- a flush arriving in the same cycle as a write hit --");
        //
        // One cycle wide, and invisible from the CPU side: the write lands in
        // the data array either way, so reading it back through the cache
        // returns the right answer. What goes missing is the dirty bit, and the
        // evidence only appears at the next flush - by which time the line has
        // been invalidated and the word is gone.
        //
        // This is a real bug that reached the board's BIOS before it was found
        // here, and it is exactly the shape this project keeps running into:
        // two always blocks deciding the same thing separately.
        wr(CACHEABLE_BASE + 32'h3000, 4'b1111, 32'h0000_AAAA);
        @(negedge clk); flush_req = 1'b1;
        @(posedge clk);
        while (!flush_busy) @(posedge clk);
        @(negedge clk); flush_req = 1'b0;
        while (flush_busy) @(posedge clk);
        expect_eq(dram[32'h3000/4], 32'h0000_AAAA, "baseline is in memory");

        rd_check(CACHEABLE_BASE + 32'h3000, 32'h0000_AAAA, "line resident again");

        // The race: request the store and the flush on the same clock edge.
        @(negedge clk);
        cpu_addr    = CACHEABLE_BASE + 32'h3000;
        cpu_wdata   = 32'h0000_BBBB;
        cpu_wstrb   = 4'b1111;
        cpu_we      = 1'b1;
        cpu_re      = 1'b0;
        flush_req   = 1'b1;
        outstanding = 1'b1;
        @(negedge clk);
        flush_req = 1'b0;              // exactly one sampled cycle

        i = 0;
        while (i < 4000) begin
            @(posedge clk);
            i = i + 1;
            if (cpu_ready) i = 5000;
        end
        @(negedge clk);
        cpu_we      = 1'b0;
        outstanding = 1'b0;
        if (i < 5000) begin
            $display("  FAIL  the racing store was never answered");
            errors = errors + 1;
        end
        while (flush_busy) @(posedge clk);

        // The store must still be readable...
        rd_check(CACHEABLE_BASE + 32'h3000, 32'h0000_BBBB, "racing store survives");

        // ...and, crucially, must still be *dirty*, so a later flush publishes
        // it. With the dirty bit lost, this is where it disappears.
        @(negedge clk); flush_req = 1'b1;
        @(posedge clk);
        while (!flush_busy) @(posedge clk);
        @(negedge clk); flush_req = 1'b0;
        while (flush_busy) @(posedge clk);
        expect_eq(dram[32'h3000/4], 32'h0000_BBBB, "racing store reached memory");

        // ------------------------------------------------------------------
        $display("\n-- a longer walk, against a slower bus --");
        mem_lat = 5;
        for (i = 0; i < 512; i = i + 1)
            wr(CACHEABLE_BASE + 32'h2000 + i*4, 4'b1111, 32'h5000_0000 + i);
        for (i = 0; i < 512; i = i + 1)
            rd_check(CACHEABLE_BASE + 32'h2000 + i*4, 32'h5000_0000 + i, "walk");

        // Flush and confirm every one of them is in memory, not just in a way
        // that happens still to be resident.
        @(negedge clk);
        flush_req = 1'b1;
        @(posedge clk);
        while (!flush_busy) @(posedge clk);
        while (flush_busy)  @(posedge clk);
        @(negedge clk);
        flush_req = 1'b0;
        for (i = 0; i < 512; i = i + 1) begin
            checks = checks + 1;
            if (dram[(32'h2000/4) + i] !== 32'h5000_0000 + i) begin
                $display("  FAIL  walk word %0d: memory has 0x%08x, expected 0x%08x",
                         i, dram[(32'h2000/4) + i], 32'h5000_0000 + i);
                errors = errors + 1;
                i = 512;
            end
        end

        // ------------------------------------------------------------------
        $display("\n----------------------------------------------------------------");
        $display(" checks       : %0d", checks);
        $display(" hits         : %0d", stat_hits);
        $display(" misses       : %0d", stat_misses);
        $display(" evictions    : %0d", stat_evictions);
        $display(" uncached     : %0d", stat_uncached);
        $display(" stray readys : %0d", stray_ready);
        $display(" errors       : %0d", errors);
        $display("----------------------------------------------------------------");
        if (errors == 0) $display("*** DCACHE UNIT TEST PASSED ***");
        else             $display("*** DCACHE UNIT TEST FAILED ***");
        $finish;
    end

endmodule
