// Single-producer / single-consumer byte ring, lock-free.
//
// One thread may call push(), one other thread may call pop(); neither ever
// blocks. Each index is written by exactly one side and read by the other, so
// a release store paired with an acquire load is the whole synchronisation:
// the producer publishes a byte by advancing `head_` after writing it, and the
// consumer frees a slot by advancing `tail_` after reading it.
//
// The indices run freely and are masked on use, so full and empty are
// distinguishable without sacrificing a slot. They sit on separate cache lines
// so the two threads do not bounce one line between their cores.
#pragma once

#include <atomic>
#include <cstddef>
#include <cstdint>

template <size_t Capacity>
class SpscRing {
    static_assert(Capacity && (Capacity & (Capacity - 1)) == 0,
                  "capacity must be a power of two");

public:
    // Producer side.
    bool push(uint8_t byte) {
        const uint32_t head = head_.load(std::memory_order_relaxed);
        if (head - tail_.load(std::memory_order_acquire) == Capacity)
            return false;
        buf_[head & (Capacity - 1)] = byte;
        head_.store(head + 1, std::memory_order_release);
        return true;
    }

    // Consumer side.
    bool pop(uint8_t &byte) {
        const uint32_t tail = tail_.load(std::memory_order_relaxed);
        if (head_.load(std::memory_order_acquire) == tail)
            return false;
        byte = buf_[tail & (Capacity - 1)];
        tail_.store(tail + 1, std::memory_order_release);
        return true;
    }

    // Consumer side: copy out up to `max` bytes, returning how many.
    size_t pop_bulk(uint8_t *out, size_t max) {
        const uint32_t tail = tail_.load(std::memory_order_relaxed);
        const uint32_t head = head_.load(std::memory_order_acquire);
        size_t n = head - tail;
        if (n > max) n = max;
        for (size_t i = 0; i < n; ++i)
            out[i] = buf_[(tail + i) & (Capacity - 1)];
        tail_.store(tail + static_cast<uint32_t>(n), std::memory_order_release);
        return n;
    }

    // Either side; a snapshot that may be stale by the time it is used.
    bool empty() const {
        return head_.load(std::memory_order_acquire) ==
               tail_.load(std::memory_order_acquire);
    }

private:
    alignas(64) std::atomic<uint32_t> head_{0};
    alignas(64) std::atomic<uint32_t> tail_{0};
    alignas(64) uint8_t buf_[Capacity];
};
