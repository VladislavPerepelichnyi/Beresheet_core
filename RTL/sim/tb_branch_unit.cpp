#include <iostream>
#include <memory>
#include <cassert>
#include <string>

#include "verilated.h"
#include "verilated_vcd_c.h"

#include "Vbranch_unit.h"
#include "definitions.h"

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Verilated::traceEverOn(true); 

    auto bu = std::make_unique<Vbranch_unit>();
    auto trace = std::make_unique<VerilatedVcdC>();
    bu->trace(trace.get(), 99); 
    
    // Save VCD directly to the build directory
    trace->open("build/sim/branch_unit/waveform.vcd");

    uint64_t sim_time = 0;

    // Helper to apply inputs, evaluate combinational logic, and check outputs
    auto test_step = [&](
        const std::string& name,
        uint8_t  funct3, 
        uint32_t rs1, 
        uint32_t rs2, 
        uint8_t  exp_take, 
        uint8_t  exp_illegal
    ) {
        bu->funct3   = funct3;
        bu->rs1_data = rs1;
        bu->rs2_data = rs2;

        bu->eval();
        trace->dump(sim_time++); 

        bool failed = false;
        if (bu->take_branch != exp_take) failed = true;
        if (bu->illegal_funct3 != exp_illegal) failed = true;

        if (failed) {
            std::cerr << "\033[1;31mBRANCH_UNIT TB FAILED at: " << name << "\033[0m\n"
                      << "  funct3: " << (int)funct3 
                      << " rs1: " << rs1 << " rs2: " << rs2 << "\n"
                      << "  Expected take_branch: " << (int)exp_take 
                      << " | Got: " << (int)bu->take_branch << "\n"
                      << "  Expected illegal:     " << (int)exp_illegal 
                      << " | Got: " << (int)bu->illegal_funct3 << std::endl;
            assert(false);
        }
    };

    // Note: Standard RISC-V funct3 values are used directly here
    // BEQ = 0, BNE = 1, BLT = 4, BGE = 5, BLTU = 6, BGEU = 7

    // =========================================================================
    // BEQ (000) & BNE (001)
    // =========================================================================
    test_step("BEQ - Equal",     0, 10, 10, 1, 0);
    test_step("BEQ - Not Equal", 0, 10, 20, 0, 0);
    test_step("BNE - Equal",     1, 10, 10, 0, 0);
    test_step("BNE - Not Equal", 1, 10, 20, 1, 0);

    // =========================================================================
    // BLT (100) & BGE (101) - Signed Comparisons
    // =========================================================================
    // 0xFFFFFFFF is -1 in two's complement
    test_step("BLT - Less (Signed)",    4, 0xFFFFFFFF, 1, 1, 0); // -1 < 1
    test_step("BLT - Greater (Signed)", 4, 1, 0xFFFFFFFF, 0, 0); // 1 < -1 is false
    test_step("BLT - Equal",            4, 5, 5,          0, 0); 
    
    test_step("BGE - Less (Signed)",    5, 0xFFFFFFFF, 1, 0, 0); // -1 >= 1 is false
    test_step("BGE - Greater (Signed)", 5, 1, 0xFFFFFFFF, 1, 0); // 1 >= -1
    test_step("BGE - Equal",            5, 5, 5,          1, 0); 

    // =========================================================================
    // BLTU (110) & BGEU (111) - Unsigned Comparisons
    // =========================================================================
    // 0xFFFFFFFF is 4294967295 unsigned
    test_step("BLTU - Greater (Unsigned)", 6, 0xFFFFFFFF, 1, 0, 0); // 4294967295 < 1 is false
    test_step("BLTU - Less (Unsigned)",    6, 1, 0xFFFFFFFF, 1, 0); // 1 < 4294967295
    test_step("BLTU - Equal",              6, 5, 5,          0, 0); 

    test_step("BGEU - Greater (Unsigned)", 7, 0xFFFFFFFF, 1, 1, 0); // 4294967295 >= 1
    test_step("BGEU - Less (Unsigned)",    7, 1, 0xFFFFFFFF, 0, 0); // 1 >= 4294967295 is false
    test_step("BGEU - Equal",              7, 5, 5,          1, 0); 

    // =========================================================================
    // ILLEGAL FUNCT3 (010 & 011)
    // =========================================================================
    test_step("Illegal Funct3 - 010", 2, 10, 10, 0, 1);
    test_step("Illegal Funct3 - 011", 3, 10, 10, 0, 1);

    // Green text for success
    std::cout << "\033[1;32mBRANCH_UNIT TB SUCCEEDED\033[0m\n";

    bu->final();
    trace->close();

    return 0;
}