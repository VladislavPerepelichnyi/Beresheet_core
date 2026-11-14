#include <iostream>
#include <memory>
#include <cassert>

#include "verilated.h"
#include "verilated_vcd_c.h"

#include "Valu.h"
#include "definitions.h"

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Verilated::traceEverOn(true); 

    auto alu = std::make_unique<Valu>();
    auto trace = std::make_unique<VerilatedVcdC>();
    alu->trace(trace.get(), 99); 
    
    // save vcd directly to the build directory
    trace->open("build/sim/alu/waveform.vcd");

    uint64_t sim_time = 0;

    auto test_op = [&](uint32_t a, uint32_t b, uint8_t op, uint32_t expected) {
        alu->a = a;
        alu->b = b;
        alu->alu_control = op;
        
        alu->eval(); 
        trace->dump(sim_time++); 
        
        if (alu->result != expected) {
            // red text for failure
            std::cerr << "\033[1;31mALU TB FAILED\033[0m\n"
                      << "a=" << a << " b=" << b << " op=" << (int)op 
                      << " | expected: " << expected << " got: " << alu->result << std::endl;
            assert(false); 
        }
    };

    // math
    test_op(10, 20, ALU_ADD, 30);
    test_op(50, 15, ALU_SUB, 35);
    test_op(0xFFFFFFFF, 1, ALU_ADD, 0); // overflow check

    // logic
    test_op(0b1100, 0b1010, ALU_AND, 0b1000);
    test_op(0b1100, 0b1010, ALU_OR,  0b1110);
    test_op(0b1100, 0b1010, ALU_XOR, 0b0110);

    // shifts
    test_op(1, 4, ALU_SLL, 16);
    test_op(16, 2, ALU_SRL, 4);

    // arithmetic shift right (preserves sign bit)
    // 0xFFFFFFFC is -4 in two's complement. -4 >> 1 = -2 (0xFFFFFFFE)
    test_op(0xFFFFFFFC, 1, ALU_SRA, 0xFFFFFFFE);

    // signed set less than
    // -10 (0xFFFFFFF6) < 5 -> true (1)
    test_op(0xFFFFFFF6, 5, ALU_SLT, 1);
    // 5 < -10 -> false (0)
    test_op(5, 0xFFFFFFF6, ALU_SLT, 0);

    // unsigned set less than
    // 0xFFFFFFF6 (4294967286) < 5 -> false (0)
    test_op(0xFFFFFFF6, 5, ALU_SLTU, 0);

    // green text for success
    std::cout << "\033[1;32mALU TB SUCCEEDED\033[0m\n";

    alu->final();
    trace->close();

    return 0;
}
