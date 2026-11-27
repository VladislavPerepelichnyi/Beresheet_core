`include "definitions.vh"
`include "wb_defines.vh"

// =============================================================================
// Beresheet SoC: RV32IMA core, L1 caches, Wishbone interconnect, peripherals.
//
// Board independent; instantiated by the FPGA top level and by the simulation
// testbench (with a behavioural SDRAM model), so both run identical logic.
//
//   riscv_core
//     | imem                              | dmem
//   I-cache                             D-cache
//     |                                   |
//   wb_master_bridge (m1)               wb_master_bridge (m0)
//      \                                 /
//       \---------- wb_arbiter ---------/      data port has priority
//                       |
//                  wb_intercon                 decode, return mux, error slave
//                       |
//   boot RAM, CLINT, PLIC, UART, LED/SWIRQ, SD card, SDRAM
//
// Address map (16 MB regions, decoded on addr[31:24]; see wb_defines.vh):
//
//   0x0000_0000  boot RAM, 32 KB        0x1300_0000  Ethernet   (reserved)
//   0x0200_0000  CLINT                  0x1400_0000  HDMI       (reserved)
//   0x0C00_0000  PLIC                   0x1500_0000  USB        (reserved)
//   0x1000_0000  UART 16550             0x1600_0000  PCIe       (reserved)
//   0x1100_0000  LED PWM / SWIRQ        0x8000_0000  SDRAM, 8 MB
//   0x1200_0000  SD card (SPI)
//
// Interrupts: the CLINT drives mip.MSIP/MTIP and the core's `time` CSR. The
// PLIC collects device lines (UART = 1, SWIRQ = 2..5, SD = 6) and drives
// mip.MEIP (context 0) and mip.SEIP (context 1).
// =============================================================================
module soc_wb #(
    parameter FREQ        = `SOC_CLK_HZ,   // system clock, Hz
    parameter BOOT_INIT   = "",            // boot RAM image, word-oriented hex
    parameter DCACHE_SIZE = 4096,          // bytes
    parameter DCACHE_LINE = 64,            // bytes
    parameter ICACHE_SIZE = 4096,
    parameter ICACHE_LINE = 64
)(
    input  wire clk,
    input  wire clk_sdram,            // clk phase shifted, for the SDRAM
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

    // --- LED brightness, active high ---
    output wire [`LED_CHANNELS-1:0] led_pwm,

    // --- Status ---
    output wire        halted,
    output wire        trap_error,
    output wire        ebreak_halt,
    output wire [3:0]  trap_cause,
    output wire        bus_error,       // sticky: some master received ERR
    output wire        decode_miss,     // STB to an unmapped address, now

    // --- Debug and observation, for the testbench; unused on hardware ---
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

    // Cache and TLB event counters
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
    output wire [31:0]                dbg_itlb_faults
);

    // ------------------------------------------------------------------------
    // Nets shared between blocks. Every net is declared before its first use:
    // an implicitly declared net simulates correctly in Verilator but is left
    // undriven by Gowin synthesis.
    // ------------------------------------------------------------------------
    wire        irq_soft, irq_timer;
    wire [63:0] mtime;
    wire [`PLIC_CTXS-1:0] plic_eip;

    // Core <-> I-cache, I-cache <-> instruction bridge
    wire [`BUS_WIDTH-1:0] imem_addr, imem_rdata;
    wire                  imem_req, imem_ready;
    wire [`BUS_WIDTH-1:0] ibus_addr, ibus_rdata;
    wire                  ibus_re, ibus_ready;

    // Core <-> D-cache, D-cache <-> data bridge
    wire [`BUS_WIDTH-1:0] dmem_addr, dmem_wdata, dmem_rdata;
    wire [3:0]            dmem_wstrb;
    wire                  dmem_we, dmem_re, dmem_ready, dmem_lock;
    wire [`BUS_WIDTH-1:0] dbus_addr, dbus_wdata, dbus_rdata;
    wire [3:0]            dbus_wstrb;
    wire                  dbus_we, dbus_re, dbus_ready, dbus_lock;

    // FENCE.I: core request, per-cache flush handshake, busy back to the core
    wire fence_i_req;
    wire cache_flush_busy;
    wire dcache_flush, icache_flush;
    wire dcache_flush_busy, icache_flush_busy;

    // ------------------------------------------------------------------------
    // Core
    // ------------------------------------------------------------------------
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
        .dbg_dtlb_hits          (dbg_dtlb_hits),
        .dbg_dtlb_misses        (dbg_dtlb_misses),
        .dbg_itlb_hits          (dbg_itlb_hits),
        .dbg_itlb_misses        (dbg_itlb_misses),
        .dbg_dtlb_faults        (dbg_dtlb_faults),
        .dbg_itlb_faults        (dbg_itlb_faults),
        .irq_soft               (irq_soft),
        .irq_timer              (irq_timer),
        .irq_ext                (plic_eip[0]),      // PLIC context 0, M-mode
        .irq_ext_s              (plic_eip[1]),      // PLIC context 1, S-mode
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
    // Only memory is cacheable: SDRAM and the boot RAM. Every other region is a
    // device whose registers have side effects (mtime, UART FIFOs, PLIC claim)
    // and must reach the bus on every access.
    // ------------------------------------------------------------------------
    cache_vipt #(
        .CACHE_SIZE      (DCACHE_SIZE),
        .LINE_SIZE       (DCACHE_LINE),
        .WAY_NUM         (4),
        .CACHEABLE_BASE  (`SDRAM_BASE_ADDR),
        .CACHEABLE_SIZE  (`SDRAM_BYTES),
        .CACHEABLE2_BASE (`BOOT_BASE_ADDR),
        .CACHEABLE2_SIZE (`BOOT_RAM_BYTES)
    ) dcache (
        .clk (clk), .rst (rst),
        // The core presents physical addresses here (translation happens in
        // the core), so index and tag use the same address.
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
        .stat_hits      (dbg_dc_hits),
        .stat_misses    (dbg_dc_misses),
        .stat_evictions (dbg_dc_evictions),
        .stat_uncached  (dbg_dc_uncached)
    );

    // ------------------------------------------------------------------------
    // Instruction cache: the same cache with its write port tied off. With no
    // way to set a dirty bit, the write-back path and its outputs are removed
    // by synthesis.
    // ------------------------------------------------------------------------
    /* verilator lint_off UNUSEDSIGNAL */
    wire [31:0] ic_evictions;
    wire [31:0] ic_dead_wdata;
    wire [3:0]  ic_dead_wstrb;
    wire        ic_dead_we, ic_dead_lock;
    /* verilator lint_on UNUSEDSIGNAL */

    cache_vipt #(
        .CACHE_SIZE      (ICACHE_SIZE),
        .LINE_SIZE       (ICACHE_LINE),
        .WAY_NUM         (4),
        .CACHEABLE_BASE  (`SDRAM_BASE_ADDR),
        .CACHEABLE_SIZE  (`SDRAM_BYTES),
        .CACHEABLE2_BASE (`BOOT_BASE_ADDR),
        .CACHEABLE2_SIZE (`BOOT_RAM_BYTES)
    ) icache (
        .clk (clk), .rst (rst),
        .cpu_addr  (imem_addr),
        .cpu_paddr (imem_addr),
        .cpu_wdata (32'd0),
        .cpu_wstrb (4'b0000),
        .cpu_we    (1'b0),
        .cpu_re    (imem_req),
        .cpu_lock  (1'b0),
        .cpu_rdata (imem_rdata),
        .cpu_ready (imem_ready),
        .flush_req  (icache_flush),
        .flush_busy (icache_flush_busy),
        .mem_addr  (ibus_addr),
        .mem_wdata (ic_dead_wdata),
        .mem_wstrb (ic_dead_wstrb),
        .mem_we    (ic_dead_we),
        .mem_re    (ibus_re),
        .mem_lock  (ic_dead_lock),
        .mem_rdata (ibus_rdata),
        .mem_ready (ibus_ready),
        .stat_hits      (dbg_ic_hits),
        .stat_misses    (dbg_ic_misses),
        .stat_evictions (ic_evictions),
        .stat_uncached  (dbg_ic_uncached)
    );

    // ------------------------------------------------------------------------
    // FENCE.I sequencer
    //
    // FENCE.I writes back the D-cache and invalidates the I-cache. Each cache
    // gets its own request, held until that cache reports busy: the two start
    // whenever each next becomes idle, so waiting for both to be busy at once
    // could re-trigger a cache that had already finished. Once both have
    // accepted, wait for both to go idle.
    // ------------------------------------------------------------------------
    localparam FL_IDLE = 2'd0, FL_GO = 2'd1, FL_WAIT = 2'd2;

    reg [1:0] fl_state;
    reg       fl_busy;
    reg       d_req, i_req;

    assign dcache_flush = d_req;
    assign icache_flush = i_req;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            fl_state <= FL_IDLE;
            fl_busy  <= 1'b0;
            d_req    <= 1'b0;
            i_req    <= 1'b0;
        end else begin
            case (fl_state)
            FL_IDLE: if (fence_i_req) begin
                        fl_state <= FL_GO;
                        fl_busy  <= 1'b1;
                        d_req    <= 1'b1;
                        i_req    <= 1'b1;
                     end
            FL_GO:   begin
                        if (dcache_flush_busy) d_req <= 1'b0;
                        if (icache_flush_busy) i_req <= 1'b0;
                        if (!d_req && !i_req)
                            fl_state <= FL_WAIT;
                     end
            FL_WAIT: if (!(dcache_flush_busy | icache_flush_busy)) begin
                        fl_state <= FL_IDLE;
                        fl_busy  <= 1'b0;
                     end
            default: fl_state <= FL_IDLE;
            endcase
        end
    end

    // Busy in the same cycle as the request: the core samples it immediately,
    // and a low value there would let FENCE.I retire before the flush began.
    assign cache_flush_busy = fl_busy | fence_i_req;

    // ------------------------------------------------------------------------
    // Wishbone masters: m0 = data port, m1 = instruction port
    // ------------------------------------------------------------------------
    wire [`WB_ADDR_WIDTH-1:0] m0_adr, m1_adr;
    wire [`WB_DATA_WIDTH-1:0] m0_dat_w, m1_dat_w, m0_dat_r, m1_dat_r;
    wire [`WB_SEL_WIDTH-1:0]  m0_sel, m1_sel;
    wire                      m0_we, m1_we, m0_stb, m1_stb, m0_cyc, m1_cyc;
    wire                      m0_lock;
    /* verilator lint_off UNUSEDSIGNAL */
    wire                      m1_lock;          // fetches never lock
    /* verilator lint_on UNUSEDSIGNAL */
    wire                      m0_ack, m1_ack, m0_err, m1_err;
    wire                      d_bus_error, i_bus_error;

    assign bus_error = d_bus_error | i_bus_error;

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
        .boot_stb_o  (boot_stb),  .boot_dat_i  (boot_dat),  .boot_ack_i  (boot_ack),
        .uart_stb_o  (uart_stb),  .uart_dat_i  (uart_dat),  .uart_ack_i  (uart_ack),
        .sdram_stb_o (sdram_stb), .sdram_dat_i (sdram_dat), .sdram_ack_i (sdram_ack),
        .clint_stb_o (clint_stb), .clint_dat_i (clint_dat), .clint_ack_i (clint_ack),
        .led_stb_o   (led_stb),   .led_dat_i   (led_dat),   .led_ack_i   (led_ack),
        .plic_stb_o  (plic_stb),  .plic_dat_i  (plic_dat),  .plic_ack_i  (plic_ack),
        .sd_stb_o    (sd_stb),    .sd_dat_i    (sd_dat),    .sd_ack_i    (sd_ack),
        .decode_miss (decode_miss)
    );

    // ------------------------------------------------------------------------
    // Slave: boot RAM. Holds the BIOS with its stack and data, so nothing
    // depends on SDRAM before the BIOS has tested it.
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
    // Slave: UART 16550
    // ------------------------------------------------------------------------
    wire uart_irq;

    uart_wb_slave uart (
        .clk (clk), .rst (rst),
        .wb_adr_i (s_adr), .wb_dat_i (s_dat_w), .wb_sel_i (s_sel),
        .wb_we_i (s_we), .wb_stb_i (uart_stb), .wb_cyc_i (s_cyc),
        .wb_dat_o (uart_dat), .wb_ack_o (uart_ack),
        .irq (uart_irq), .uart_tx (uart_tx), .uart_rx (uart_rx)
    );

    // ------------------------------------------------------------------------
    // Slave: CLINT (machine timer and software interrupt)
    // ------------------------------------------------------------------------
    clint_wb #(.CPU_HZ (FREQ)) clint (
        .clk (clk), .rst (rst),
        .wb_adr_i (s_adr), .wb_dat_i (s_dat_w), .wb_sel_i (s_sel),
        .wb_we_i (s_we), .wb_stb_i (clint_stb), .wb_cyc_i (s_cyc),
        .wb_dat_o (clint_dat), .wb_ack_o (clint_ack),
        .msip (irq_soft), .mtip (irq_timer), .mtime_o (mtime)
    );

    // ------------------------------------------------------------------------
    // Slave: LED PWM and software-triggered interrupt lines
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
        .pwm_out (led_pwm), .swirq_out (swirq)
    );

    // ------------------------------------------------------------------------
    // Slave: SD card, SPI mode
    //
    // The card must be clocked at 100-400 kHz until initialised, so the reset
    // value of the SPI divider is derived from FREQ. Firmware raises the rate
    // after initialisation.
    // ------------------------------------------------------------------------
    // f_sck = FREQ / (2 * (div + 1))
    localparam integer SD_INIT_HZ  = 100_000;
    localparam integer SD_INIT_DIV = (FREQ / (2 * SD_INIT_HZ)) - 1;

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
    // Slave: PLIC
    //
    // Source 0 does not exist and unassigned sources are tied low, so no
    // unconnected input can raise a spurious interrupt.
    // ------------------------------------------------------------------------
    wire [`PLIC_SRCS-1:0] plic_src = {
        {(`PLIC_SRCS - `PLIC_SRC_SD - 1){1'b0}},
        sd_irq,                 // source 6
        swirq,                  // sources 2..5
        uart_irq,               // source 1
        1'b0                    // source 0
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
    // Slave: SDRAM (Wishbone adapter + controller)
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

    // ------------------------------------------------------------------------
    // Reserved peripheral slots
    //
    // Each optional peripheral owns a region in wb_defines.vh and is enabled by
    // `define INCL_PER_<NAME> in soc_config.vh. None is implemented yet, so
    // requesting one fails elaboration on an unresolvable module name rather
    // than silently building a SoC without it. Implementing one means adding
    // its strobe and return terms to wb_intercon, instantiating it here, and
    // wiring its interrupt to a free PLIC source.
    // ------------------------------------------------------------------------
`ifdef INCL_PER_ETHERNET
    INCL_PER_ETHERNET_is_not_implemented_yet u_ethernet ();   // REGION_ETHERNET
`endif
`ifdef INCL_PER_HDMI
    INCL_PER_HDMI_is_not_implemented_yet     u_hdmi ();       // REGION_HDMI
`endif
`ifdef INCL_PER_USB
    INCL_PER_USB_is_not_implemented_yet      u_usb ();        // REGION_USB
`endif
`ifdef INCL_PER_PCIE
    INCL_PER_PCIE_is_not_implemented_yet     u_pcie ();       // REGION_PCIE
`endif

endmodule
