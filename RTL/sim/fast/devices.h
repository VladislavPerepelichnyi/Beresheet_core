// Functional models of the SoC's memory-mapped devices, for the fast simulator.
//
// Same addresses and register behaviour as the RTL in RTL/peripherals, so
// firmware and Linux drive them unchanged:
//
//   0x0200_0000  CLINT   msip, mtimecmp, mtime          (clint_wb.v)
//   0x0C00_0000  PLIC    7 sources, contexts M and S    (plic_wb.v)
//   0x1000_0000  UART    16550, byte registers          (uart16550/)
//   0x1100_0000  LED     duty registers, software IRQs  (led_pwm_wb.v)
//
// Every access is split in two, which is what lets a device with read side
// effects answer in the same cycle without being disturbed by re-evaluation:
//
//   peek()        the value a read returns; no side effects. The harness may
//                 call it several times while the model's combinational
//                 logic settles.
//   commit_read() the side effects of that read (UART RBR pop, IIR clearing
//                 THRE, PLIC claim), applied once, at the clock edge that
//                 completes the access.
//   write()       a store, applied at the clock edge that completes it.
//
// Nothing changes between the last peek() and the commit, so the value
// returned and the side effect always refer to the same state.
//
// Byte strobes: the CLINT, PLIC and LED ignore them and take the whole word,
// exactly as their RTL does (each leaves wb_sel_i unused). The UART is
// byte-addressed: each enabled byte lane is one register.
#pragma once

#include <cstdint>

#include "console.h"

// -----------------------------------------------------------------------------
// CLINT. mtime advances once per 24 core cycles, the SoC's 24 MHz divided to
// the 1 MHz the device tree's timebase-frequency declares, so simulated time
// matches the board's in cycles. The harness calls tick() on that schedule.
// -----------------------------------------------------------------------------
class Clint {
public:
    static constexpr uint32_t kCyclesPerTick = 24;

    uint64_t mtime    = 0;
    uint64_t mtimecmp = ~0ull;     // reset: no timer interrupt pending
    bool     msip     = false;

    bool mtip() const { return mtime >= mtimecmp; }
    void tick() { ++mtime; }

    uint32_t peek(uint32_t off) const {
        switch (off & 0xFFFF) {
        case 0x0000: return msip;
        case 0x4000: return static_cast<uint32_t>(mtimecmp);
        case 0x4004: return static_cast<uint32_t>(mtimecmp >> 32);
        case 0xBFF8: return static_cast<uint32_t>(mtime);
        case 0xBFFC: return static_cast<uint32_t>(mtime >> 32);
        default:     return 0;
        }
    }

    void write(uint32_t off, uint32_t v) {
        switch (off & 0xFFFF) {
        case 0x0000: msip = v & 1; break;
        case 0x4000: mtimecmp = (mtimecmp & ~0xFFFFFFFFull) | v; break;
        case 0x4004: mtimecmp = (mtimecmp & 0xFFFFFFFFull) | (uint64_t(v) << 32); break;
        case 0xBFF8: mtime = (mtime & ~0xFFFFFFFFull) | v; break;
        case 0xBFFC: mtime = (mtime & 0xFFFFFFFFull) | (uint64_t(v) << 32); break;
        default: break;
        }
    }
};

// -----------------------------------------------------------------------------
// PLIC. Sources 1..7 (0 does not exist), priorities 0..7, two contexts:
// 0 = hart 0 M-mode -> irq_ext, 1 = hart 0 S-mode -> irq_ext_s.
//
// Each source has a gateway that forwards one request and then refuses more
// until that source is completed. A level source still asserted at completion
// is forwarded again at once, as the specification requires (and as the RTL
// was fixed to do - see plic_wb.v).
// -----------------------------------------------------------------------------
class Plic {
public:
    static constexpr unsigned kSources = 8;
    static constexpr unsigned kContexts = 2;

    uint8_t priority[kSources] = {};
    uint8_t pending = 0;                  // bit per source
    uint8_t enable[kContexts] = {};
    uint8_t threshold[kContexts] = {};
    uint8_t gw_busy = 0;                  // gateway has forwarded, awaiting completion

    // Highest-priority pending and enabled source; lowest id wins a tie.
    unsigned best(unsigned ctx, unsigned *prio = nullptr) const {
        unsigned id = 0, p = 0;
        for (unsigned s = 1; s < kSources; ++s)
            if ((pending >> s & 1) && (enable[ctx] >> s & 1) && priority[s] > p) {
                p = priority[s];
                id = s;
            }
        if (prio) *prio = p;
        return id;
    }

    bool eip(unsigned ctx) const {
        unsigned p;
        best(ctx, &p);
        return p > threshold[ctx];
    }

    // Gateways: latch a request from every idle source whose line is high.
    void sample(uint8_t levels) {
        const uint8_t raise = levels & ~gw_busy & 0xFE;
        pending |= raise;
        gw_busy |= raise;
    }

    uint32_t peek(uint32_t off) const {
        off &= 0xFFFFFF;
        if (off < 4 * kSources) return priority[off >> 2];
        if (off == 0x1000) return pending;
        if (off >= 0x2000 && off < 0x2000 + 0x80 * kContexts && (off & 0x7F) == 0)
            return enable[(off - 0x2000) >> 7];
        unsigned ctx;
        if (context_reg(off, ctx))
            return (off & 4) ? best(ctx) : threshold[ctx];
        return 0;
    }

    void commit_read(uint32_t off) {
        unsigned ctx;
        off &= 0xFFFFFF;
        if (context_reg(off, ctx) && (off & 4)) {
            const unsigned id = best(ctx);
            if (id) pending &= static_cast<uint8_t>(~(1u << id));
        }
    }

    void write(uint32_t off, uint32_t v) {
        off &= 0xFFFFFF;
        unsigned ctx;
        if (off < 4 * kSources) {
            if (off >> 2) priority[off >> 2] = v & 7;
        } else if (off >= 0x2000 && off < 0x2000 + 0x80 * kContexts && (off & 0x7F) == 0) {
            enable[(off - 0x2000) >> 7] = v & 0xFE;
        } else if (context_reg(off, ctx)) {
            if (!(off & 4)) {
                threshold[ctx] = v & 7;
            } else {
                // Completion: releases the gateway if it names a source that
                // is enabled on this context; otherwise silently ignored.
                const unsigned id = v & 7;
                if (id && (enable[ctx] >> id & 1)) gw_busy &= static_cast<uint8_t>(~(1u << id));
            }
        }
    }

private:
    // Threshold (+0) or claim/complete (+4) of a context. Only the first two
    // words of each 4 KiB context block exist.
    static bool context_reg(uint32_t off, unsigned &ctx) {
        if (off < 0x200000 || off >= 0x200000 + 0x1000 * kContexts) return false;
        if ((off & 0xFF8) != 0) return false;
        ctx = (off - 0x200000) >> 12;
        return true;
    }
};

// -----------------------------------------------------------------------------
// UART, 16550 register set at byte offsets 0..7 (reg-shift 0).
//
// Transmission is instantaneous: a byte written to THR goes straight to the
// host console and THR is empty again, so the guest is never slowed to the
// board's 38400 baud. If the host side is backed up the byte is held and THRE
// stays low until it drains - ordinary transmitter back-pressure.
//
// Interrupts, as Linux's 8250 driver uses them:
//   RDA   (IIR 0x04)  IER.ERBFI and the receive FIFO is not empty
//   THRE  (IIR 0x02)  IER.ETBEI and the transmitter became empty. Raised when
//                     THR empties and when ETBEI is enabled while it is empty;
//                     cleared by reading IIR while it is the reported cause,
//                     or by writing THR.
// Line-status and modem-status interrupts never fire: there are no line errors
// and the modem lines are fixed (CTS, DSR, DCD asserted).
//
// Received bytes are fed in by the harness from the console; see feed_rx().
// -----------------------------------------------------------------------------
class Uart {
public:
    explicit Uart(Console &con) : con_(con) {}

    static constexpr unsigned kFifo = 16;

    uint8_t peek_reg(unsigned r) const {
        const bool dlab = lcr_ & 0x80;
        switch (r) {
        case 0: return dlab ? dll_ : (rx_n_ ? rx_[rx_head_] : 0);
        case 1: return dlab ? dlm_ : ier_;
        case 2: return iir();
        case 3: return lcr_;
        case 4: return mcr_;
        case 5: return lsr();
        case 6: return msr();
        case 7: return scr_;
        default: return 0;
        }
    }

    void commit_read_reg(unsigned r) {
        const bool dlab = lcr_ & 0x80;
        if (r == 0 && !dlab && rx_n_) {
            rx_head_ = (rx_head_ + 1) % kFifo;
            --rx_n_;
        } else if (r == 2 && (iir() & 0x0F) == 0x02) {
            thre_irq_ = false;
        }
    }

    void write_reg(unsigned r, uint8_t v) {
        const bool dlab = lcr_ & 0x80;
        switch (r) {
        case 0:
            if (dlab) dll_ = v;
            else transmit(v);
            break;
        case 1:
            if (dlab) {
                dlm_ = v;
            } else {
                const uint8_t was = ier_;
                ier_ = v & 0x0F;
                if (!(was & 0x02) && (ier_ & 0x02) && !tx_held_) thre_irq_ = true;
            }
            break;
        case 2:
            fifo_en_ = v & 0x01;
            if (v & 0x02) rx_n_ = 0;            // clear receive FIFO
            break;
        case 3: lcr_ = v; break;
        case 4: mcr_ = v & 0x1F; break;
        case 7: scr_ = v; break;
        default: break;                         // LSR, MSR: read only
        }
    }

    // Interrupt line to the PLIC.
    bool irq() const { return (iir() & 0x01) == 0; }

    // Room in the receive FIFO, and whether the guest takes receive
    // interrupts (the harness paces piped input on that).
    unsigned rx_space() const { return (fifo_en_ ? kFifo : 1) - rx_n_; }
    bool rx_empty() const { return rx_n_ == 0; }
    bool rx_irq_enabled() const { return ier_ & 0x01; }

    void feed_rx(uint8_t c) {
        if (rx_n_ < kFifo) {
            rx_[(rx_head_ + rx_n_) % kFifo] = c;
            ++rx_n_;
        }
    }

    // Retries a byte the console could not take earlier. True if THR emptied.
    bool retry_tx() {
        if (!tx_held_ || !con_.tx_put(tx_hold_)) return false;
        tx_held_ = false;
        thre_irq_ = true;
        return true;
    }

private:
    void transmit(uint8_t c) {
        if (mcr_ & 0x10) {                      // loopback: straight back in
            feed_rx(c);
            thre_irq_ = true;
            return;
        }
        if (tx_held_) return;                   // THR was full; the byte is lost, as on hardware
        if (con_.tx_put(c)) {
            thre_irq_ = true;
        } else {
            tx_hold_ = c;
            tx_held_ = true;
            thre_irq_ = false;
        }
    }

    uint8_t iir() const {
        uint8_t id = 0x01;                      // no interrupt pending
        if ((ier_ & 0x01) && rx_n_)          id = 0x04;
        else if ((ier_ & 0x02) && thre_irq_) id = 0x02;
        return id | (fifo_en_ ? 0xC0 : 0x00);
    }

    uint8_t lsr() const {
        uint8_t v = rx_n_ ? 0x01 : 0x00;        // DR
        if (!tx_held_) v |= 0x60;               // THRE | TEMT
        return v;
    }

    uint8_t msr() const {
        if (mcr_ & 0x10)                        // loopback: outputs feed inputs
            return static_cast<uint8_t>(((mcr_ & 0x02) << 3) | ((mcr_ & 0x01) << 5) |
                                        ((mcr_ & 0x04) << 4) | ((mcr_ & 0x08) << 4));
        return 0xB0;                            // DCD | DSR | CTS
    }

    Console &con_;
    uint8_t ier_ = 0, lcr_ = 0, mcr_ = 0, scr_ = 0, dll_ = 0, dlm_ = 0;
    bool fifo_en_ = false;
    bool thre_irq_ = false;
    bool tx_held_ = false;
    uint8_t tx_hold_ = 0;
    uint8_t rx_[kFifo] = {};
    unsigned rx_head_ = 0, rx_n_ = 0;
};

// -----------------------------------------------------------------------------
// LED block. Duty registers are stored and otherwise ignored; the SWIRQ
// register (+0x20) drives PLIC sources 2..5, which is how the PLIC tests raise
// an external interrupt on demand. +0x30 is the SoC's debug word, read as 0.
// -----------------------------------------------------------------------------
class Led {
public:
    uint8_t duty[6] = {};
    uint8_t swirq = 0;

    uint32_t peek(uint32_t off) const {
        const unsigned idx = (off >> 2) & 0xF;
        if (idx < 6) return duty[idx];
        if (idx == 8) return swirq;
        return 0;
    }

    void write(uint32_t off, uint32_t v) {
        const unsigned idx = (off >> 2) & 0xF;
        if (idx < 6) duty[idx] = static_cast<uint8_t>(v);
        else if (idx == 8) swirq = v & 0xF;
    }
};

// -----------------------------------------------------------------------------
// The device bus: decode on address[31:24] like wb_intercon.v, and the
// interrupt wiring from soc_wb.v.
// -----------------------------------------------------------------------------
class Devices {
public:
    explicit Devices(Console &con) : uart(con) {}

    Clint clint;
    Plic  plic;
    Uart  uart;
    Led   led;

    // Interrupt outputs to the core, recomputed by update_irqs().
    bool irq_soft = false, irq_timer = false, irq_ext = false, irq_ext_s = false;

    enum Region : uint8_t { kNone, kClint, kPlic, kUart, kLed };

    static Region decode(uint32_t addr) {
        switch (addr >> 24) {
        case 0x02: return kClint;
        case 0x0C: return kPlic;
        case 0x10: return (addr & 0xFFFFFF) < 0x20 ? kUart : kNone;
        case 0x11: return (addr & 0xFFFFFF) < 0x40 ? kLed : kNone;
        default:   return kNone;
        }
    }

    uint32_t peek(Region r, uint32_t addr, unsigned strb) const {
        switch (r) {
        case kClint: return clint.peek(addr);
        case kPlic:  return plic.peek(addr);
        case kLed:   return led.peek(addr);
        case kUart: {
            uint32_t v = 0;
            for (unsigned lane = 0; lane < 4; ++lane)
                if (strb >> lane & 1)
                    v |= uint32_t(uart.peek_reg((addr & 0x1C) + lane)) << (8 * lane);
            return v;
        }
        default: return 0;
        }
    }

    void commit_read(Region r, uint32_t addr, unsigned strb) {
        if (r == kPlic) {
            plic.commit_read(addr);
        } else if (r == kUart) {
            for (unsigned lane = 0; lane < 4; ++lane)
                if (strb >> lane & 1) uart.commit_read_reg((addr & 0x1C) + lane);
        } else {
            return;
        }
        update_irqs();
    }

    void write(Region r, uint32_t addr, uint32_t data, unsigned strb) {
        switch (r) {
        case kClint: clint.write(addr, data); break;
        case kPlic:  plic.write(addr, data); break;
        case kLed:   led.write(addr, data); break;
        case kUart:
            for (unsigned lane = 0; lane < 4; ++lane)
                if (strb >> lane & 1)
                    uart.write_reg((addr & 0x1C) + lane, static_cast<uint8_t>(data >> (8 * lane)));
            break;
        default: return;
        }
        update_irqs();
    }

    // PLIC source lines, as wired in soc_wb.v: 1 UART, 2..5 software lines,
    // 6 SD card (absent here), 7 unused.
    uint8_t source_levels() const {
        return static_cast<uint8_t>((uart.irq() ? 0x02 : 0) | (led.swirq << 2));
    }

    void update_irqs() {
        plic.sample(source_levels());
        irq_soft  = clint.msip;
        irq_timer = clint.mtip();
        irq_ext   = plic.eip(0);
        irq_ext_s = plic.eip(1);
    }
};
