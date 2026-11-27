#include "guest_memory.h"

#include <cerrno>
#include <cstdio>
#include <elf.h>
#include <fcntl.h>
#include <fstream>
#include <sstream>
#include <stdexcept>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

namespace {

constexpr uint32_t kPage = 4096;

[[noreturn]] void fail(const std::string &msg) { throw std::runtime_error(msg); }

std::string sys_error(const std::string &what, const std::string &path) {
    return what + " " + path + ": " + strerror(errno);
}

// A read-only view of a whole file, unmapped on scope exit.
struct FileView {
    int fd = -1;
    size_t size = 0;
    const uint8_t *data = nullptr;

    explicit FileView(const std::string &path, bool map = true) {
        fd = open(path.c_str(), O_RDONLY | O_CLOEXEC);
        if (fd < 0) fail(sys_error("cannot open", path));
        struct stat st;
        if (fstat(fd, &st) != 0) fail(sys_error("cannot stat", path));
        size = static_cast<size_t>(st.st_size);
        if (map && size) {
            void *p = mmap(nullptr, size, PROT_READ, MAP_PRIVATE, fd, 0);
            if (p == MAP_FAILED) fail(sys_error("cannot map", path));
            data = static_cast<const uint8_t *>(p);
        }
    }
    ~FileView() {
        if (data) munmap(const_cast<uint8_t *>(data), size);
        if (fd >= 0) close(fd);
    }
};

// RV32I encodings for the reset stub.
uint32_t rv_lui(unsigned rd, uint32_t imm20) { return (imm20 << 12) | (rd << 7) | 0x37; }
uint32_t rv_addi(unsigned rd, unsigned rs1, int32_t imm) {
    return (static_cast<uint32_t>(imm & 0xFFF) << 20) | (rs1 << 15) | (rd << 7) | 0x13;
}
uint32_t rv_jalr(unsigned rd, unsigned rs1, int32_t imm) {
    return (static_cast<uint32_t>(imm & 0xFFF) << 20) | (rs1 << 15) | (rd << 7) | 0x67;
}
// Splits a 32-bit constant for lui + a sign-extended 12-bit add.
void split_hi_lo(uint32_t v, uint32_t &hi, int32_t &lo) {
    hi = (v + 0x800u) >> 12;
    lo = static_cast<int32_t>(v - (hi << 12));
}

constexpr unsigned kRegT0 = 5, kRegA0 = 10, kRegA1 = 11, kRegA2 = 12;

std::string hex32(uint32_t v) {
    char b[16];
    snprintf(b, sizeof b, "0x%08x", v);
    return b;
}

struct DescEntry {
    std::string role, file;
    uint32_t addr;
    int line;
};

// Parses BOOT.TXT. Same grammar as the BIOS (firmware/bios/boot.c): one
// "<role> <file> <hex address>" per line, '#' starts a comment.
bool parse_descriptor(const std::string &text, std::vector<DescEntry> &out,
                      std::string &err) {
    std::istringstream in(text);
    std::string line;
    int lineno = 0;
    while (std::getline(in, line)) {
        ++lineno;
        const size_t hash = line.find('#');
        if (hash != std::string::npos) line.resize(hash);
        std::istringstream ls(line);
        std::string role, file, addr, extra;
        if (!(ls >> role)) continue;
        if (!(ls >> file >> addr) || (ls >> extra)) {
            err = "line " + std::to_string(lineno) + ": expected <role> <file> <hex address>";
            return false;
        }
        if (role != "sbi" && role != "kernel" && role != "dtb" && role != "load") {
            err = "line " + std::to_string(lineno) + ": unknown role \"" + role + "\"";
            return false;
        }
        char *end = nullptr;
        const unsigned long a = strtoul(addr.c_str(), &end, 16);
        if (addr.empty() || *end != '\0' || a > 0xFFFFFFFFul) {
            err = "line " + std::to_string(lineno) + ": bad address \"" + addr + "\"";
            return false;
        }
        out.push_back({role, file, static_cast<uint32_t>(a), lineno});
    }
    if (out.empty()) {
        err = "no entries";
        return false;
    }
    return true;
}

std::string read_small_text(const std::string &path, size_t limit) {
    std::ifstream f(path, std::ios::binary);
    if (!f) return {};
    std::string s(limit, '\0');
    f.read(&s[0], static_cast<std::streamsize>(limit));
    s.resize(static_cast<size_t>(f.gcount()));
    return s;
}

}  // namespace

// -----------------------------------------------------------------------------

GuestMemory::GuestMemory() {
    // Anonymous and lazily backed: untouched SDRAM costs no host memory, and
    // reads as zero exactly like the board's memory after the BIOS clears it.
    const int flags = MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE;
    void *b = mmap(nullptr, kBootSize, PROT_READ | PROT_WRITE, flags, -1, 0);
    void *s = mmap(nullptr, kSdramSize, PROT_READ | PROT_WRITE, flags, -1, 0);
    if (b == MAP_FAILED || s == MAP_FAILED) fail("cannot reserve guest memory");
    boot_  = static_cast<uint8_t *>(b);
    sdram_ = static_cast<uint8_t *>(s);
}

GuestMemory::~GuestMemory() {
    munmap(boot_, kBootSize);
    munmap(sdram_, kSdramSize);
}

// Placing a file image.
//
// In SDRAM a page-aligned file is mapped straight into the guest region with
// MAP_PRIVATE | MAP_FIXED over the anonymous reservation. That is zero-copy -
// a 3 MB kernel costs one system call, and pages the guest never touches are
// never read - and copy-on-write, so the guest can write anywhere and the file
// is never modified (it was opened O_RDONLY, which MAP_PRIVATE permits with
// PROT_WRITE). The kernel zero-fills the tail of the last page past end of
// file, which is what the guest would see on the board.
//
// Everything else is copied with pread(): boot RAM (small, and the reset stub
// is written into it), an unaligned address, or a file whose first or last page
// is shared with an image already placed - mapping over that page would replace
// the earlier image's bytes.
void GuestMemory::place_file(const std::string &path, uint32_t addr, bool map_ok) {
    FileView f(path, /*map=*/false);
    const uint64_t end = static_cast<uint64_t>(addr) + f.size;

    const bool in_sdram = addr >= kSdramBase && end <= uint64_t(kSdramBase) + kSdramSize;
    const bool in_boot  = end <= kBootSize;
    if (!in_sdram && !in_boot)
        fail(path + " (" + std::to_string(f.size) + " bytes at " + hex32(addr) +
             ") does not fit in boot RAM or SDRAM");
    if (f.size == 0) return;

    uint8_t *host = ram(addr);
    bool use_map = false;
    size_t first = 0, last = 0;
    if (in_sdram) {
        first = (addr - kSdramBase) / kPage;
        last  = (addr - kSdramBase + f.size - 1) / kPage;
        use_map = map_ok && sysconf(_SC_PAGESIZE) == kPage && (addr % kPage) == 0;
        for (size_t p = first; p <= last && use_map; ++p)
            if (loaded_page_[p]) use_map = false;
    }

    if (use_map) {
        void *p = mmap(host, f.size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_FIXED, f.fd, 0);
        if (p == MAP_FAILED) fail(sys_error("cannot map", path));
    } else {
        size_t done = 0;
        while (done < f.size) {
            const ssize_t n = pread(f.fd, host + done, f.size - done, static_cast<off_t>(done));
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) fail(sys_error("short read from", path));
            done += static_cast<size_t>(n);
        }
    }
    if (in_sdram)
        for (size_t p = first; p <= last; ++p) loaded_page_[p] = true;
}

void GuestMemory::load_raw(const std::string &path, uint32_t addr) {
    place_file(path, addr, /*map_ok=*/true);
}

// ELF segments are copied from a read-only mapping of the file rather than
// mapped into the guest: a segment's page also holds neighbouring file bytes
// (headers, the next section), and .bss past p_filesz must read as zero.
uint32_t GuestMemory::load_elf(const std::string &path) {
    FileView f(path);
    if (f.size < sizeof(Elf32_Ehdr)) fail(path + ": too small to be an ELF file");

    Elf32_Ehdr eh;
    memcpy(&eh, f.data, sizeof eh);
    if (memcmp(eh.e_ident, ELFMAG, SELFMAG) != 0) fail(path + ": not an ELF file");
    if (eh.e_ident[EI_CLASS] != ELFCLASS32 || eh.e_ident[EI_DATA] != ELFDATA2LSB ||
        eh.e_machine != EM_RISCV)
        fail(path + ": not a 32-bit little-endian RISC-V ELF");
    if (eh.e_phoff + uint64_t(eh.e_phnum) * sizeof(Elf32_Phdr) > f.size)
        fail(path + ": truncated program header table");

    unsigned loaded = 0;
    for (unsigned i = 0; i < eh.e_phnum; ++i) {
        Elf32_Phdr ph;
        memcpy(&ph, f.data + eh.e_phoff + i * sizeof(Elf32_Phdr), sizeof ph);
        if (ph.p_type != PT_LOAD || ph.p_memsz == 0) continue;
        if (ph.p_offset + uint64_t(ph.p_filesz) > f.size || ph.p_filesz > ph.p_memsz)
            fail(path + ": segment " + std::to_string(i) + " is malformed");

        const uint64_t end = uint64_t(ph.p_paddr) + ph.p_memsz;
        uint8_t *first = ram(ph.p_paddr);
        uint8_t *last  = ram(static_cast<uint32_t>(end - 1));
        if (!first || !last || last - first != static_cast<ptrdiff_t>(ph.p_memsz - 1))
            fail(path + ": segment at " + hex32(ph.p_paddr) + " (" +
                 std::to_string(ph.p_memsz) + " bytes) is outside boot RAM and SDRAM");

        memcpy(first, f.data + ph.p_offset, ph.p_filesz);
        memset(first + ph.p_filesz, 0, ph.p_memsz - ph.p_filesz);
        ++loaded;
    }
    if (!loaded) fail(path + ": no loadable segments");
    return eh.e_entry;
}

void GuestMemory::write_reset_jump(uint32_t target) {
    uint32_t hi;
    int32_t lo;
    split_hi_lo(target, hi, lo);
    const uint32_t stub[] = {rv_lui(kRegT0, hi), rv_jalr(0, kRegT0, lo)};
    memcpy(boot_, stub, sizeof stub);
}

bool GuestMemory::is_boot_descriptor(const std::string &path) {
    const std::string text = read_small_text(path, 8192);
    if (text.empty() || text.find('\0') != std::string::npos) return false;
    for (unsigned char c : text)
        if (c < 0x20 && c != '\n' && c != '\r' && c != '\t') return false;
    std::vector<DescEntry> entries;
    std::string err;
    return parse_descriptor(text, entries, err);
}

// -----------------------------------------------------------------------------
// Boot descriptor
//
// Loads what the board BIOS would load from the SD card, then stands in for the
// BIOS's handoff (boot_handoff() in firmware/bios/boot.c) with a stub at the
// reset vector:
//
//   a0 = 0                 hart id
//   a1 = dtb address       0 if the descriptor has none
//   a2 = &fw_dynamic_info  in boot RAM, where the BIOS also keeps it
//   jump to the sbi image in machine mode
//
// fw_dynamic_info tells OpenSBI what to run after itself: magic "OSBI",
// version 2, next_addr = kernel, next_mode = 1 (supervisor), options 0,
// boot_hart 0. Interrupts are already off out of reset, which is the state the
// BIOS establishes before jumping.
// -----------------------------------------------------------------------------
std::string GuestMemory::load_boot_descriptor(const std::string &path) {
    const std::string text = read_small_text(path, 65536);
    std::vector<DescEntry> entries;
    std::string err;
    if (!parse_descriptor(text, entries, err)) fail(path + ": " + err);

    std::string dir = ".";
    const size_t slash = path.find_last_of('/');
    if (slash != std::string::npos) dir = path.substr(0, slash ? slash : 1);

    bool have_sbi = false, have_kernel = false, have_dtb = false;
    uint32_t sbi = 0, kernel = 0, dtb = 0;
    std::string log;

    for (const DescEntry &e : entries) {
        // The BIOS loads only into SDRAM, so that a bad descriptor cannot
        // overwrite the code doing the loading. Same rule here, so a
        // descriptor accepted by this simulator is accepted by the board.
        if (e.addr < kSdramBase)
            fail(path + " line " + std::to_string(e.line) + ": " + hex32(e.addr) +
                 " is not inside SDRAM");
        const std::string file = e.file[0] == '/' ? e.file : dir + "/" + e.file;
        place_file(file, e.addr, /*map_ok=*/true);

        if (e.role == "sbi")    { sbi = e.addr;    have_sbi = true; }
        if (e.role == "kernel") { kernel = e.addr; have_kernel = true; }
        if (e.role == "dtb")    { dtb = e.addr;    have_dtb = true; }
        log += " " + e.role + "@" + hex32(e.addr);
    }
    if (!have_sbi) fail(path + ": no 'sbi' entry - nowhere to jump");

    constexpr uint32_t kInfoAddr = 0x40;
    const uint32_t info[] = {
        0x4942534fu,                    // magic "OSBI"
        2,                              // version
        have_kernel ? kernel : 0,       // next_addr
        1,                              // next_mode: supervisor
        0,                              // options
        0,                              // boot_hart
    };
    memcpy(boot_ + kInfoAddr, info, sizeof info);

    uint32_t dtb_hi, sbi_hi;
    int32_t dtb_lo, sbi_lo;
    split_hi_lo(have_dtb ? dtb : 0, dtb_hi, dtb_lo);
    split_hi_lo(sbi, sbi_hi, sbi_lo);
    const uint32_t stub[] = {
        rv_addi(kRegA0, 0, 0),
        rv_lui(kRegA1, dtb_hi),
        rv_addi(kRegA1, kRegA1, dtb_lo),
        rv_addi(kRegA2, 0, kInfoAddr),
        rv_lui(kRegT0, sbi_hi),
        rv_jalr(0, kRegT0, sbi_lo),
    };
    static_assert(sizeof stub <= kInfoAddr, "reset stub overlaps fw_dynamic_info");
    memcpy(boot_, stub, sizeof stub);
    return log;
}
