// Host console for the fast simulator: the guest UART's other end.
//
// Two I/O threads sit between the terminal and the simulation thread, each
// joined to it by a lock-free single-producer/single-consumer ring:
//
//   stdin  -> input thread  -> rx ring -> simulation thread (UART RBR)
//   UART THR -> simulation thread -> tx ring -> output thread -> stdout
//
// The simulation thread only ever pushes or pops a ring, which cannot block.
// A full tx ring is reported to the guest as a busy transmitter (LSR.THRE
// low), the same back-pressure a real UART applies, so nothing is dropped.
#pragma once

#include <atomic>
#include <cstdint>
#include <thread>

#include "spsc_ring.h"

// Set from signal handlers and the Ctrl-A x escape; polled by the simulation
// thread. A lock-free atomic, so it is safe to touch from a handler.
extern std::atomic<bool> g_quit_requested;

class Console {
public:
    // Starts the output thread, and the input thread when `read_stdin` is set.
    // A TTY on stdin is switched to raw mode so every key reaches the guest;
    // the terminal is restored on every exit path, including fatal signals.
    void start(bool read_stdin);

    // Flushes everything the guest transmitted, joins both threads and
    // restores the terminal. Idempotent.
    void stop();

    bool stdin_is_tty() const { return stdin_tty_; }

    // --- Simulation thread only. Neither call blocks. ---

    // Queues a transmitted byte. False when the ring is full.
    bool tx_put(uint8_t byte) {
        if (!tx_.push(byte)) return false;
        // Wake the output thread only if it has gone to sleep. The fence
        // orders the push before the flag read; the output thread does the
        // mirror image (flag store, fence, ring check), so at least one side
        // always sees the other and no byte is left waiting.
        std::atomic_thread_fence(std::memory_order_seq_cst);
        if (tx_sleeping_.load(std::memory_order_relaxed) &&
            tx_sleeping_.exchange(false, std::memory_order_relaxed))
            wake_output();
        return true;
    }

    // Takes one received byte, if any arrived.
    bool rx_get(uint8_t &byte) { return rx_.pop(byte); }
    bool rx_ready() const { return !rx_.empty(); }

private:
    void input_loop();
    void output_loop();
    void wake_output();

    SpscRing<4096>  rx_;
    SpscRing<65536> tx_;
    std::atomic<bool> tx_sleeping_{false};
    std::atomic<bool> stopping_{false};

    std::thread in_thread_, out_thread_;
    int  wake_pipe_[2] = {-1, -1};   // wakes the input thread out of poll()
    int  tx_pipe_[2]   = {-1, -1};   // wakes the output thread out of poll()
    bool stdin_tty_ = false;
    bool started_   = false;
};
