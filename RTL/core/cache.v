`include "definitions.vh"
/* verilator lint_off DECLFILENAME */
// =============================================================================
// VIPT write-back cache: 4-way set associative, 64-byte lines, write-allocate,
// tree-PLRU replacement. Instantiated twice, as the data cache and, with the
// write path tied off, as the instruction cache, so both share one verified
// implementation.
//
// The data array is one 32-bit word wide with a synchronous read so that it
// infers block RAM; tags, valid and dirty bits are flip-flops because the tag
// compare happens in the lookup cycle. A hit therefore takes two cycles.
//
// Index and offset come from the virtual address (cpu_addr), the tag and the
// cacheability decision from the physical one (cpu_paddr). This is alias-free
// because index + offset (10 bits at the default geometry) fits inside the
// 12-bit Sv32 page offset.
//
// Only the CACHEABLE windows (memory) are cached. Every other access (MMIO)
// goes to the bus as a single registered transfer, because a device read or
// write must happen exactly once.
// =============================================================================
module cache_vipt #(
    parameter CACHE_SIZE = 4096,        // bytes of data, total across all ways
    parameter LINE_SIZE  = 64,          // bytes per line
    parameter WAY_NUM    = 4,           // must be 4: the PLRU tree assumes it

    // The cacheable windows, one per memory (SDRAM and the boot block RAM;
    // the BIOS runs from the latter, so it must be cached too). Each window
    // must be a power of two, aligned to its size, so the range test is one
    // equality compare. A size of zero disables the second window.
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

    // Write back every dirty line and invalidate everything (FENCE.I).
    // flush_busy is high while the flush runs.
    input  wire                  flush_req,
    output wire                  flush_busy,

    // --- Memory side. Same protocol, to a wb_master_bridge. ---
    output reg  [`BUS_WIDTH-1:0] mem_addr,
    output reg  [`BUS_WIDTH-1:0] mem_wdata,
    output reg  [3:0]            mem_wstrb,
    output reg                   mem_we,
    output reg                   mem_re,
    output wire                  mem_lock,
    input  wire [`BUS_WIDTH-1:0] mem_rdata,
    input  wire                  mem_ready,

    // --- Statistics, for the testbench and performance reports ---
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
    // Full-width tags: with two cacheable windows the tag must also say which
    // window a line came from.
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
    // Flat arrays indexed by {set, way}. The compare must be combinational.
    reg [TAG_BITS-1:0] tag_ram   [0:SETS*WAY_NUM-1];
    reg                valid_ram [0:SETS*WAY_NUM-1];
    reg                dirty_ram [0:SETS*WAY_NUM-1];
    reg [2:0]          plru_tree [0:SETS-1];

    // --- Data, in block RAM -------------------------------------------------
    // One 32-bit word wide with byte enables, addressed by {way, set, word}.
    // Synchronous read, so it maps onto block RAM.
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
    // Hit detection and PLRU victim selection
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

    // -------------------------------------------------------------------------
    // Uncached accesses are registered in and out. Passing them through
    // combinationally would put the cacheability decode and the read-data mux
    // on the core's longest path; registering costs two cycles per MMIO access.
    // -------------------------------------------------------------------------
    wire uncached_req = cpu_req && !cacheable && !flushing && (state == S_IDLE);

    reg [`BUS_WIDTH-1:0] unc_addr, unc_wdata, unc_rdata;
    reg [3:0]            unc_wstrb;
    reg                  unc_we, unc_re, unc_lock;

    // Only an uncached transfer reaches the bus as a single access, so only it
    // can carry LOCK. Cached atomics complete inside the cache, and the only
    // other bus master (instruction fetch) never writes.
    assign mem_lock = unc_lock & (state == S_UNC_XFER);

    // A flush outranks a waiting request. The data-array write and the dirty
    // bit live in different always blocks, so both use this one condition.
    wire flush_start = flush_req && !flushing && (state == S_IDLE);
    wire serve_req   = (state == S_IDLE) && !flush_start &&
                       cpu_req && cacheable;

    // -------------------------------------------------------------------------
    // ready is decoded from the state. The core holds its request through the
    // ready cycle, so S_HIT / S_UNC_DONE are each entered exactly once per
    // request and the FSM returns to idle as the core advances.
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
                        // presents its block RAM address. Both then answer
                        // from S_HIT.
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
                        // hits: one compare path instead of two.
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
    // cpu_addr contributes only its index and offset; the tag comes from
    // cpu_paddr. hit_vec[3] is covered by the final else in the encoder.
    wire _unused = |{cpu_addr[`BUS_WIDTH-1:OFFSET_BITS+INDEX_BITS], cpu_addr[1:0],
                     hit_vec[WAY_NUM-1]};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
