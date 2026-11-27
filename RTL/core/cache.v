`include "definitions.vh"
/* verilator lint_off DECLFILENAME */
// =============================================================================
// VIPT write-back cache. Instantiated twice: once as the data cache, and once
// with the write path tied off as the instruction cache.
//
// Sharing one module is not laziness. The instruction cache differs from the
// data cache only in never writing, so a separate module would be the same
// tags, the same PLRU tree, the same fill sequencer and the same fill bugs -
// verified separately, or more likely not. With one module, everything the
// data cache's testbench proves is also proven about the instruction cache, and
// the write, dirty and eviction logic simply disappears when nothing can set a
// dirty bit.
//
// 4-way set associative, 64-byte lines, write-back with write-allocate, PLRU
// replacement. That is Vlad's architecture from RTL/core/drafts/cache_draft.v
// and it is kept: the FSM shape, the replacement policy and the VIPT address
// split are all his. What changed is where the data lives, and why is worth
// recording.
//
// The draft read a whole line combinationally:
//
//     hit_line = cache_data[index][accessed_way];       // 512 bits, no clock
//
// Block RAM cannot do an asynchronous read, so the tool had no choice but to
// build the array out of flip-flops, and said so:
//
//     ERROR (IF0008) : The number(32768) of DFF used to infer "cache_data"
//     exceeds the resource limit(15750) of current device
//
// 32 768 flip-flops for 4 KB of data, on a part with 15 750 of them in total
// and 2 817 already spent on the CPU. Here the data array is one 32-bit word
// wide and synchronous, so it infers block RAM; the tags stay in flip-flops
// because the compare has to happen in the same cycle as the lookup.
//
// The cost of that is one cycle: a hit is two cycles, not one, because the
// address goes in on the first and the data comes out on the second. Against
// an uncached SDRAM access it is still a large win.
//
// --- VIPT, and why it is safe here ---------------------------------------
//
// Index and offset come from the *virtual* address, the tag from the physical
// one. That only works without aliasing if index+offset fits inside the page
// offset, and it does: 4 ways over 4 KB is 1 KB per way, so 10 bits of index
// and offset against SV32's 12-bit page offset. Two bits to spare.
//
// Until the MMU exists, cpu_paddr and cpu_addr are the same wire. After it,
// cpu_addr arrives first and cpu_paddr comes from the TLB, which is the whole
// point of indexing with the virtual address.
//
// --- What is not cached ---------------------------------------------------
//
// CACHEABLE_BASE and CACHEABLE_SIZE name the one region that may be cached.
// Everything else - the CLINT, the PLIC, the UART, the LEDs, the SD card -
// goes straight to the bus. This is not an optimisation. A cached MMIO read
// returns a stale value from the last time the line was filled, and a cached
// MMIO write may never reach the device at all; caching a UART transmit
// register would simply lose the characters.
//
// The decision is made on the *physical* address, because that is what names
// the device. A virtual address says nothing about what it is pointing at.
// =============================================================================
module cache_vipt #(
    parameter CACHE_SIZE = 4096,        // bytes of data, total across all ways
    parameter LINE_SIZE  = 64,          // bytes per line
    parameter WAY_NUM    = 4,           // must be 4: the PLRU tree assumes it

    // The cacheable windows: memory, and nothing else.
    //
    // Two of them, because this machine has two memories. SDRAM is the obvious
    // one. The 32 KB of block RAM at the reset vector is the one that is easy
    // to leave out and expensive to leave out: the BIOS runs entirely from it -
    // its code, its stack, its data - so with block RAM uncached, every fetch
    // and every stack access takes the slow path and the machine measured
    // *worse* than it did with no cache at all. 6.51 CPI against 3.56.
    //
    // The distinction that matters is memory versus device, not fast versus
    // slow. A device may not be cached because reading it twice is not the same
    // as reading it once. Block RAM is memory; it just happens to be nearby.
    //
    // Each window must be a power of two and aligned to its own size, which is
    // what turns the range test into one equality compare. Set a size to zero
    // to disable that window.
    parameter [`BUS_WIDTH-1:0] CACHEABLE_BASE  = 32'h8000_0000,
    parameter [`BUS_WIDTH-1:0] CACHEABLE_SIZE  = 32'h0080_0000,
    parameter [`BUS_WIDTH-1:0] CACHEABLE2_BASE = 32'h0000_0000,
    parameter [`BUS_WIDTH-1:0] CACHEABLE2_SIZE = 32'h0000_0000
)(
    input  wire clk,
    input  wire rst,

    // --- CPU side. Same protocol as the core's dmem port: hold the request
    //     until ready goes high; rdata is valid on that cycle. ---
    input  wire [`BUS_WIDTH-1:0] cpu_addr,     // index and offset come from here
    input  wire [`BUS_WIDTH-1:0] cpu_paddr,    // tag and cacheability come from here
    input  wire [`BUS_WIDTH-1:0] cpu_wdata,
    input  wire [3:0]            cpu_wstrb,
    input  wire                  cpu_we,
    input  wire                  cpu_re,
    input  wire                  cpu_lock,
    output wire [`BUS_WIDTH-1:0] cpu_rdata,
    output wire                  cpu_ready,

    // Write back every dirty line and invalidate everything. Held until
    // flush_busy falls. For fence.i, and for sfence.vma once the MMU can
    // change what a physical tag means.
    input  wire                  flush_req,
    output wire                  flush_busy,

    // --- Memory side. Same protocol again, so this drives a wb_master_bridge
    //     exactly as the core used to. ---
    output reg  [`BUS_WIDTH-1:0] mem_addr,
    output reg  [`BUS_WIDTH-1:0] mem_wdata,
    output reg  [3:0]            mem_wstrb,
    output reg                   mem_we,
    output reg                   mem_re,
    output wire                  mem_lock,
    input  wire [`BUS_WIDTH-1:0] mem_rdata,
    input  wire                  mem_ready,

    // --- Observation, for the testbench and for `make fpga-report` counters ---
    output reg  [31:0] stat_hits,
    output reg  [31:0] stat_misses,
    output reg  [31:0] stat_evictions,
    output reg  [31:0] stat_uncached
);

    // --- Geometry -----------------------------------------------------------
    localparam TOTAL_LINES  = CACHE_SIZE / LINE_SIZE;
    localparam SETS         = TOTAL_LINES / WAY_NUM;
    localparam OFFSET_BITS  = $clog2(LINE_SIZE);
    localparam INDEX_BITS   = $clog2(SETS);
    localparam WAY_BITS     = $clog2(WAY_NUM);
    // Full-width tags. An earlier version narrowed them to the size of a single
    // cacheable window, which saved 1 152 flip flops and was given up when a
    // second window was added: with two regions at opposite ends of the map the
    // tag has to say which one a line came from.
    localparam TAG_BITS     = `BUS_WIDTH - INDEX_BITS - OFFSET_BITS;
    localparam W1_BITS      = $clog2(CACHEABLE_SIZE);
    localparam W2_BITS      = (CACHEABLE2_SIZE == 0) ? 1 : $clog2(CACHEABLE2_SIZE);
    localparam WORDS_PER_LINE = LINE_SIZE / 4;
    localparam BEAT_BITS    = $clog2(WORDS_PER_LINE);
    localparam DATA_WORDS   = CACHE_SIZE / 4;
    localparam DATA_ABITS   = $clog2(DATA_WORDS);

    // Sized constants for the loop terminators, so the comparisons do not
    // silently widen.
    localparam [31:0] LAST_BEAT = WORDS_PER_LINE - 1;
    localparam [31:0] LAST_WAY  = WAY_NUM - 1;
    localparam [31:0] SET_COUNT = SETS;

    // --- Address decode -----------------------------------------------------
    // Index and offset from the virtual address, tag from the physical one.
    wire [INDEX_BITS-1:0]  idx      = cpu_addr[OFFSET_BITS +: INDEX_BITS];
    wire [BEAT_BITS-1:0]   word_sel = cpu_addr[2 +: BEAT_BITS];
    wire [TAG_BITS-1:0]    ptag     = cpu_paddr[`BUS_WIDTH-1 : INDEX_BITS+OFFSET_BITS];

    // Aligned power-of-two windows, so each range test is one equality compare
    // on the bits above the window rather than two magnitude compares.
    wire in_win1 = (cpu_paddr[`BUS_WIDTH-1:W1_BITS] ==
                    CACHEABLE_BASE[`BUS_WIDTH-1:W1_BITS]);
    wire in_win2 = (CACHEABLE2_SIZE != 0) &&
                   (cpu_paddr[`BUS_WIDTH-1:W2_BITS] ==
                    CACHEABLE2_BASE[`BUS_WIDTH-1:W2_BITS]);
    wire cacheable = in_win1 | in_win2;

    wire cpu_req = cpu_re | cpu_we;

    // --- Tag / valid / dirty, in flip-flops ---------------------------------
    // Flat arrays indexed by {set, way}: 16 sets x 4 ways x 22 bits is 1 408
    // flip-flops, which is affordable, and the compare must be combinational.
    reg [TAG_BITS-1:0] tag_ram   [0:SETS*WAY_NUM-1];
    reg                valid_ram [0:SETS*WAY_NUM-1];
    reg                dirty_ram [0:SETS*WAY_NUM-1];
    reg [2:0]          plru_tree [0:SETS-1];

    // --- Data, in block RAM -------------------------------------------------
    // One 32-bit word wide with byte enables, addressed by {way, set, word}.
    // Synchronous read: this is the change that made the design fit.
    reg [`BUS_WIDTH-1:0] data_ram [0:DATA_WORDS-1];
    reg [`BUS_WIDTH-1:0] data_dout;

    reg  [DATA_ABITS-1:0] data_raddr, data_waddr;
    reg  [`BUS_WIDTH-1:0] data_din;
    reg  [3:0]            data_be;
    reg                   data_wr;

    always @(posedge clk) begin
        if (data_wr) begin
            if (data_be[0]) data_ram[data_waddr][ 7: 0] <= data_din[ 7: 0];
            if (data_be[1]) data_ram[data_waddr][15: 8] <= data_din[15: 8];
            if (data_be[2]) data_ram[data_waddr][23:16] <= data_din[23:16];
            if (data_be[3]) data_ram[data_waddr][31:24] <= data_din[31:24];
        end
        data_dout <= data_ram[data_raddr];
    end

    // =========================================================================
    // Hit detection and PLRU victim selection. Vlad's logic, kept.
    // =========================================================================
    reg  [WAY_NUM-1:0]  hit_vec;
    reg                 is_hit;
    reg  [WAY_BITS-1:0] hit_way;
    reg  [WAY_BITS-1:0] victim_way;

    integer i;

    always @(*) begin
        is_hit  = 1'b0;
        hit_vec = {WAY_NUM{1'b0}};
        for (i = 0; i < WAY_NUM; i = i + 1) begin
            if (valid_ram[{idx, i[WAY_BITS-1:0]}] &&
                (tag_ram[{idx, i[WAY_BITS-1:0]}] == ptag)) begin
                is_hit     = 1'b1;
                hit_vec[i] = 1'b1;
            end
        end

        if      (hit_vec[0]) hit_way = 2'd0;
        else if (hit_vec[1]) hit_way = 2'd1;
        else if (hit_vec[2]) hit_way = 2'd2;
        else                 hit_way = 2'd3;

        // Three-bit tree: bit 0 chooses the half, bits 1 and 2 the pair within.
        if (!plru_tree[idx][0])
            victim_way = (!plru_tree[idx][1]) ? 2'd0 : 2'd1;
        else
            victim_way = (!plru_tree[idx][2]) ? 2'd2 : 2'd3;
    end

    // =========================================================================
    // FSM
    // =========================================================================
    localparam S_IDLE       = 3'd0,
               S_HIT        = 3'd1,   // block RAM data arrives this cycle
               S_FILL       = 3'd2,   // read a line in, one word per beat
               S_EVICT_ADDR = 3'd3,   // present a block RAM address
               S_EVICT_XFER = 3'd4,   // hold that word on the bus
               S_FLUSH_SCAN = 3'd5,   // walk every line looking for dirty ones
               S_UNC_XFER   = 3'd6,   // an uncached transfer is on the bus
               S_UNC_DONE   = 3'd7;   // and its answer is in a register

    reg [2:0]            state;
    reg [BEAT_BITS-1:0]  beat;
    reg [WAY_BITS-1:0]   act_way;     // way being filled or evicted
    reg [INDEX_BITS-1:0] act_idx;
    reg [TAG_BITS-1:0]   act_tag;     // tag to install after a fill
    reg [TAG_BITS-1:0]   evict_tag;   // tag being written back
    reg                  evict_then_fill;
    reg                  flushing;
    reg [INDEX_BITS:0]   flush_idx;   // one bit wider: it has to reach SETS
    reg [WAY_BITS-1:0]   flush_way;

    assign flush_busy = flushing;

    // Locking only matters for a transfer that actually reaches the bus. A hit
    // never does, and cannot be interfered with: the only other master on this
    // bus is instruction fetch, which reads.
    // Only an uncached transfer can reach the bus as a single access, so only
    // that one can carry LOCK. A cached atomic never leaves the cache, and
    // nothing else on this bus writes.
    assign mem_lock = unc_lock & (state == S_UNC_XFER);

    // -------------------------------------------------------------------------
    // Uncached accesses are registered in and out, and this is a timing
    // decision that was made the expensive way round.
    //
    // The first version passed them through combinationally, so that an MMIO
    // access would cost exactly what it did before the cache existed. It did -
    // and it also put this cache's cacheability decode and read-data mux into
    // the longest path in the whole SoC, which already ran
    //
    //     ALU address -> bus arbiter -> slave decode -> read data -> writeback
    //
    // in a single cycle. Synthesis reported it plainly: the worst path went
    // through alu_result, then dcache/bypass, then the arbiter, then back
    // through dcache/dmem_rdata into the register file - 44.2 ns against a
    // 41.7 ns period. The design did not close.
    //
    // Registering both ends costs two cycles on a UART or CLINT access, which
    // nothing here is sensitive to, and cuts that trunk in half. A cache that
    // is a pipeline stage is worth more than one that is a wire.
    // -------------------------------------------------------------------------
    wire uncached_req = cpu_req && !cacheable && !flushing && (state == S_IDLE);

    reg [`BUS_WIDTH-1:0] unc_addr, unc_wdata, unc_rdata;
    reg [3:0]            unc_wstrb;
    reg                  unc_we, unc_re, unc_lock;

    // A flush outranks a waiting request. Both the data array write and the
    // dirty bit have to agree about that, and they are in different always
    // blocks - so the condition lives here once rather than being written out
    // twice. Written out twice, it was wrong once: the sequential block gave
    // way to the flush while the combinational block still wrote the array, so
    // the word landed in a line nothing had marked dirty and the flush walked
    // straight past it.
    wire flush_start = flush_req && !flushing && (state == S_IDLE);
    wire serve_req   = (state == S_IDLE) && !flush_start &&
                       cpu_req && cacheable;

    // -------------------------------------------------------------------------
    // The answer is combinational off the state, not registered, and that is a
    // correctness requirement rather than a preference.
    //
    // The core holds its request until it sees ready and only advances on the
    // clock edge at the end of that cycle. A registered ready is therefore
    // asserted in a cycle where the request is still present - so the FSM would
    // see the same request again, serve it a second time, and answer one access
    // behind for the rest of time. On a store it would write the array twice.
    //
    // With ready decoded from the state instead, S_HIT is reached exactly once
    // per request and the core advances out of it. Both terms are cheap: a
    // three-bit state compare, and a block RAM output register.
    // -------------------------------------------------------------------------
    assign cpu_ready = (state == S_HIT) || (state == S_UNC_DONE);
    assign cpu_rdata = (state == S_UNC_DONE) ? unc_rdata : data_dout;

    reg [`BUS_WIDTH-1:0] fsm_mem_addr;
    reg [`BUS_WIDTH-1:0] fsm_mem_wdata;
    reg                  fsm_mem_we, fsm_mem_re;

    always @(*) begin
        if (state == S_UNC_XFER) begin
            mem_addr  = unc_addr;
            mem_wdata = unc_wdata;
            mem_wstrb = unc_wstrb;
            mem_we    = unc_we;
            mem_re    = unc_re;
        end else begin
            mem_addr  = fsm_mem_addr;
            mem_wdata = fsm_mem_wdata;
            mem_wstrb = 4'b1111;          // fills and evictions are whole words
            mem_we    = fsm_mem_we;
            mem_re    = fsm_mem_re;
        end
    end

    // Block RAM port muxing. The read address has to be presented in the same
    // cycle the tags are compared, so a hit does not cost a third cycle.
    always @(*) begin
        data_raddr = {hit_way, idx, word_sel};
        data_waddr = {act_way, act_idx, beat};
        data_din   = mem_rdata;
        data_be    = 4'b1111;
        data_wr    = 1'b0;

        case (state)
        S_IDLE: begin
            if (serve_req && is_hit && cpu_we) begin
                // Write hit: straight into the array, byte strobes and all.
                data_waddr = {hit_way, idx, word_sel};
                data_din   = cpu_wdata;
                data_be    = cpu_wstrb;
                data_wr    = 1'b1;
            end
        end
        S_FILL: begin
            data_raddr = {act_way, act_idx, beat};
            if (mem_re && mem_ready)
                data_wr = 1'b1;
        end
        S_EVICT_ADDR: data_raddr = {act_way, act_idx, beat};
        S_EVICT_XFER: data_raddr = {act_way, act_idx, beat};
        default: ;
        endcase
    end

    integer j;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state           <= S_IDLE;
            fsm_mem_we      <= 1'b0;
            fsm_mem_re      <= 1'b0;
            fsm_mem_addr    <= {`BUS_WIDTH{1'b0}};
            fsm_mem_wdata   <= {`BUS_WIDTH{1'b0}};
            beat            <= {BEAT_BITS{1'b0}};
            act_way         <= {WAY_BITS{1'b0}};
            act_idx         <= {INDEX_BITS{1'b0}};
            act_tag         <= {TAG_BITS{1'b0}};
            evict_tag       <= {TAG_BITS{1'b0}};
            evict_then_fill <= 1'b0;
            flushing        <= 1'b0;
            unc_we          <= 1'b0;
            unc_re          <= 1'b0;
            unc_lock        <= 1'b0;
            unc_addr        <= {`BUS_WIDTH{1'b0}};
            unc_wdata       <= {`BUS_WIDTH{1'b0}};
            unc_wstrb       <= 4'b0000;
            unc_rdata       <= {`BUS_WIDTH{1'b0}};
            flush_idx       <= {(INDEX_BITS+1){1'b0}};
            flush_way       <= {WAY_BITS{1'b0}};
            stat_hits       <= 32'd0;
            stat_misses     <= 32'd0;
            stat_evictions  <= 32'd0;
            stat_uncached   <= 32'd0;

            for (j = 0; j < SETS*WAY_NUM; j = j + 1) begin
                valid_ram[j] <= 1'b0;
                dirty_ram[j] <= 1'b0;
            end
            // Left unset in the draft, which left the first victim of every set
            // undefined in simulation.
            for (j = 0; j < SETS; j = j + 1)
                plru_tree[j] <= 3'b000;
        end else begin
            case (state)
            // -----------------------------------------------------------------
            S_IDLE: begin
                if (flush_start) begin
                    flushing  <= 1'b1;
                    flush_idx <= {(INDEX_BITS+1){1'b0}};
                    flush_way <= {WAY_BITS{1'b0}};
                    state     <= S_FLUSH_SCAN;
                end else if (uncached_req) begin
                    unc_addr  <= cpu_paddr;
                    unc_wdata <= cpu_wdata;
                    unc_wstrb <= cpu_wstrb;
                    unc_we    <= cpu_we;
                    unc_re    <= cpu_re;
                    unc_lock  <= cpu_lock;
                    state     <= S_UNC_XFER;
                end else if (serve_req) begin
                    if (is_hit) begin
                        stat_hits <= stat_hits + 32'd1;

                        // Point the tree away from the way just used.
                        plru_tree[idx][0] <= ~hit_way[1];
                        if (hit_way[1]) plru_tree[idx][2] <= ~hit_way[0];
                        else            plru_tree[idx][1] <= ~hit_way[0];

                        // A write commits to the array in this cycle; a read
                        // has its block RAM address presented in this cycle.
                        // Both then pass through S_HIT, which is what makes the
                        // request consumed exactly once - see the note on
                        // cpu_ready above.
                        if (cpu_we)
                            dirty_ram[{idx, hit_way}] <= 1'b1;
                        state <= S_HIT;
                    end else begin
                        stat_misses <= stat_misses + 32'd1;
                        act_way <= victim_way;
                        act_idx <= idx;
                        act_tag <= ptag;
                        beat    <= {BEAT_BITS{1'b0}};

                        if (valid_ram[{idx, victim_way}] &&
                            dirty_ram[{idx, victim_way}]) begin
                            evict_tag       <= tag_ram[{idx, victim_way}];
                            evict_then_fill <= 1'b1;
                            stat_evictions  <= stat_evictions + 32'd1;
                            state           <= S_EVICT_ADDR;
                        end else begin
                            fsm_mem_addr <= {ptag, idx, {OFFSET_BITS{1'b0}}};
                            fsm_mem_re   <= 1'b1;
                            state        <= S_FILL;
                        end
                    end
                end
            end

            // -----------------------------------------------------------------
            S_UNC_XFER: begin
                if (mem_ready) begin
                    unc_rdata     <= mem_rdata;
                    unc_we        <= 1'b0;
                    unc_re        <= 1'b0;
                    unc_lock      <= 1'b0;
                    stat_uncached <= stat_uncached + 32'd1;
                    state         <= S_UNC_DONE;
                end
            end

            S_UNC_DONE: state <= S_IDLE;

            // -----------------------------------------------------------------
            S_HIT: begin
                // cpu_ready is high for this one cycle and the core advances on
                // the edge that leaves this state.
                state <= S_IDLE;
            end

            // -----------------------------------------------------------------
            // One bus read per beat. The word is written into the array by the
            // combinational block above on the cycle mem_ready is high.
            S_FILL: begin
                if (mem_ready) begin
                    if (beat == LAST_BEAT[BEAT_BITS-1:0]) begin
                        fsm_mem_re <= 1'b0;
                        tag_ram  [{act_idx, act_way}] <= act_tag;
                        valid_ram[{act_idx, act_way}] <= 1'b1;
                        dirty_ram[{act_idx, act_way}] <= 1'b0;
                        // Back to IDLE, where the still-asserted request now
                        // hits. Two extra cycles, and it keeps one comparison
                        // path instead of two.
                        state <= S_IDLE;
                    end else begin
                        beat         <= beat + 1'b1;
                        fsm_mem_addr <= fsm_mem_addr + 32'd4;
                    end
                end
            end

            // -----------------------------------------------------------------
            // Eviction reads the array, so it needs the same one-cycle latency
            // the CPU side does: present the address, then hold the word on the
            // bus until it is taken.
            S_EVICT_ADDR: begin
                fsm_mem_addr <= {evict_tag, act_idx, beat, 2'b00};
                state        <= S_EVICT_XFER;
            end

            S_EVICT_XFER: begin
                fsm_mem_wdata <= data_dout;
                fsm_mem_we    <= 1'b1;
                if (mem_ready) begin
                    fsm_mem_we <= 1'b0;
                    if (beat == LAST_BEAT[BEAT_BITS-1:0]) begin
                        beat <= {BEAT_BITS{1'b0}};
                        dirty_ram[{act_idx, act_way}] <= 1'b0;
                        if (evict_then_fill) begin
                            evict_then_fill <= 1'b0;
                            fsm_mem_addr <= {act_tag, act_idx, {OFFSET_BITS{1'b0}}};
                            fsm_mem_re   <= 1'b1;
                            state        <= S_FILL;
                        end else begin
                            valid_ram[{act_idx, act_way}] <= 1'b0;
                            state <= S_FLUSH_SCAN;
                        end
                    end else begin
                        beat  <= beat + 1'b1;
                        state <= S_EVICT_ADDR;
                    end
                end
            end

            // -----------------------------------------------------------------
            // Flush: walk every line, write back the dirty ones, invalidate all.
            S_FLUSH_SCAN: begin
                if (flush_idx == SET_COUNT[INDEX_BITS:0]) begin
                    flushing <= 1'b0;
                    state    <= S_IDLE;
                end else if (valid_ram[{flush_idx[INDEX_BITS-1:0], flush_way}] &&
                             dirty_ram[{flush_idx[INDEX_BITS-1:0], flush_way}]) begin
                    act_idx         <= flush_idx[INDEX_BITS-1:0];
                    act_way         <= flush_way;
                    evict_tag       <= tag_ram[{flush_idx[INDEX_BITS-1:0], flush_way}];
                    evict_then_fill <= 1'b0;
                    beat            <= {BEAT_BITS{1'b0}};
                    stat_evictions  <= stat_evictions + 32'd1;
                    state           <= S_EVICT_ADDR;
                    // The counters advance here so the eviction returns to the
                    // next line rather than to this one.
                    if (flush_way == LAST_WAY[WAY_BITS-1:0]) begin
                        flush_way <= {WAY_BITS{1'b0}};
                        flush_idx <= flush_idx + 1'b1;
                    end else
                        flush_way <= flush_way + 1'b1;
                end else begin
                    valid_ram[{flush_idx[INDEX_BITS-1:0], flush_way}] <= 1'b0;
                    if (flush_way == LAST_WAY[WAY_BITS-1:0]) begin
                        flush_way <= {WAY_BITS{1'b0}};
                        flush_idx <= flush_idx + 1'b1;
                    end else
                        flush_way <= flush_way + 1'b1;
                end
            end

            default: state <= S_IDLE;
            endcase
        end
    end

    /* verilator lint_off UNUSEDSIGNAL */
    // cpu_addr contributes only its index and offset - the tag comes from
    // cpu_paddr, which is the entire point of a virtually indexed, physically
    // tagged cache. hit_vec[3] is covered by the final else in the encoder.
    wire _unused = |{cpu_addr[`BUS_WIDTH-1:OFFSET_BITS+INDEX_BITS], cpu_addr[1:0],
                     hit_vec[WAY_NUM-1]};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
