// =============================================================================
// fast_sim - the Beresheet core on its own, with memory and devices in C++.
//
// Verilates RTL/core/riscv_core.v (pipeline, CSRs, MMU and TLBs, mul/div) and
// nothing else: no caches, no Wishbone bus, no RTL peripherals. Memory is a
// pair of host arrays at the SoC addresses and the devices are functional
// models (devices.h), so the binaries that run on the SoC run here too, at a
// few million cycles per second instead of tens of thousands.
//
// Usage: fast_sim [options] <program>
//
//   <program> is one of
//     an ELF       loaded by its program headers; a non-zero entry point gets
//                  a jump stub at the reset vector
//     a raw image  loaded at --load-addr (default 0x0, the reset vector)
//     a boot descriptor (BOOT.TXT, the board BIOS's format)
//                  every image loaded, then OpenSBI entered as the BIOS does
//
//   --max-cycles N    stop after N cycles (0 = never, the default)
//   --expect-trap N   pass only if the program halts on a trap with mcause N
//   --load-addr A     load address for a raw image
//   --check           per-cycle invariant checks (default for ELF/raw images)
//   --no-check        disable them (default for boot descriptors)
//   --trace           print every retired instruction to stderr
//   --quiet           print the run summary only on failure
//
// End of a bare-metal run: the test convention of tests/rv32i/test_macros.h. A
// trap taken while mtvec is zero halts the core (riscv_core's `halted`); after
// EBREAK, a0 == 0 is PASS and anything else is the id of the failed check.
//
// Exit status:
//   0      PASS, or the user quit
//   1-250  FAIL: the failing check id in a0 (250 for larger ids)
//   251    --max-cycles reached
//   252    an invariant check failed
//   253    halted on a trap other than the expected one (or none was expected)
//   255    the simulator could not start
//
// -----------------------------------------------------------------------------
// Threading model
//
//   simulation thread (main)  owns the Verilated model, guest memory and every
//                             device model. Nothing else touches them, so they
//                             need no locks. It never blocks: console traffic
//                             is a non-blocking push or pop on a ring.
//   input thread              stdin -> rx ring. Blocks in poll()/read().
//   output thread             tx ring -> stdout. Blocks in poll()/write().
//   model threads             only if built with THREADS > 1: Verilator's own
//                             workers, entered and left inside eval() on the
//                             simulation thread. Not the default - for a core
//                             this small the hand-off costs far more than it
//                             parallelises (see mk/fast_sim.mk).
//
// The rings are lock-free single-producer/single-consumer queues
// (spsc_ring.h). The only other shared state is g_quit_requested, an atomic
// flag set by signal handlers and the Ctrl-A x escape. No lock exists, so none
// can be held across a call into the model.
//
// Device bookkeeping is kept off the per-cycle path: the CLINT advances every
// 24 cycles, and the console is polled every 64 of those ticks (1536 cycles,
// about 64 us of simulated time - far faster than any human or 38400 baud).
//
// -----------------------------------------------------------------------------
// One cycle
//
//   1. settle:        clk low; answer the fetch and data requests from memory
//                     or a device peek; eval. Repeat until the request outputs
//                     stop changing (the data port feeds the walkers and the
//                     register-file bypass, so an answer can in principle move
//                     the next request).
//   2. commit:        the access the core will complete at the coming edge is
//                     applied once: a store, or a device read's side effect.
//   3. rising edge:   clk=1, eval; the flops capture the settled values.
//
// Memory answers in the same cycle with ready held high - the zero-latency
// memory the core was designed against. Only the RV32A sequencer ever holds
// stage 3; bus-latency hazards need the full-SoC simulator.
//
// Throughput is about 2.5 Mcycles/s (Linux boot, one host core). Two evals per
// cycle are the minimum with a combinational memory answer, and they are where
// the time goes: profiled, the model is ~95% of it (sequential logic ~60%,
// input-driven combinational logic ~30%), the harness and devices ~5%.
// =============================================================================

#include <cerrno>
#include <chrono>
#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <stdexcept>
#include <string>

#include "Vfast_sim_top.h"
#include "verilated.h"

#include "checks.h"
#include "console.h"
#include "devices.h"
#include "guest_memory.h"

// Set by mk/fast_sim.mk from THREADS; must match Verilator's --threads.
#ifndef FAST_SIM_THREADS
#define FAST_SIM_THREADS 1
#endif

namespace {

enum ExitCode {
    kExitPass = 0,
    kExitFailMaxId = 250,
    kExitMaxCycles = 251,
    kExitInvariant = 252,
    kExitTrap = 253,
    kExitSetup = 255,
};

struct Options {
    std::string program;
    uint64_t max_cycles = 0;
    int expect_trap = -1;
    uint32_t load_addr = 0;
    int check = -1;                 // -1: by program type
    bool trace = false;
    bool quiet = false;
};

[[noreturn]] void usage(const char *msg = nullptr) {
    if (msg) fprintf(stderr, "fast_sim: %s\n", msg);
    fprintf(stderr,
            "usage: fast_sim [--max-cycles N] [--expect-trap N] [--load-addr A]\n"
            "                [--check|--no-check] [--trace] [--quiet] <program>\n"
            "  <program>: ELF, raw image, or boot descriptor (BOOT.TXT)\n");
    exit(kExitSetup);
}

uint64_t parse_number(const char *s, const char *what) {
    char *end = nullptr;
    errno = 0;
    const unsigned long long v = strtoull(s, &end, 0);
    if (errno || !*s || *end) usage((std::string("bad ") + what + ": " + s).c_str());
    return v;
}

Options parse_args(int argc, char **argv) {
    Options o;
    for (int i = 1; i < argc; ++i) {
        const std::string a = argv[i];
        auto value = [&](const char *what) {
            if (i + 1 >= argc) usage((std::string(what) + " needs a value").c_str());
            return parse_number(argv[++i], what);
        };
        if (a == "--max-cycles") o.max_cycles = value("--max-cycles");
        else if (a == "--expect-trap") o.expect_trap = static_cast<int>(value("--expect-trap"));
        else if (a == "--load-addr") o.load_addr = static_cast<uint32_t>(value("--load-addr"));
        else if (a == "--check") o.check = 1;
        else if (a == "--no-check") o.check = 0;
        else if (a == "--trace") o.trace = true;
        else if (a == "--quiet") o.quiet = true;
        else if (a == "-h" || a == "--help") usage();
        else if (a.size() > 1 && a[0] == '-') usage(("unknown option " + a).c_str());
        else if (o.program.empty()) o.program = a;
        else usage("more than one program given");
    }
    if (o.program.empty()) usage("no program given");
    return o;
}

const char *cause_name(unsigned c) {
    switch (c) {
    case 0: return "instruction address misaligned";
    case 1: return "instruction access fault";
    case 2: return "illegal instruction";
    case 3: return "breakpoint";
    case 4: return "load address misaligned";
    case 5: return "load access fault";
    case 6: return "store address misaligned";
    case 7: return "store access fault";
    case 8: return "ecall from U-mode";
    case 9: return "ecall from S-mode";
    case 11: return "ecall from M-mode";
    case 12: return "instruction page fault";
    case 13: return "load page fault";
    case 15: return "store page fault";
    default: return "unknown cause";
    }
}

// -----------------------------------------------------------------------------

enum class StopReason { kHalted, kMaxCycles, kQuit };

class Simulator {
public:
    Simulator(GuestMemory &mem, Console &con, const Options &opt, bool bare_metal)
        : mem_(mem), con_(con), dev_(con), opt_(opt), bare_metal_(bare_metal) {
        ctx_ = std::make_unique<VerilatedContext>();
        // Exactly the threads the model was built for. Left at its default
        // the context sizes its worker pool to the host's CPU count, which for
        // a single-threaded model is a pool of idle threads.
        ctx_->threads(FAST_SIM_THREADS);
        top_ = std::make_unique<Vfast_sim_top>(ctx_.get(), "top");
    }

    ~Simulator() { top_->final(); }

    void reset() {
        Vfast_sim_top &t = *top_;
        t.imem_ready = 1;
        t.dmem_ready = 1;
        t.dbg_reg_addr = 10;          // a0, for the verdict
        t.rst = 1;
        for (int i = 0; i < 4; ++i) {
            t.clk = 1; t.eval();
            t.clk = 0; t.eval();
        }
        t.rst = 0;
        dev_.update_irqs();
        sync_device_inputs();
    }

    template <bool kObserve>
    StopReason run() {
        Vfast_sim_top &t = *top_;
        unsigned tick_countdown = Clint::kCyclesPerTick;
        unsigned poll_countdown = kTicksPerPoll;

        for (;;) {
            // --- settle the same-cycle memory answers ---
            uint32_t ia, da;
            uint8_t dre, dwe, strb, fence;
            Devices::Region region = Devices::kNone;
            for (unsigned iter = 0;; ++iter) {
                ia = t.imem_addr;
                da = t.dmem_addr;
                dre = t.dmem_re;
                dwe = t.dmem_we;
                strb = t.dmem_wstrb;
                fence = t.fence_i_req;

                if (const uint8_t *p = mem_.ram(ia)) t.imem_rdata = GuestMemory::load32(p);
                else t.imem_rdata = unmapped_fetch(ia, t.imem_req);

                region = Devices::kNone;
                if (dre | dwe) {
                    if (const uint8_t *p = mem_.ram(da)) {
                        if (dre) t.dmem_rdata = GuestMemory::load32(p);
                    } else {
                        region = Devices::decode(da);
                        if (dre) t.dmem_rdata = dev_.peek(region, da, strb);
                    }
                }
                // No caches, so FENCE.I has nothing to wait for: answering
                // "busy" exactly while it is requested completes it at once,
                // as the core-only testbench always did.
                t.cache_flush_busy = fence;

                t.eval();
                if (t.imem_addr == ia && t.dmem_addr == da && t.dmem_re == dre &&
                    t.dmem_we == dwe && t.dmem_wstrb == strb && t.fence_i_req == fence)
                    break;
                if (iter == 8) {
                    fprintf(stderr, "fast_sim: memory requests did not settle at cycle %" PRIu64 "\n",
                            cycles_);
                    exit(kExitSetup);
                }
            }

            ++cycles_;
            instret_ += t.retire_valid;
            if constexpr (kObserve) {
                checks_.sample(t, cycles_);
                if (opt_.trace && t.retire_valid)
                    fprintf(stderr, "[%10" PRIu64 "] pc=%08x  insn=%08x\n", cycles_,
                            t.retire_pc, t.retire_instruction);
            }

            // --- commit the access completing at the next edge ---
            if (t.halted) return StopReason::kHalted;   // frozen; nothing completes
            if (dwe) {
                if (uint8_t *p = mem_.ram(da)) GuestMemory::store32(p, t.dmem_wdata, strb);
                else if (region != Devices::kNone) dev_.write(region, da, t.dmem_wdata, strb), sync_device_inputs();
                else unmapped_data(da, true);
            } else if (dre && !mem_.ram(da)) {
                if (region != Devices::kNone) dev_.commit_read(region, da, strb), sync_device_inputs();
                else unmapped_data(da, false);
            }

            // --- periodic device work ---
            if (--tick_countdown == 0) {
                tick_countdown = Clint::kCyclesPerTick;
                dev_.clint.tick();
                if (--poll_countdown == 0) {
                    poll_countdown = kTicksPerPoll;
                    poll_console();
                    if (g_quit_requested.load(std::memory_order_relaxed)) return StopReason::kQuit;
                }
                dev_.update_irqs();
                sync_device_inputs();
                if (opt_.max_cycles && cycles_ >= opt_.max_cycles) return StopReason::kMaxCycles;
            }

            // --- rising edge ---
            t.clk = 1;
            t.eval();
            t.clk = 0;
        }
    }

    // One more edge after the halt, so the last writeback is visible on the
    // debug register port - the old testbench did the same. Nothing is
    // committed: the halted core is frozen and its last access already done.
    void finish_halt() {
        top_->clk = 1; top_->eval();
        top_->clk = 0; top_->eval();
    }

    const Vfast_sim_top &model() const { return *top_; }
    const InvariantChecks &checks() const { return checks_; }
    uint64_t cycles() const { return cycles_; }
    uint64_t instret() const { return instret_; }

private:
    static constexpr unsigned kTicksPerPoll = 64;

    void sync_device_inputs() {
        Vfast_sim_top &t = *top_;
        t.irq_soft = dev_.irq_soft;
        t.irq_timer = dev_.irq_timer;
        t.irq_ext = dev_.irq_ext;
        t.irq_ext_s = dev_.irq_ext_s;
        t.mtime = dev_.clint.mtime;
    }

    // Moves received bytes into the UART and retries a held transmit byte.
    //
    // Typed input goes in as fast as the FIFO takes it. Piped input is paced
    // one byte per poll, and under a boot descriptor it also waits until the
    // guest enables the receive interrupt: Linux clears the FIFO when it opens
    // the port, so anything delivered earlier would be lost, and scripted input
    // is normally written long before the shell is up.
    void poll_console() {
        Uart &u = dev_.uart;
        u.retry_tx();
        if (!con_.rx_ready()) return;
        if (con_.stdin_is_tty()) {
            uint8_t c;
            for (unsigned room = u.rx_space(); room && con_.rx_get(c); --room) u.feed_rx(c);
        } else if (u.rx_empty() && (bare_metal_ || u.rx_irq_enabled())) {
            uint8_t c;
            if (con_.rx_get(c)) u.feed_rx(c);
        }
    }

    uint32_t unmapped_fetch(uint32_t addr, bool requested) {
        if (requested && !warned_fetch_) {
            warned_fetch_ = true;
            fprintf(stderr, "fast_sim: warning: fetch from unmapped address %08x reads 0 "
                            "(reported once)\n", addr);
        }
        return 0;
    }

    void unmapped_data(uint32_t addr, bool write) {
        bool &warned = write ? warned_store_ : warned_load_;
        if (warned) return;
        warned = true;
        fprintf(stderr, "fast_sim: warning: %s unmapped address %08x at cycle %" PRIu64
                        ", pc near %08x (%s; reported once)\n",
                write ? "store to" : "load from", addr, cycles_, top_->retire_pc,
                write ? "ignored" : "reads 0");
    }

    GuestMemory &mem_;
    Console &con_;
    Devices dev_;
    const Options &opt_;
    const bool bare_metal_;
    std::unique_ptr<VerilatedContext> ctx_;
    std::unique_ptr<Vfast_sim_top> top_;
    InvariantChecks checks_;
    uint64_t cycles_ = 0, instret_ = 0;
    bool warned_fetch_ = false, warned_load_ = false, warned_store_ = false;
};

}  // namespace

// -----------------------------------------------------------------------------

int main(int argc, char **argv) {
    const Options opt = parse_args(argc, argv);

    GuestMemory mem;
    bool bare_metal = true;
    std::string what;
    try {
        if (GuestMemory::is_boot_descriptor(opt.program)) {
            bare_metal = false;
            what = "boot descriptor:" + mem.load_boot_descriptor(opt.program);
        } else {
            FILE *f = fopen(opt.program.c_str(), "rb");
            if (!f) throw std::runtime_error("cannot open " + opt.program + ": " + strerror(errno));
            unsigned char magic[4] = {};
            const size_t n = fread(magic, 1, 4, f);
            fclose(f);
            if (n == 4 && memcmp(magic, "\x7f" "ELF", 4) == 0) {
                const uint32_t entry = mem.load_elf(opt.program);
                if (entry != 0) mem.write_reset_jump(entry);
                char buf[64];
                snprintf(buf, sizeof buf, "ELF, entry %08x", entry);
                what = buf;
            } else {
                mem.load_raw(opt.program, opt.load_addr);
                char buf[64];
                snprintf(buf, sizeof buf, "raw image at %08x", opt.load_addr);
                what = buf;
                if (opt.load_addr != 0) mem.write_reset_jump(opt.load_addr);
            }
        }
    } catch (const std::exception &e) {
        fprintf(stderr, "fast_sim: %s\n", e.what());
        return kExitSetup;
    }

    const bool observe = opt.check >= 0 ? opt.check : bare_metal;
    if (!opt.quiet) fprintf(stderr, "fast_sim: %s (%s)\n", opt.program.c_str(), what.c_str());

    Console con;
    con.start(/*read_stdin=*/true);

    Simulator sim(mem, con, opt, bare_metal);
    sim.reset();

    const auto t0 = std::chrono::steady_clock::now();
    const StopReason why = (observe || opt.trace) ? sim.run<true>() : sim.run<false>();
    const double secs =
        std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();

    if (why == StopReason::kHalted) sim.finish_halt();
    con.stop();     // flush guest output and restore the terminal before reporting

    // --- verdict ---
    const Vfast_sim_top &t = sim.model();
    const uint32_t a0 = t.dbg_reg_data;
    int code = kExitPass;
    std::string verdict;
    char line[160];

    switch (why) {
    case StopReason::kQuit:
        verdict = "stopped by user";
        break;
    case StopReason::kMaxCycles:
        verdict = "FAIL: --max-cycles reached";
        code = kExitMaxCycles;
        break;
    case StopReason::kHalted:
        if (t.trap_error) {
            snprintf(line, sizeof line, "halted on trap, mcause=%u (%s), mepc=%08x mtval=%08x",
                     t.trap_cause, cause_name(t.trap_cause), t.dbg_mepc, t.dbg_mtval);
            verdict = line;
            if (opt.expect_trap >= 0 && static_cast<unsigned>(opt.expect_trap) == t.trap_cause)
                verdict += " -> PASS (expected)";
            else
                verdict += " -> FAIL", code = kExitTrap;
        } else {
            snprintf(line, sizeof line, "halted on %s, a0=0x%08x (%u)",
                     t.ebreak_halt ? "ebreak" : "ecall", a0, a0);
            verdict = line;
            if (opt.expect_trap >= 0) {
                verdict += " -> FAIL (expected a trap)";
                code = kExitTrap;
            } else if (a0 != 0) {
                verdict += " -> FAIL";
                code = a0 < kExitFailMaxId ? static_cast<int>(a0) : kExitFailMaxId;
            } else {
                verdict += " -> PASS";
            }
        }
        break;
    }
    if (observe && !sim.checks().ok() && code == kExitPass) {
        verdict += " (but an invariant failed)";
        code = kExitInvariant;
    }

    if (!opt.quiet || code != kExitPass) {
        const double cps = secs > 0 ? sim.cycles() / secs : 0;
        fprintf(stderr, "fast_sim: %s\n", verdict.c_str());
        fprintf(stderr, "  cycles          %" PRIu64 "\n", sim.cycles());
        fprintf(stderr, "  instructions    %" PRIu64, sim.instret());
        if (sim.instret())
            fprintf(stderr, "  (CPI %.3f)", double(sim.cycles()) / double(sim.instret()));
        fputc('\n', stderr);
        fprintf(stderr, "  wall time       %.3f s, %.2f Mcycles/s\n", secs, cps / 1e6);
        if (t.dbg_itlb_hits || t.dbg_itlb_misses || t.dbg_dtlb_hits || t.dbg_dtlb_misses)
            fprintf(stderr, "  TLB             I %u hit / %u miss / %u fault, "
                            "D %u hit / %u miss / %u fault\n",
                    t.dbg_itlb_hits, t.dbg_itlb_misses, t.dbg_itlb_faults,
                    t.dbg_dtlb_hits, t.dbg_dtlb_misses, t.dbg_dtlb_faults);
        if (observe) sim.checks().print_summary(stderr);
    }
    return code;
}
