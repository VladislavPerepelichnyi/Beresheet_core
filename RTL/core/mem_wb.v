`include "definitions.vh"

// =============================================================================
// Stage 3: Memory access and Writeback.
//
// Turns the pipelined load/store into a word-aligned, byte-strobed memory
// transaction, extends load data according to funct3, and selects the value
// written back. The register write port is driven combinationally so the
// register file's bypass hands the value straight to Decode/Execute.
//
// The RV32A atomics are sequenced here because the read-modify-write has to
// happen at the memory port. While a sequence runs, mem_stall freezes the whole
// pipeline, and the control unit takes no trap and the RV32M unit does not
// start, so nothing can observe the half-finished state.
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
    // Load reservation: a single word address, the smallest set the spec
    // allows. Cleared by:
    //   any SC          required: success or failure, an SC invalidates it
    //   a store to it   not required on a single hart; costs one comparator
    //   a trap          not required (software should SC on a context switch),
    //                   but stops a preempted LR/SC pair from succeeding
    // ------------------------------------------------------------------------
    reg                    resv_valid;
    reg [`BUS_WIDTH-3:0]   resv_addr;      // word address, bits 31:2

    wire [`BUS_WIDTH-3:0]  this_word = alu_result[`BUS_WIDTH-1:2];
    wire resv_hit = resv_valid && (resv_addr == this_word);

    // ------------------------------------------------------------------------
    // Atomic sequencer, used by SC and the AMOs (LR is a plain load that also
    // takes a reservation):
    //
    //   AM_ARM    an AMO issues its read and latches the old and the modified
    //             value; an SC evaluates the reservation and latches the
    //             verdict. No bus write happens in this phase.
    //   AM_WRITE  the write goes out, driven entirely from registers, and the
    //             instruction retires when it is acknowledged.
    //
    // This is the Wishbone RMW cycle seen from the core: CYC stays asserted and
    // LOCK keeps the arbiter from granting the bus to another master between
    // the two halves.
    //
    // Both the SC verdict and the AMO result are registered so that neither a
    // comparator nor an adder sits in front of the bus write path; this costs
    // one cycle on rare instructions. Returning to AM_ARM on completion is safe
    // because completion is the cycle mem_stall falls, so the next cycle holds
    // a different instruction.
    // ------------------------------------------------------------------------
    localparam AM_ARM   = 1'b0;
    localparam AM_WRITE = 1'b1;

    reg                   am_state;
    reg [`BUS_WIDTH-1:0]  amo_old;        // value read, and the value rd gets
    reg [`BUS_WIDTH-1:0]  amo_wdata;      // the modified value, ready to send
    reg                   sc_go_q;        // the SC's verdict, registered

    // An SC stores only if it still holds the reservation for this word. The
    // verdict is registered in the sequencer's first phase and used in its
    // second, so the comparator is not on the bus path.
    wire sc_fail = is_sc & ~sc_go_q;

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
    // bus.
    // ------------------------------------------------------------------------
    assign dmem_re = valid_in & mem_re_in & ~write_phase;
    assign dmem_we = valid_in & ((mem_we_in & ~is_sc) |
                                 (write_phase & (is_amo | sc_go_q)));

    // LOCK means "another transfer follows", so it is asserted during the read
    // and dropped for the write. The arbiter keeps the grant while LOCK is
    // high; holding it through the final transfer would leave the bus granted
    // to a port with nothing to send and starve instruction fetch.
    assign dmem_lock = amo_read_phase;

    // For an AMO the stall spans both halves: the read's ACK must not release
    // the pipeline, or the instruction would advance with the write still to do.
    assign mem_stall = is_seq ? ~seq_finishing
                              : ((dmem_we | dmem_re) & ~dmem_ready);

    // ------------------------------------------------------------------------
    // The AMO operation, applied to the word returned by the bus and rs2, so
    // the result is latched at the same edge as the old value.
    // ------------------------------------------------------------------------
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
    // funct3[1:0] gives the width for loads and stores alike (00 byte,
    // 01 halfword, 10 word). The strobe is also Wishbone's SEL on reads, which
    // byte-addressed peripherals use to select a register, so LBU/LHU must get
    // narrow strobes too. The atomics are word accesses; only the AMO write
    // data differs, as it is already a whole aligned word.
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
                // Any SC clears it, stored or not, but only once the SC has
                // finished: the bus request must stay stable until ACK.
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
    // Writeback multiplexer. Two atomics do not write back the bus value:
    //   AMO  rd gets the value read before the modify, from the latch, because
    //        the bus is carrying the write by the time the AMO retires.
    //   SC   rd gets 0 on success and 1 on failure.
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
