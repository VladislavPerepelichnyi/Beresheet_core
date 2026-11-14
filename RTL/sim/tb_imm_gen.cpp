#include <iostream>
#include <memory>
#include <cassert>
#include <string>
#include <iomanip>

#include "verilated.h"
#include "verilated_vcd_c.h"

#include "Vimm_gen.h"
#include "definitions.h" // Ensures IMM_I, IMM_S, etc. are imported correctly

// Helper functions to pack an expected immediate value into the proper RISC-V 
// instruction bit fields. This keeps the test step clean and avoids magic numbers.
uint32_t pack_i_type(uint32_t imm) {
    return (imm & 0xFFF) << 20;
}

uint32_t pack_s_type(uint32_t imm) {
    return ((imm & 0xFE0) << 20) | ((imm & 0x1F) << 7);
}

uint32_t pack_b_type(uint32_t imm) {
    return ((imm & 0x1000) << 19) | // inst[31]    = imm[12]
           ((imm & 0x0800) >> 4)  | // inst[7]     = imm[11]
           ((imm & 0x07E0) << 20) | // inst[30:25] = imm[10:5]
           ((imm & 0x001E) << 7);   // inst[11:8]  = imm[4:1]
}

uint32_t pack_j_type(uint32_t imm) {
    return ((imm & 0x100000) << 11) | // inst[31]    = imm[20]
           ((imm & 0x0FF000) << 0)  | // inst[19:12] = imm[19:12]
           ((imm & 0x000800) << 9)  | // inst[20]    = imm[11]
           ((imm & 0x0007FE) << 20);  // inst[30:21] = imm[10:1]
}

uint32_t pack_u_type(uint32_t imm) {
    return imm & 0xFFFFF000;          // inst[31:12] = imm[31:12]
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Verilated::traceEverOn(true); 

    auto imm_gen = std::make_unique<Vimm_gen>();
    auto trace = std::make_unique<VerilatedVcdC>();
    imm_gen->trace(trace.get(), 99); 
    
    // Save VCD directly to the build directory
    trace->open("build/sim/imm_gen/waveform.vcd");

    uint64_t sim_time = 0;

    // Helper to evaluate combinational logic and verify the generated immediate
    auto test_step = [&](
        const std::string& name,
        uint32_t inst,
        uint8_t  imm_src, 
        uint32_t exp_imm
    ) {
        imm_gen->inst    = inst;
        imm_gen->imm_src = imm_src;

        imm_gen->eval();
        trace->dump(sim_time++); 

        if (imm_gen->imm != exp_imm) {
            std::cerr << "\033[1;31mIMM_GEN TB FAILED at: " << name << "\033[0m\n"
                      << std::hex << std::setfill('0')
                      << "  Instruction : 0x" << std::setw(8) << inst << "\n"
                      << "  Src Selector: 0x" << (int)imm_src << "\n"
                      << "  Expected Imm: 0x" << std::setw(8) << exp_imm << "\n"
                      << "  Got Imm     : 0x" << std::setw(8) << imm_gen->imm << std::endl;
            assert(false);
        }
    };

    // =========================================================================
    // I-Type Instructions (ADDI, LW, JALR, etc.)
    // =========================================================================
    test_step("I-Type: Positive", pack_i_type(0x123), IMM_I, 0x00000123);
    test_step("I-Type: Negative", pack_i_type(0xFFFFFFFF), IMM_I, 0xFFFFFFFF); // -1
    test_step("I-Type: Edge Max", pack_i_type(0x7FF), IMM_I, 0x000007FF);      // +2047
    test_step("I-Type: Edge Min", pack_i_type(0x800), IMM_I, 0xFFFFF800);      // -2048

    // =========================================================================
    // S-Type Instructions (SW, SH, SB)
    // =========================================================================
    test_step("S-Type: Positive", pack_s_type(0x123), IMM_S, 0x00000123);
    test_step("S-Type: Negative", pack_s_type(0xFFFFFFFF), IMM_S, 0xFFFFFFFF); // -1
    test_step("S-Type: Edge Max", pack_s_type(0x7FF), IMM_S, 0x000007FF);      // +2047
    test_step("S-Type: Edge Min", pack_s_type(0x800), IMM_S, 0xFFFFF800);      // -2048

    // =========================================================================
    // B-Type Instructions (BEQ, BNE, BLT, etc.) - Implicit bit 0 is 0
    // =========================================================================
    test_step("B-Type: Positive", pack_b_type(0x122), IMM_B, 0x00000122);
    test_step("B-Type: Negative", pack_b_type(0xFFFFFFFE), IMM_B, 0xFFFFFFFE); // -2
    test_step("B-Type: Edge Max", pack_b_type(0xFFE), IMM_B, 0x00000FFE);      // +4094
    test_step("B-Type: Edge Min", pack_b_type(0x1000), IMM_B, 0xFFFFF000);     // -4096

    // =========================================================================
    // J-Type Instructions (JAL) - Implicit bit 0 is 0
    // =========================================================================
    test_step("J-Type: Positive", pack_j_type(0x01234E), IMM_J, 0x0001234E);
    test_step("J-Type: Negative", pack_j_type(0xFFFFFFFE), IMM_J, 0xFFFFFFFE); // -2
    test_step("J-Type: Edge Max", pack_j_type(0x0FFFFE), IMM_J, 0x000FFFFE);   // +1048574
    test_step("J-Type: Edge Min", pack_j_type(0x100000), IMM_J, 0xFFF00000);   // -1048576

    // =========================================================================
    // U-Type Instructions (LUI, AUIPC) - Low 12 bits are 0
    // =========================================================================
    test_step("U-Type: Positive", pack_u_type(0x12345000), IMM_U, 0x12345000);
    test_step("U-Type: Negative", pack_u_type(0xDEADB000), IMM_U, 0xDEADB000); 

    // =========================================================================
    // Z-Type / Atomics - Should always output absolute 0
    // =========================================================================
    // Throwing garbage data at the instruction, Z-Type should strictly return 0
    test_step("Z-Type: Force Zero", 0xDEADBEEF, IMM_Z, 0x00000000);

    // Green text for success
    std::cout << "\033[1;32mIMM_GEN TB SUCCEEDED\033[0m\n";

    imm_gen->final();
    trace->close();

    return 0;
}