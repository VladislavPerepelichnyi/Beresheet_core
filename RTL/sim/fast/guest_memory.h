// Guest physical memory for the fast simulator, and the program loaders.
//
// Two RAM regions at their SoC addresses, so a binary built for the board runs
// here unchanged:
//
//   0x0000_0000  boot RAM   32 KiB   reset vector (PC_INIT_VALUE in definitions.vh)
//   0x8000_0000  SDRAM       8 MiB
//
// Accesses outside both are not RAM; the caller routes them to the device
// models. There is no aliasing: the SoC decodes on address[31:24] and so
// repeats each RAM through its 16 MiB window, but a program that relies on
// that is wrong, and here it is reported instead of silently working.
#pragma once

#include <cstdint>
#include <cstring>
#include <string>

static_assert(__BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__,
              "guest memory is accessed with host loads; RISC-V is little-endian");

class GuestMemory {
public:
    static constexpr uint32_t kBootBase  = 0x00000000u;
    static constexpr uint32_t kBootSize  = 32u * 1024;        // BOOT_RAM_BYTES
    static constexpr uint32_t kSdramBase = 0x80000000u;
    static constexpr uint32_t kSdramSize = 8u * 1024 * 1024;  // SDRAM_BYTES

    GuestMemory();
    ~GuestMemory();
    GuestMemory(const GuestMemory &) = delete;
    GuestMemory &operator=(const GuestMemory &) = delete;

    // Host pointer for a guest address, or nullptr if it is not RAM.
    uint8_t *ram(uint32_t addr) {
        const uint32_t s = addr - kSdramBase;
        if (s < kSdramSize) return sdram_ + s;
        if (addr < kBootSize) return boot_ + addr;
        return nullptr;
    }

    // Word at an aligned address that is known to be RAM.
    static uint32_t load32(const uint8_t *p) {
        uint32_t v;
        memcpy(&v, p, 4);
        return v;
    }

    // Store with byte strobes to an aligned address that is known to be RAM.
    static void store32(uint8_t *p, uint32_t data, unsigned strb) {
        if (strb == 0xF) { memcpy(p, &data, 4); return; }
        for (unsigned i = 0; i < 4; ++i)
            if (strb & (1u << i)) p[i] = static_cast<uint8_t>(data >> (8 * i));
    }

    // --- Loaders. Each throws std::runtime_error with a readable message. ---

    // An ELF32 RISC-V executable: every PT_LOAD segment at its physical
    // address, .bss zeroed. Returns the entry point.
    uint32_t load_elf(const std::string &path);

    // A raw image at `addr`.
    void load_raw(const std::string &path, uint32_t addr);

    // A boot descriptor (the board BIOS's BOOT.TXT). Loads every entry and
    // writes a reset stub at 0x0 that enters the `sbi` image the way the BIOS
    // does. Returns a one-line description for the log.
    std::string load_boot_descriptor(const std::string &path);

    // Writes a two-instruction jump to `target` at the reset vector.
    void write_reset_jump(uint32_t target);

    // True when `path` looks like a boot descriptor rather than a binary.
    static bool is_boot_descriptor(const std::string &path);

private:
    // Places a file's bytes at a guest address, by mapping it when possible.
    void place_file(const std::string &path, uint32_t addr, bool map_ok);

    uint8_t *boot_  = nullptr;
    uint8_t *sdram_ = nullptr;
    // Pages of SDRAM that already hold part of a loaded image, so a later
    // image that shares one is copied instead of mapped over it.
    bool loaded_page_[kSdramSize / 4096] = {};
};
