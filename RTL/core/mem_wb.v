`include "definitions.vh"

// =============================================================================
// Stage 3: Memory access and Writeback.
//
// Turns the pipelined load/store request into a word-aligned, byte-strobed
// memory transaction, extends load data according to funct3, and selects the
// value written back to the register file.
//
// The write port is driven combinationally so that the register file's internal
// bypass hands the value straight to the instruction sitting in Decode/Execute.
//
// This stage also owns the RV32A atomics, for one reason: the read-modify-write
// has to happen where the memory port is. The pattern is the same as the CSR
// sequencer - a multi-cycle operation with the pipeline frozen around it, so
// nothing can observe the half-finished state - but a CSR read-modify-write
// takes a known two cycles while a memory one takes as long as the bus does.
// So this sequencer waits on `dmem_ready` twice rather than counting cycles.
//
// The pipeline freeze comes free: `mem_stall` already holds every stage, and
// every other mechanism that has to stay out of the way is already keyed off it
// - the control unit will not take a trap or an interrupt, and the RV32M unit
// will not start, while mem_stall is high.
// =============================================================================
module mem_wb (
    input  wire clk,
    input  wire rst,

    // --- From EX/MEM ---
    input  wire [`BUS_WIDTH-1:0]      alu_result,   // load/store address, or result
    input  wire [`BUS_WIDTH-1:0]      store_data,   // rs2
    input  wire [`BUS_WIDTH-1:0]      link_pc,
    input  wire [`REG_ADDR_WIDTH-1:0] rd_addr,
    input  wire                       reg_we_in,
    input  wire                       mem_we_in,
    input  wire                       mem_re_in,
    input  wire [1:0]                 wb_sel,
    input  wire [2:0]                 funct3,
    input  wire                       is_atomic_in, // RV32A
    input  wire [4:0]                 amo_funct5,   // which atomic
    input  wire                       valid_in,

    // --- Reservation control ---
    input  wire                       trap_take,    // clear the reservation

    // --- Data memory port ---
    output wire [`BUS_WIDTH-1:0] dmem_addr,         // word aligned
    output reg  [`BUS_WIDTH-1:0] dmem_wdata,        // shifted into its byte lane
    output reg  [3:0]            dmem_wstrb,
    output wire                  dmem_we,
    output wire                  dmem_re,
    output wire                  dmem_lock,         // hold the bus across an RMW
    input  wire [`BUS_WIDTH-1:0] dmem_rdata,        // whole word, combinational
    input  wire                  dmem_ready,

    // --- Register file write port ---
    output wire                       reg_we,
    output wire [`REG_ADDR_WIDTH-1:0] reg_waddr,
    output reg  [`BUS_WIDTH-1:0]      reg_wdata,

    // --- To the control unit ---
    output wire mem_stall,                          // memory busy, freeze the pipe

    // --- Observation, for the testbench ---
    output wire dbg_amo_read,                       // RMW read phase active
    output wire dbg_amo_write,                      // RMW write phase active
    output wire dbg_resv_valid
);

    wire [1:0] byte_off = alu_result[1:0];

    assign dmem_addr = {alu_result[`BUS_WIDTH-1:2], 2'b00};

    // ------------------------------------------------------------------------
    // Atomic decode
    // ------------------------------------------------------------------------
    wire is_atomic = is_atomic_in & valid_in;
    wire is_lr     = is_atomic & (amo_funct5 == `F5_LR);
    wire is_sc     = is_atomic & (amo_funct5 == `F5_SC);
    wire is_amo    = is_atomic & ~is_lr & ~is_sc;   // a fetch-and-op

    // ------------------------------------------------------------------------
    // Load reservation.
    //
    // One reservation, holding a word address - the smallest set the spec
    // allows, and the whole set for a machine with no cache lines to speak of.
    // The spec permits an arbitrarily large set provided it covers the
    // addressed word, so this is the conservative end of the range: fewer
    // spurious failures, and the eventuality guarantee for constrained loops
    // is trivially met because nothing else in this machine writes memory.
    //
    // Cleared by:
    //   any SC          the spec is explicit - success or failure, an SC
    //                   invalidates the reservation, which is what makes "an SC
    //                   can only pair with the most recent LR" true.
    //   a store to it   not required on a single-hart machine, since only
    //                   another hart's store must fail an SC. Done anyway
    //                   because it costs one comparator and matches what an
    //                   implementation tracking a cache line would do. It
    //                   cannot break a constrained loop, which is forbidden
    //                   from containing stores between the LR and the SC.
    //   a trap          also not required - the spec puts that burden on
    //                   software, which is supposed to SC to a scratch word on
    //                   a context switch. Done anyway because a preempted
    //                   sequence resuming into a *successful* SC is a data race
    //                   that would be very hard to find, and "H traps" is
    //                   already a permitted way for a constrained loop to end.
    // ------------------------------------------------------------------------
    reg                    resv_valid;
    reg [`BUS_WIDTH-3:0]   resv_addr;      // word address, bits 31:2

    wire [`BUS_WIDTH-3:0]  this_word = alu_result[`BUS_WIDTH-1:2];
    wire resv_hit = resv_valid && (resv_addr == this_word);

    // An SC stores only if it still holds the reservation for this word. The
    // verdict is taken in the sequencer's first phase and used in its second,
    // so nothing on the bus depends on the comparator.
    wire sc_fail = is_sc & ~sc_go_q;

    // ------------------------------------------------------------------------
    // Atomic sequencer.
    //
    // Two phases, and both LR/SC and the AMOs go through it:
    //
    //   AM_ARM    an AMO issues its read and latches the old value and the
    //             modified value; an SC evaluates the reservation and latches
    //             the verdict. No bus write happens in this phase.
    //   AM_WRITE  the write goes out, driven entirely from registers, and the
    //             instruction retires when it is acknowledged.
    //
    // This is Wishbone's RMW cycle (spec section 3.4) seen from the core side:
    // CYC held across both halves, STB dropped in between as a master wait
    // state, WE flipped for the second transfer. The bridge holds CYC and
    // asserts LOCK so the arbiter cannot hand the bus to anyone else in the
    // gap - which is what makes the operation indivisible rather than merely
    // consecutive.
    //
    // An SC does not need two phases to be *correct* - it did the reservation
    // check and the store in one cycle, and every test passed. It needs them to
    // be fast. The check is a 30-bit compare against the address register, and
    // its result gates the bus write enable, so it sat in front of the entire
    // forward bus path: address -> compare -> WE -> arbiter -> decoder -> slave,
    // and then the read data came back through the writeback mux and the
    // register-file bypass. That one comparator cost 12 levels of logic and took
    // the whole design from 27.5 MHz to 27.013 MHz against a 27 MHz constraint -
    // still closing, with 0.05% to spare, which is not a margin. Registering the
    // verdict costs one cycle on an instruction that is rare and already sits
    // inside a retry loop.
    //
    // The AMO's result is registered for the same reason and from the same
    // place: computing it from `amo_old` would put an adder in front of the bus,
    // so it is computed from the bus read data instead and latched, which ends
    // at a register rather than starting from one.
    //
    // Returning to AM_ARM on completion is safe because completion is exactly
    // the cycle mem_stall falls, and EX/MEM advances or flushes on that edge -
    // so the next cycle holds a different instruction. tb_rv32i asserts that
    // directly, because getting it wrong would silently repeat the operation.
    // ------------------------------------------------------------------------
    localparam AM_ARM   = 1'b0;
    localparam AM_WRITE = 1'b1;

    reg                   am_state;
    reg [`BUS_WIDTH-1:0]  amo_old;        // value read, and the value rd gets
    reg [`BUS_WIDTH-1:0]  amo_wdata;      // the modified value, ready to send
    reg                   sc_go_q;        // the SC's verdict, registered

    // Instructions the sequencer drives. LR is not one of them: it is a plain
    // load that also takes a reservation.
    wire is_seq = is_amo | is_sc;

    wire arm_phase   = is_seq & (am_state == AM_ARM);
    wire write_phase = is_seq & (am_state == AM_WRITE);

    wire amo_read_phase  = is_amo & arm_phase;
    wire amo_write_phase = is_amo & write_phase;

    // A store-conditional that lost its reservation has nothing to send, so its
    // write phase completes without touching the bus at all.
    wire seq_finishing = write_phase &
                         ((is_amo | sc_go_q) ? dmem_ready : 1'b1);

    assign dbg_amo_read   = amo_read_phase;
    assign dbg_amo_write  = amo_write_phase;
    assign dbg_resv_valid = resv_valid;

    // ------------------------------------------------------------------------
    // Bus request.
    //
    // A read for loads, LR, and an AMO's first half. A write for stores, a
    // succeeding SC, and an AMO's second half. A failing SC never touches the
    // bus - it is the one memory instruction in the ISA that can retire without
    // a transaction at all.
    // ------------------------------------------------------------------------
    assign dmem_re = valid_in & mem_re_in & ~write_phase;
    assign dmem_we = valid_in & ((mem_we_in & ~is_sc) |
                                 (write_phase & (is_amo | sc_go_q)));

    // Hold the bus across the two halves.
    //
    // The lock is asserted during the read and dropped for the write, because
    // what it has to say is "another transfer follows in this cycle" - the
    // arbiter releases the grant on a response only when the lock is low, so
    // holding it through the final transfer would keep the bus granted with
    // nothing left to send. That deadlocks the machine: the data port owns a
    // bus it no longer wants and the instruction port can never fetch again.
    //
    // Which is how this was found. The spec's wording matches: the interconnect
    // holds the grant "until the current MASTER negates LOCK_O or CYC_O", so
    // the master is expected to negate it on its last transfer, not after.
    assign dmem_lock = amo_read_phase;

    // For an AMO the stall spans both halves: the read's ACK must not release
    // the pipeline, or the instruction would advance with the write still to do.
    assign mem_stall = is_seq ? ~seq_finishing
                              : ((dmem_we | dmem_re) & ~dmem_ready);

    // ------------------------------------------------------------------------
    // The atomic operation itself. Applied to the value just read and rs2.
    // ------------------------------------------------------------------------
    // Applied to the word just returned by the bus, so the result can be
    // latched at the same edge as the old value. Reading `amo_old` instead
    // would be one cycle later and would put this in front of the bus.
    wire [`BUS_WIDTH-1:0] amo_in = dmem_rdata;

    reg [`BUS_WIDTH-1:0] amo_result;
    always @(*) begin
        case (amo_funct5)
            `F5_AMOSWAP: amo_result = store_data;
            `F5_AMOADD:  amo_result = amo_in + store_data;
            `F5_AMOXOR:  amo_result = amo_in ^ store_data;
            `F5_AMOAND:  amo_result = amo_in & store_data;
            `F5_AMOOR:   amo_result = amo_in | store_data;
            `F5_AMOMIN:  amo_result = ($signed(amo_in) < $signed(store_data))
                                      ? amo_in : store_data;
            `F5_AMOMAX:  amo_result = ($signed(amo_in) > $signed(store_data))
                                      ? amo_in : store_data;
            `F5_AMOMINU: amo_result = (amo_in < store_data) ? amo_in : store_data;
            default:     amo_result = (amo_in > store_data) ? amo_in : store_data;
        endcase
    end

    // ------------------------------------------------------------------------
    // Access size and byte strobes.
    //
    // funct3[1:0] gives the width for loads and stores alike: 00 byte,
    // 01 halfword, 10 word. That matters because the strobe is not only a
    // store enable - on a read it is Wishbone's SEL, which tells the slave
    // "where valid data is expected". A byte-addressed peripheral uses it to
    // pick a register, so deriving it from the store encodings alone leaves
    // LBU (100) and LHU (101) falling through to a full-word strobe and
    // reading the wrong register.
    //
    // The atomics are all word accesses (funct3 = 010), so they land in the
    // default arm; only the AMO write data differs, and it bypasses the shifter
    // because the operation already produced a whole aligned word.
    // ------------------------------------------------------------------------
    always @(*) begin
        case (funct3[1:0])
            2'b00: begin                         // LB, LBU, SB
                dmem_wstrb = 4'b0001 << byte_off;
                dmem_wdata = store_data << {byte_off, 3'b000};
            end
            2'b01: begin                         // LH, LHU, SH
                dmem_wstrb = 4'b0011 << {byte_off[1], 1'b0};
                dmem_wdata = store_data << {byte_off[1], 4'b0000};
            end
            default: begin                       // LW, SW, and every atomic
                dmem_wstrb = 4'b1111;
                dmem_wdata = amo_write_phase ? amo_wdata : store_data;
            end
        endcase
    end

    // ------------------------------------------------------------------------
    // Sequencer and reservation state
    // ------------------------------------------------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            am_state   <= AM_ARM;
            amo_old    <= {`BUS_WIDTH{1'b0}};
            amo_wdata  <= {`BUS_WIDTH{1'b0}};
            sc_go_q    <= 1'b0;
            resv_valid <= 1'b0;
            resv_addr  <= {(`BUS_WIDTH-2){1'b0}};
        end
        else begin
            // --- sequencer phases ---
            case (am_state)
                AM_ARM: begin
                    if (amo_read_phase && dmem_ready) begin
                        amo_old   <= dmem_rdata;
                        amo_wdata <= amo_result;
                        am_state  <= AM_WRITE;
                    end
                    // An SC issues nothing here; it only decides.
                    if (is_sc) begin
                        sc_go_q  <= resv_hit;
                        am_state <= AM_WRITE;
                    end
                end

                AM_WRITE:
                    if (seq_finishing) am_state <= AM_ARM;

                default: am_state <= AM_ARM;
            endcase

            // --- reservation ---
            // Ordered so that an LR taking a reservation wins over the same
            // instruction's own address matching a stale one.
            if (trap_take) begin
                resv_valid <= 1'b0;
            end
            else if (is_sc && !mem_stall) begin
                // Any SC clears it, whether it stored or not - but only once
                // the SC is finished.
                //
                // Clearing it on the first cycle instead is wrong in a way that
                // zero-latency memory cannot show. `sc_go` is what drives the
                // bus write, and it is derived from the reservation; clear the
                // reservation while the store is still in flight and STB drops
                // mid-transaction. Wishbone requires the master to hold its
                // outputs from STB until ACK, so the store is lost, and the
                // instruction then retires reporting failure because the
                // reservation it was checking has gone. A succeeding SC turns
                // into a failing SC that also loses the write.
                //
                // Over the bus this is immediate and total; on the bare core
                // ready is high in the same cycle, so the whole window does not
                // exist. It is the third bug of this exact shape in the project.
                resv_valid <= 1'b0;
            end
            else if (is_lr && dmem_ready) begin
                resv_valid <= 1'b1;
                resv_addr  <= this_word;
            end
            else if (dmem_we && dmem_ready && resv_hit) begin
                // A plain store, or an AMO's write half, landing on the
                // reserved word.
                resv_valid <= 1'b0;
            end
        end
    end

    // ------------------------------------------------------------------------
    // Load path: pick the lane, then sign- or zero-extend
    // ------------------------------------------------------------------------
    wire [`BUS_WIDTH-1:0] rdata_shifted_b = dmem_rdata >> {byte_off,    3'b000};
    wire [`BUS_WIDTH-1:0] rdata_shifted_h = dmem_rdata >> {byte_off[1], 4'b0000};
    wire [7:0]  load_byte = rdata_shifted_b[7:0];
    wire [15:0] load_half = rdata_shifted_h[15:0];

    reg [`BUS_WIDTH-1:0] load_extended;
    always @(*) begin
        case (funct3)
            `F3_LB:  load_extended = {{24{load_byte[7]}},  load_byte};
            `F3_LH:  load_extended = {{16{load_half[15]}}, load_half};
            `F3_LBU: load_extended = {24'b0, load_byte};
            `F3_LHU: load_extended = {16'b0, load_half};
            default: load_extended = dmem_rdata;   // F3_LW, LR.W
        endcase
    end

    // ------------------------------------------------------------------------
    // Writeback multiplexer.
    //
    // The two atomics that do not write back a bus value:
    //   AMO  rd gets the value read *before* the modify, and by the cycle this
    //        retires the bus is carrying the write, so it has to come from the
    //        latch rather than from dmem_rdata.
    //   SC   rd gets 0 on success, non-zero on failure. The spec reserves the
    //        code 1 for "unspecified failure" precisely so an implementation
    //        can produce it from the multiplexer it already has for SLT.
    // ------------------------------------------------------------------------
    assign reg_we    = reg_we_in & valid_in & ~mem_stall;
    assign reg_waddr = rd_addr;

    always @(*) begin
        if (is_amo)     reg_wdata = amo_old;
        else if (is_sc) reg_wdata = {{(`BUS_WIDTH-1){1'b0}}, sc_fail};
        else begin
            case (wb_sel)
                `WB_MEM: reg_wdata = load_extended;
                `WB_PC4: reg_wdata = link_pc;
                default: reg_wdata = alu_result;        // WB_ALU
            endcase
        end
    end

endmodule
