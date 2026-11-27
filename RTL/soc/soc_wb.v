`include "definitions.vh"
`include "wb_defines.vh"

// =============================================================================
// The SoC: RV32IM core, Wishbone interconnect, boot RAM, SDRAM, UART.
//
// Platform independent. The same module is instantiated by the simulation
// testbench (against a behavioural SDRAM model) and by the Tang Nano 20K top
// level (against the real embedded SDRAM), so hardware and simulation exercise
// identical logic.
//
//   riscv_core
//     |  imem                              dmem
//     v                                     v
//   wb_master_bridge                      wb_master_bridge
//     \                                     /
//      \-------------- wb_arbiter ---------/     data port has priority
//                          |
//                     wb_intercon                decode, return mux, err slave
//        /------/------/------|------\--------\--------\
//   boot RAM  CLINT  PLIC    UART   LED PWM   SD card   SDRAM
//  0x0000_0000  0x0200_0000  0x0C00_0000  0x1000_0000  0x1100_0000  0x8000_0000
//
// The CLINT is a bus slave, not part of the core, because the ACLINT spec
// defines MTIME and MTIMECMP as memory-mapped registers - there is deliberately
// no mtime CSR. Its two outputs go back to the core as interrupt pins, and its
// mtime feeds the core's `time` CSR.
//
// The PLIC is the same shape: a bus slave whose output is an interrupt pin.
// It collects every device interrupt in the system and presents one wire to the
// core, so the core does not need to know how many devices exist. Both of its
// contexts are now wired: M-mode to mip.MEIP and S-mode to mip.SEIP.
//
// Interrupt sources: the UART is source 1, and sources 2..5 are software
// triggered from the GPIO block's SWIRQ register, which is how the PLIC's
// priority and threshold logic gets exercised without needing four devices.
// =============================================================================
module soc_wb #(
    parameter FREQ      = `SOC_CLK_HZ,
    parameter BOOT_INIT = "",         // hex image for the boot RAM

    // Data cache. Set to 0 to take it out of the path entirely, which is how a
    // suspected cache bug gets separated from a suspected core bug: rebuild
    // with DCACHE=0 and see whether the symptom survives.
    parameter DCACHE      = 1,
    parameter DCACHE_SIZE = 4096,
    parameter DCACHE_LINE = 64,

    // Instruction cache. The same module with its write port tied off, so the
    // dirty bits, the eviction sequencer and the byte strobes all optimise
    // away - an instruction cache is a data cache that never writes.
    parameter ICACHE      = 1,
    parameter ICACHE_SIZE = 4096,
    parameter ICACHE_LINE = 64
)(
    input  wire clk,
    input  wire clk_sdram,            // phase shifted from clk, for the SDRAM
    input  wire rst,

    // --- SDRAM pins ---
    inout  wire [31:0] SDRAM_DQ,
    output wire [10:0] SDRAM_A,
    output wire [1:0]  SDRAM_BA,
    output wire        SDRAM_nCS,
    output wire        SDRAM_nWE,
    output wire        SDRAM_nRAS,
    output wire        SDRAM_nCAS,
    output wire        SDRAM_CLK,
    output wire        SDRAM_CKE,
    output wire [3:0]  SDRAM_DQM,

    // --- Serial ---
    output wire        uart_tx,
    input  wire        uart_rx,

    // --- SD card, SPI mode ---
    output wire        sd_cs_n,
    output wire        sd_sck,
    output wire        sd_mosi,
    input  wire        sd_miso,

    // --- LED brightness, active high; the board inverts ---
    output wire [`LED_CHANNELS-1:0] led_pwm,

    // --- Status and debug ---
    output wire        halted,
    output wire        trap_error,
    output wire        ebreak_halt,
    output wire [3:0]  trap_cause,
    output wire        bus_error,
    output wire        decode_miss,

    input  wire [`REG_ADDR_WIDTH-1:0] dbg_reg_addr,
    output wire [`BUS_WIDTH-1:0]      dbg_reg_data,
    output wire                       retire_valid,
    output wire [`BUS_WIDTH-1:0]      retire_pc,
    output wire [`BUS_WIDTH-1:0]      retire_instruction,
    output wire [`BUS_WIDTH-1:0]      dbg_stage2_pc,
    output wire [`BUS_WIDTH-1:0]      dbg_stage2_instruction,
    output wire                       dbg_muldiv_stall,
    output wire                       dbg_csr_capture,
    output wire                       dbg_csr_commit,
    output wire [`BUS_WIDTH-1:0]      dbg_csr_old,
    output wire                       dbg_amo_read,
    output wire                       dbg_amo_write,
    output wire                       dbg_resv_valid,

    // Data cache observation. Zero when DCACHE=0. Not memory mapped, so on
    // hardware these are stripped; in simulation they are how a cache that is
    // working differently from expected gets told apart from one that is
    // broken.
    output wire [31:0]                dbg_dc_hits,
    output wire [31:0]                dbg_dc_misses,
    output wire [31:0]                dbg_dc_evictions,
    output wire [31:0]                dbg_dc_uncached,
    output wire [31:0]                dbg_ic_hits,
    output wire [31:0]                dbg_ic_misses,
    output wire [31:0]                dbg_ic_uncached,
    output wire [31:0]                dbg_dtlb_hits,
    output wire [31:0]                dbg_dtlb_misses,
    output wire [31:0]                dbg_dtlb_faults,
    output wire [31:0]                dbg_itlb_hits,
    output wire [31:0]                dbg_itlb_misses,
    output wire [31:0]                dbg_itlb_faults,

    // Bring-up only: the flush handshake, brought out so it can be watched on
    // the LEDs. FENCE.I stops returning on hardware and returns in simulation,
    // which means the difference is not visible in any waveform I can produce.
    output wire [4:0]                 dbg_flush
);

    // ------------------------------------------------------------------------
    // Core
    // ------------------------------------------------------------------------
    // Declared here rather than beside the CLINT, because the core is
    // instantiated first and needs them.
    wire        irq_soft, irq_timer;
    wire [63:0] mtime;
    wire [`PLIC_CTXS-1:0] plic_eip;

    wire [`BUS_WIDTH-1:0] imem_addr, imem_rdata;
    wire                  imem_req, imem_ready;

    wire [`BUS_WIDTH-1:0] ibus_addr, ibus_rdata;
    wire                  ibus_re, ibus_ready;

    // Zifencei plumbing. Declared here because the core connects to it above
    // the sequencer that drives it.
    wire fence_i_req;
    // TLB observation, declared above the core that drives it.
    wire [31:0] dtlb_hits, dtlb_misses, dtlb_faults;
    wire [31:0] itlb_hits, itlb_misses, itlb_faults;
    wire dcache_flush_busy, icache_flush_busy;
    wire dcache_flush, icache_flush;
    // Declared here, with the others, and not where it is assigned further
    // down. Using it before declaring it created an implicit net: Verilator
    // merged that with the real one and simulated correctly, Gowin made two
    // nets and left the core's input undriven, so FENCE.I waited forever for a
    // signal that could not arrive. `make fpga` now fails on this.
    wire cache_flush_busy;
    // Declared here, with the others, and not where it is assigned further
    // down. Using it before declaring it created an implicit net: Verilator
    // merged that with the real one and simulated correctly, Gowin made two
    // nets and left the core's input undriven, so FENCE.I waited forever for a
    // signal that could not arrive. The synthesiser said so - "Net
    // 'cache_flush_busy' does not have a driver" - and the build did not fail,
    // so nobody read it. See the EX1998 check in the Makefile.

    wire [`BUS_WIDTH-1:0] dmem_addr, dmem_wdata, dmem_rdata;
    wire [3:0]            dmem_wstrb;
    wire                  dmem_we, dmem_re, dmem_ready, dmem_lock;

    // Between the core's data port and its bus bridge. Both sides speak the
    // same request/ready protocol, so the cache is a shim rather than a new
    // kind of connection - and DCACHE=0 removes it by wiring the two together.
    wire [`BUS_WIDTH-1:0] dbus_addr, dbus_wdata, dbus_rdata;
    wire [3:0]            dbus_wstrb;
    wire                  dbus_we, dbus_re, dbus_ready, dbus_lock;

    riscv_core core (
        .clk                    (clk),
        .rst                    (rst),
        .imem_addr              (imem_addr),
        .imem_req               (imem_req),
        .imem_rdata             (imem_rdata),
        .imem_ready             (imem_ready),
        .dmem_addr              (dmem_addr),
        .dmem_wdata             (dmem_wdata),
        .dmem_wstrb             (dmem_wstrb),
        .dmem_we                (dmem_we),
        .dmem_re                (dmem_re),
        .dmem_lock              (dmem_lock),
        .dmem_rdata             (dmem_rdata),
        .dmem_ready             (dmem_ready),
        .fence_i_req            (fence_i_req),
        .cache_flush_busy       (cache_flush_busy),
        .dbg_dtlb_hits          (dtlb_hits),
        .dbg_dtlb_misses        (dtlb_misses),
        .dbg_itlb_hits          (itlb_hits),
        .dbg_itlb_misses        (itlb_misses),
        .dbg_dtlb_faults        (dtlb_faults),
        .dbg_itlb_faults        (itlb_faults),
        .irq_soft               (irq_soft),
        .irq_timer              (irq_timer),
        // The PLIC's two contexts, finally both connected: context 0 is hart 0
        // machine mode and context 1 is hart 0 supervisor mode. Building the
        // second one before S-mode existed is what made this a one-line change.
        .irq_ext                (plic_eip[0]),
        .irq_ext_s              (plic_eip[1]),
        .mtime                  (mtime),
        .halted                 (halted),
        .trap_error             (trap_error),
        .ebreak_halt            (ebreak_halt),
        .trap_cause             (trap_cause),
        .dbg_reg_addr           (dbg_reg_addr),
        .dbg_reg_data           (dbg_reg_data),
        .retire_valid           (retire_valid),
        .retire_pc              (retire_pc),
        .retire_instruction     (retire_instruction),
        .dbg_stage2_pc          (dbg_stage2_pc),
        .dbg_stage2_instruction (dbg_stage2_instruction),
        .dbg_muldiv_stall       (dbg_muldiv_stall),
        .dbg_csr_capture        (dbg_csr_capture),
        .dbg_csr_commit         (dbg_csr_commit),
        .dbg_csr_old            (dbg_csr_old),
        .dbg_amo_read           (dbg_amo_read),
        .dbg_amo_write          (dbg_amo_write),
        .dbg_resv_valid         (dbg_resv_valid)
    );

    // ------------------------------------------------------------------------
    // Data cache
    //
    // The cacheable window is the SDRAM region and nothing else. It comes from
    // wb_defines.vh rather than being written out here, so the map has one
    // source of truth: move the SDRAM and the cache follows.
    //
    // Everything else on this bus is a device. A cached CLINT would return a
    // frozen mtime, a cached UART would drop the characters it was asked to
    // send, and a cached PLIC claim would hand out the same interrupt forever.
    // ------------------------------------------------------------------------
    wire [31:0] dc_hits, dc_misses, dc_evictions, dc_uncached;

    assign dbg_dc_hits      = dc_hits;
    assign dbg_dc_misses    = dc_misses;
    assign dbg_dc_evictions = dc_evictions;
    assign dbg_dc_uncached  = dc_uncached;
    assign dbg_ic_hits      = ic_hits;
    assign dbg_ic_misses    = ic_misses;
    assign dbg_ic_uncached  = ic_uncached;
    assign dbg_dtlb_hits    = dtlb_hits;
    assign dbg_dtlb_misses  = dtlb_misses;
    assign dbg_dtlb_faults  = dtlb_faults;
    assign dbg_itlb_hits    = itlb_hits;
    assign dbg_itlb_misses  = itlb_misses;
    assign dbg_itlb_faults  = itlb_faults;
    assign dbg_flush = {fl_state, fl_busy, icache_flush_busy, dcache_flush_busy};

    generate
    if (DCACHE) begin : g_dcache
        cache_vipt #(
            .CACHE_SIZE     (DCACHE_SIZE),
            .LINE_SIZE      (DCACHE_LINE),
            .WAY_NUM        (4),
            .CACHEABLE_BASE  (`SDRAM_BASE_ADDR),
            .CACHEABLE_SIZE  (`SDRAM_BYTES),
            // The boot block RAM is memory too, and the BIOS lives in it.
            .CACHEABLE2_BASE (32'h0000_0000),
            .CACHEABLE2_SIZE (`BOOT_RAM_BYTES)
        ) dcache (
            .clk (clk), .rst (rst),
            // Index and tag are the same wire until the MMU lands, at which
            // point cpu_addr stays virtual and cpu_paddr comes from the TLB.
            .cpu_addr  (dmem_addr),
            .cpu_paddr (dmem_addr),
            .cpu_wdata (dmem_wdata),
            .cpu_wstrb (dmem_wstrb),
            .cpu_we    (dmem_we),
            .cpu_re    (dmem_re),
            .cpu_lock  (dmem_lock),
            .cpu_rdata (dmem_rdata),
            .cpu_ready (dmem_ready),
            .flush_req  (dcache_flush),
            .flush_busy (dcache_flush_busy),
            .mem_addr  (dbus_addr),
            .mem_wdata (dbus_wdata),
            .mem_wstrb (dbus_wstrb),
            .mem_we    (dbus_we),
            .mem_re    (dbus_re),
            .mem_lock  (dbus_lock),
            .mem_rdata (dbus_rdata),
            .mem_ready (dbus_ready),
            .stat_hits      (dc_hits),
            .stat_misses    (dc_misses),
            .stat_evictions (dc_evictions),
            .stat_uncached  (dc_uncached)
        );
    end else begin : g_no_dcache
        assign dbus_addr  = dmem_addr;
        assign dbus_wdata = dmem_wdata;
        assign dbus_wstrb = dmem_wstrb;
        assign dbus_we    = dmem_we;
        assign dbus_re    = dmem_re;
        assign dbus_lock  = dmem_lock;
        assign dmem_rdata = dbus_rdata;
        assign dmem_ready = dbus_ready;
        assign dc_hits      = 32'd0;
        assign dc_misses    = 32'd0;
        assign dc_evictions = 32'd0;
        assign dc_uncached  = 32'd0;
        assign dcache_flush_busy = 1'b0;
    end
    endgenerate

    // ------------------------------------------------------------------------
    // FENCE.I sequencer
    //
    // Turns the core's request into a flush of both caches and a busy signal
    // that is honest about when it is safe to carry on.
    //
    // The one property this must never lose is termination. The core waits for
    // busy to rise and then fall; if it could never rise, FENCE.I would hang
    // the machine. So the GO state leaves as soon as either cache reports it
    // has started - and when neither cache exists, HAVE_CACHE is a constant
    // zero and the state machine falls straight through.
    // ------------------------------------------------------------------------
    localparam FL_IDLE = 2'd0, FL_GO = 2'd1, FL_WAIT = 2'd2;
    reg [1:0] fl_state;
    reg       fl_busy;
    reg       d_req, i_req;

    wire caches_busy = dcache_flush_busy | icache_flush_busy;

    // A request per cache, dropped as soon as *that* cache has taken it.
    //
    // The first version drove one shared request and left it asserted until
    // both caches reported busy at the same time. Nothing makes that happen:
    // the two caches start whenever each next reaches its idle state, which
    // depends on what each was doing, and one can finish an entire flush before
    // the other has begun. Then "both busy" never holds, the request is never
    // withdrawn, and each cache re-flushes the moment it finishes - forever.
    //
    // Holding a per-cache request until that cache acknowledges removes the
    // simultaneity requirement and the re-trigger at once.
    assign dcache_flush = d_req;
    assign icache_flush = i_req;

    // A flush is bounded work - 64 lines, each at worst a 16-word write-back -
    // so anything past a million cycles is not slow, it is stuck. Giving up
    // turns a hang into a wrong answer, which is worse in principle and far
    // better in practice: the machine keeps running and can be asked what
    // happened, instead of going quiet with no way in.
    reg [20:0] fl_timer;
    reg [31:0] fl_status;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            fl_state  <= FL_IDLE;
            fl_busy   <= 1'b0;
            d_req     <= 1'b0;
            i_req     <= 1'b0;
            fl_timer  <= 21'd0;
            fl_status <= 32'd0;
        end else begin
            if (fl_state == FL_IDLE)
                fl_timer <= 21'd0;
            else if (!(&fl_timer))
                fl_timer <= fl_timer + 21'd1;

            if (&fl_timer) begin
                // Latch everything that could explain it, then let go.
                fl_status <= {16'hF1F1,
                              6'd0, dcache_flush_busy, icache_flush_busy,
                              2'd0, d_req, i_req, 2'd0, fl_state};
                fl_state  <= FL_IDLE;
                fl_busy   <= 1'b0;
                d_req     <= 1'b0;
                i_req     <= 1'b0;
                fl_timer  <= 21'd0;
            end else
            case (fl_state)
            FL_IDLE: if (fence_i_req) begin
                        fl_state <= FL_GO;
                        fl_busy  <= 1'b1;
                        d_req    <= (DCACHE != 0);
                        i_req    <= (ICACHE != 0);
                     end
            FL_GO: begin
                        if (dcache_flush_busy) d_req <= 1'b0;
                        if (icache_flush_busy) i_req <= 1'b0;
                        // Both acknowledged - or, with no caches built, both
                        // were never asked, which is what stops FENCE.I hanging
                        // a machine that has nothing to flush.
                        if (!d_req && !i_req)
                            fl_state <= FL_WAIT;
                   end
            FL_WAIT: if (!caches_busy) begin
                        fl_state <= FL_IDLE;
                        fl_busy  <= 1'b0;
                     end
            default: fl_state <= FL_IDLE;
            endcase
        end
    end

    // Busy from the request itself, not from the cycle after: the core samples
    // this in the same cycle it asks, and a low answer there would let FENCE.I
    // retire before anything had happened.
    assign cache_flush_busy = fl_busy | fence_i_req;

    // ------------------------------------------------------------------------
    // Instruction cache
    //
    // This is where the CPI number lives. With no cache every instruction fetch
    // is a bus transaction, and fetch and data share one bus - which is the
    // whole explanation for 3.55 CPI on hardware. It only helps code running
    // from SDRAM: the BIOS runs from block RAM, which is outside the cacheable
    // window and is answered in a cycle anyway.
    // ------------------------------------------------------------------------
    wire [31:0] ic_hits, ic_misses, ic_uncached;
    /* verilator lint_off UNUSEDSIGNAL */
    // The instruction cache cannot evict: nothing sets a dirty bit, so the
    // write-back path is unreachable and synthesis removes it. The counter is
    // kept only so both instances share one port list.
    wire [31:0] ic_evictions;
    wire [31:0] ic_dead_wdata;
    wire [3:0]  ic_dead_wstrb;
    wire        ic_dead_we, ic_dead_lock;
    /* verilator lint_on UNUSEDSIGNAL */

    generate
    if (ICACHE) begin : g_icache
        cache_vipt #(
            .CACHE_SIZE     (ICACHE_SIZE),
            .LINE_SIZE      (ICACHE_LINE),
            .WAY_NUM        (4),
            .CACHEABLE_BASE  (`SDRAM_BASE_ADDR),
            .CACHEABLE_SIZE  (`SDRAM_BYTES),
            // The boot block RAM is memory too, and the BIOS lives in it.
            .CACHEABLE2_BASE (32'h0000_0000),
            .CACHEABLE2_SIZE (`BOOT_RAM_BYTES)
        ) icache (
            .clk (clk), .rst (rst),
            .cpu_addr  (imem_addr),
            .cpu_paddr (imem_addr),
            .cpu_wdata (32'd0),
            .cpu_wstrb (4'b0000),
            // Tied low. Nothing can set a dirty bit, so the eviction path is
            // unreachable and synthesis removes it along with the write port.
            .cpu_we    (1'b0),
            .cpu_re    (imem_req),
            .cpu_lock  (1'b0),
            .cpu_rdata (imem_rdata),
            .cpu_ready (imem_ready),
            .flush_req  (icache_flush),
            .flush_busy (icache_flush_busy),
            .mem_addr  (ibus_addr),
            // An instruction cache never writes, so these go nowhere. Named
            // rather than left empty: a dangling output should say so.
            .mem_wdata (ic_dead_wdata),
            .mem_wstrb (ic_dead_wstrb),
            .mem_we    (ic_dead_we),
            .mem_re    (ibus_re),
            .mem_lock  (ic_dead_lock),
            .mem_rdata (ibus_rdata),
            .mem_ready (ibus_ready),
            .stat_hits      (ic_hits),
            .stat_misses    (ic_misses),
            .stat_evictions (ic_evictions),
            .stat_uncached  (ic_uncached)
        );
    end else begin : g_no_icache
        assign ibus_addr  = imem_addr;
        assign ibus_re    = imem_req;
        assign imem_rdata = ibus_rdata;
        assign imem_ready = ibus_ready;
        assign ic_hits      = 32'd0;
        assign ic_misses    = 32'd0;
        assign ic_evictions = 32'd0;
        assign ic_uncached  = 32'd0;
        assign icache_flush_busy = 1'b0;
    end
    endgenerate

    // ------------------------------------------------------------------------
    // Two Wishbone masters
    // ------------------------------------------------------------------------
    wire [`WB_ADDR_WIDTH-1:0] m0_adr, m1_adr;
    wire [`WB_DATA_WIDTH-1:0] m0_dat_w, m1_dat_w, m0_dat_r, m1_dat_r;
    wire [`WB_SEL_WIDTH-1:0]  m0_sel, m1_sel;
    wire                      m0_we, m1_we, m0_stb, m1_stb, m0_cyc, m1_cyc;
    wire                      m0_lock;
    /* verilator lint_off UNUSEDSIGNAL */
    // The instruction port never locks the bus: it only ever reads, and a fetch
    // is a single transfer.
    wire                      m1_lock;
    /* verilator lint_on UNUSEDSIGNAL */
    wire                      m0_ack, m1_ack, m0_err, m1_err;
    wire                      d_bus_error, i_bus_error;

    assign bus_error = d_bus_error | i_bus_error;

    // Data port
    wb_master_bridge dbus (
        .clk (clk), .rst (rst),
        .addr (dbus_addr), .wdata (dbus_wdata), .wstrb (dbus_wstrb),
        .we (dbus_we), .re (dbus_re), .lock (dbus_lock),
        .rdata (dbus_rdata), .ready (dbus_ready),
        .wb_adr_o (m0_adr), .wb_dat_o (m0_dat_w), .wb_sel_o (m0_sel),
        .wb_we_o (m0_we), .wb_stb_o (m0_stb), .wb_cyc_o (m0_cyc),
        .wb_lock_o (m0_lock),
        .wb_dat_i (m0_dat_r), .wb_ack_i (m0_ack), .wb_err_i (m0_err),
        .bus_error (d_bus_error)
    );

    // Instruction port: reads only, so wstrb is all lanes and we is low
    wb_master_bridge ibus (
        .clk (clk), .rst (rst),
        .addr (ibus_addr), .wdata (32'd0), .wstrb (4'b1111),
        .we (1'b0), .re (ibus_re), .lock (1'b0),
        .rdata (ibus_rdata), .ready (ibus_ready),
        .wb_adr_o (m1_adr), .wb_dat_o (m1_dat_w), .wb_sel_o (m1_sel),
        .wb_we_o (m1_we), .wb_stb_o (m1_stb), .wb_cyc_o (m1_cyc),
        .wb_lock_o (m1_lock),
        .wb_dat_i (m1_dat_r), .wb_ack_i (m1_ack), .wb_err_i (m1_err),
        .bus_error (i_bus_error)
    );

    // ------------------------------------------------------------------------
    // Arbiter and interconnect
    // ------------------------------------------------------------------------
    wire [`WB_ADDR_WIDTH-1:0] b_adr;
    wire [`WB_DATA_WIDTH-1:0] b_dat_w, b_dat_r;
    wire [`WB_SEL_WIDTH-1:0]  b_sel;
    wire                      b_we, b_stb, b_cyc, b_ack, b_err;

    wb_arbiter arb (
        .clk (clk), .rst (rst),
        .m0_adr_i (m0_adr), .m0_dat_i (m0_dat_w), .m0_sel_i (m0_sel),
        .m0_we_i (m0_we), .m0_stb_i (m0_stb), .m0_cyc_i (m0_cyc),
        .m0_lock_i (m0_lock),
        .m0_dat_o (m0_dat_r), .m0_ack_o (m0_ack), .m0_err_o (m0_err),
        .m1_adr_i (m1_adr), .m1_dat_i (m1_dat_w), .m1_sel_i (m1_sel),
        .m1_we_i (m1_we), .m1_stb_i (m1_stb), .m1_cyc_i (m1_cyc),
        .m1_dat_o (m1_dat_r), .m1_ack_o (m1_ack), .m1_err_o (m1_err),
        .s_adr_o (b_adr), .s_dat_o (b_dat_w), .s_sel_o (b_sel),
        .s_we_o (b_we), .s_stb_o (b_stb), .s_cyc_o (b_cyc),
        .s_dat_i (b_dat_r), .s_ack_i (b_ack), .s_err_i (b_err)
    );

    wire [`WB_ADDR_WIDTH-1:0] s_adr;
    wire [`WB_DATA_WIDTH-1:0] s_dat_w;
    wire [`WB_SEL_WIDTH-1:0]  s_sel;
    wire                      s_we, s_cyc;

    wire boot_stb,  uart_stb,  sdram_stb,  clint_stb,  led_stb,  plic_stb;
    wire boot_ack,  uart_ack,  sdram_ack,  clint_ack,  led_ack,  plic_ack;
    wire sd_stb,    sd_ack;
    wire [`WB_DATA_WIDTH-1:0] boot_dat, uart_dat, sdram_dat, clint_dat, led_dat;
    wire [`WB_DATA_WIDTH-1:0] plic_dat, sd_dat;

    wb_intercon icon (
        .clk (clk), .rst (rst),
        .m_adr_i (b_adr), .m_dat_i (b_dat_w), .m_sel_i (b_sel),
        .m_we_i (b_we), .m_stb_i (b_stb), .m_cyc_i (b_cyc),
        .m_dat_o (b_dat_r), .m_ack_o (b_ack), .m_err_o (b_err),
        .s_adr_o (s_adr), .s_dat_o (s_dat_w), .s_sel_o (s_sel),
        .s_we_o (s_we), .s_cyc_o (s_cyc),
        .boot_stb_o (boot_stb), .boot_dat_i (boot_dat), .boot_ack_i (boot_ack),
        .uart_stb_o (uart_stb), .uart_dat_i (uart_dat), .uart_ack_i (uart_ack),
        .sdram_stb_o (sdram_stb), .sdram_dat_i (sdram_dat), .sdram_ack_i (sdram_ack),
        .clint_stb_o (clint_stb), .clint_dat_i (clint_dat), .clint_ack_i (clint_ack),
        .led_stb_o   (led_stb),   .led_dat_i   (led_dat),   .led_ack_i   (led_ack),
        .plic_stb_o  (plic_stb),  .plic_dat_i  (plic_dat),  .plic_ack_i  (plic_ack),
        .sd_stb_o    (sd_stb),    .sd_dat_i    (sd_dat),    .sd_ack_i    (sd_ack),
        .decode_miss (decode_miss)
    );

    // ------------------------------------------------------------------------
    // Slave: boot RAM. Holds the BIOS, and its stack and data, so nothing
    // depends on SDRAM being alive before the memory test runs.
    // ------------------------------------------------------------------------
    wb_ram #(
        .MEM_BYTES (`BOOT_RAM_BYTES),
        .INIT_FILE (BOOT_INIT)
    ) bootram (
        .clk (clk), .rst (rst),
        .wb_adr_i (s_adr), .wb_dat_i (s_dat_w), .wb_sel_i (s_sel),
        .wb_we_i (s_we), .wb_stb_i (boot_stb), .wb_cyc_i (s_cyc),
        .wb_dat_o (boot_dat), .wb_ack_o (boot_ack)
    );

    // ------------------------------------------------------------------------
    // Slave: UART
    // ------------------------------------------------------------------------
    wire uart_irq;      // -> PLIC source 1

    uart_wb_slave uart (
        .clk (clk), .rst (rst),
        .wb_adr_i (s_adr), .wb_dat_i (s_dat_w), .wb_sel_i (s_sel),
        .wb_we_i (s_we), .wb_stb_i (uart_stb), .wb_cyc_i (s_cyc),
        .wb_dat_o (uart_dat), .wb_ack_o (uart_ack),
        .irq (uart_irq), .uart_tx (uart_tx), .uart_rx (uart_rx)
    );

    // ------------------------------------------------------------------------
    // Slave: CLINT. Timer and software interrupts.
    // ------------------------------------------------------------------------
    clint_wb #(.CPU_HZ (FREQ)) clint (
        .clk (clk), .rst (rst),
        .wb_adr_i (s_adr), .wb_dat_i (s_dat_w), .wb_sel_i (s_sel),
        .wb_we_i (s_we), .wb_stb_i (clint_stb), .wb_cyc_i (s_cyc),
        .wb_dat_o (clint_dat), .wb_ack_o (clint_ack),
        .msip (irq_soft), .mtip (irq_timer), .mtime_o (mtime)
    );

    // ------------------------------------------------------------------------
    // Slave: LED brightness. Our own device - see led_pwm_wb.v.
    // ------------------------------------------------------------------------
    wire [`PLIC_SW_LINES-1:0] swirq;

    led_pwm_wb #(
        .CHANNELS (`LED_CHANNELS),
        .SW_LINES (`PLIC_SW_LINES)
    ) leds (
        .clk (clk), .rst (rst),
        .wb_adr_i (s_adr), .wb_dat_i (s_dat_w), .wb_sel_i (s_sel),
        .wb_we_i (s_we), .wb_stb_i (led_stb), .wb_cyc_i (s_cyc),
        .wb_dat_o (led_dat), .wb_ack_o (led_ack),
        .dbg_word (fl_status),
        .pwm_out (led_pwm), .swirq_out (swirq)
    );

    // ------------------------------------------------------------------------
    // Slave: SD card, SPI mode.
    //
    // The initial clock divider has to be right out of reset: an SD card must
    // see between 100 and 400 kHz until it has been initialised, and only then
    // may the host speed up. The divider is (FREQ / SPI_HZ) - 1, so it moves
    // with the system clock rather than being a constant that quietly becomes
    // wrong the next time the clock changes.
    // ------------------------------------------------------------------------
    localparam integer SD_INIT_HZ  = 200_000;
    localparam integer SD_INIT_DIV = (FREQ / SD_INIT_HZ) - 1;

    wire sd_irq;

    sdspi_wb #(
        .INITIAL_CLKDIV (SD_INIT_DIV[7:0])
    ) sdcard (
        .clk (clk), .rst (rst),
        .wb_adr_i (s_adr), .wb_dat_i (s_dat_w), .wb_sel_i (s_sel),
        .wb_we_i (s_we), .wb_stb_i (sd_stb), .wb_cyc_i (s_cyc),
        .wb_dat_o (sd_dat), .wb_ack_o (sd_ack),
        .sd_cs_n (sd_cs_n), .sd_sck (sd_sck),
        .sd_mosi (sd_mosi), .sd_miso (sd_miso),
        .irq (sd_irq)
    );

    // ------------------------------------------------------------------------
    // Slave: PLIC. External interrupt routing.
    //
    // Source 0 is tied low because the specification says it does not exist.
    // Sources above the ones we use are tied low too - an unconnected source
    // would be a free-running interrupt.
    // ------------------------------------------------------------------------
    wire [`PLIC_SRCS-1:0] plic_src = {
        {(`PLIC_SRCS - `PLIC_SRC_SD - 1){1'b0}},
        sd_irq,                 // source 6
        swirq,                  // sources 2..5
        uart_irq,               // source 1
        1'b0                    // source 0 does not exist
    };

    plic_wb #(
        .NUM_SRCS     (`PLIC_SRCS),
        .NUM_CTXS     (`PLIC_CTXS),
        .MAX_PRIORITY (`PLIC_MAX_PRIO)
    ) plic (
        .clk (clk), .rst (rst),
        .src_irq (plic_src), .eip (plic_eip),
        .wb_adr_i (s_adr), .wb_dat_i (s_dat_w), .wb_sel_i (s_sel),
        .wb_we_i (s_we), .wb_stb_i (plic_stb), .wb_cyc_i (s_cyc),
        .wb_dat_o (plic_dat), .wb_ack_o (plic_ack)
    );

    // ------------------------------------------------------------------------
    // Slave: SDRAM
    // ------------------------------------------------------------------------
    wire        sd_rd, sd_wr, sd_refresh, sd_data_ready, sd_busy;
    wire [22:0] sd_addr;
    wire [31:0] sd_din, sd_dout;
    wire [3:0]  sd_wmask;

    sdram_wb #(.FREQ (FREQ)) sdram_if (
        .clk (clk), .rst (rst),
        .wb_adr_i (s_adr), .wb_dat_i (s_dat_w), .wb_sel_i (s_sel),
        .wb_we_i (s_we), .wb_stb_i (sdram_stb), .wb_cyc_i (s_cyc),
        .wb_dat_o (sdram_dat), .wb_ack_o (sdram_ack),
        .sd_rd (sd_rd), .sd_wr (sd_wr), .sd_refresh (sd_refresh),
        .sd_addr (sd_addr), .sd_din (sd_din), .sd_wmask (sd_wmask),
        .sd_dout (sd_dout), .sd_data_ready (sd_data_ready), .sd_busy (sd_busy)
    );

    sdram_core #(.FREQ (FREQ)) sdram_ctl (
        .SDRAM_DQ (SDRAM_DQ), .SDRAM_A (SDRAM_A), .SDRAM_BA (SDRAM_BA),
        .SDRAM_nCS (SDRAM_nCS), .SDRAM_nWE (SDRAM_nWE),
        .SDRAM_nRAS (SDRAM_nRAS), .SDRAM_nCAS (SDRAM_nCAS),
        .SDRAM_CLK (SDRAM_CLK), .SDRAM_CKE (SDRAM_CKE), .SDRAM_DQM (SDRAM_DQM),
        .clk (clk), .clk_sdram (clk_sdram), .resetn (~rst),
        .rd (sd_rd), .wr (sd_wr), .refresh (sd_refresh),
        .addr (sd_addr), .din32 (sd_din), .wmask (sd_wmask),
        .dout32 (sd_dout), .data_ready (sd_data_ready), .busy (sd_busy)
    );

endmodule
