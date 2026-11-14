#include <iostream>
#include <memory>
#include <cassert>
#include <iomanip>
#include <string>

#include "verilated.h"
#include "verilated_vcd_c.h"

#include "Vpc_gen.h"
#include "definitions.h"

// Struct to hold all input signals cleanly
struct CtrlSignals {
    uint32_t stall        = 0;
    uint32_t trap_take    = 0;
    uint32_t trap_vector  = 0;
    uint32_t trap_return  = 0;
    uint32_t trap_epc     = 0;
    uint32_t mispredict   = 0;
    uint32_t actual_taken = 0;
    uint32_t correct_pc   = 0;
    uint32_t branch_pc    = 0;
};

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Verilated::traceEverOn(true); 

    auto pc_gen = std::make_unique<Vpc_gen>();
    auto trace = std::make_unique<VerilatedVcdC>();
    pc_gen->trace(trace.get(), 99); 
    
    // Save VCD directly to the build directory
    trace->open("build/sim/pc_gen/waveform.vcd");

    uint64_t sim_time = 0;

    // Clock generation and evaluation helper
    auto tick = [&]() {
        pc_gen->clk = 0;
        pc_gen->eval();
        trace->dump(sim_time++);
        
        pc_gen->clk = 1;
        pc_gen->eval();
        trace->dump(sim_time++);
    };

    // Helper to apply inputs, advance clock, and verify the 3 required outputs
    auto test_step = [&](
        const std::string& name,
        const CtrlSignals& in,
        uint32_t exp_pc_out, 
        uint32_t exp_predicted_pc, 
        uint8_t  exp_misaligned
    ) {
        // Apply inputs
        pc_gen->stall        = in.stall;
        pc_gen->trap_take    = in.trap_take;
        pc_gen->trap_vector  = in.trap_vector;
        pc_gen->trap_return  = in.trap_return;
        pc_gen->trap_epc     = in.trap_epc;
        pc_gen->mispredict   = in.mispredict;
        pc_gen->actual_taken = in.actual_taken;
        pc_gen->correct_pc   = in.correct_pc;
        pc_gen->branch_pc    = in.branch_pc;

        // Combinational eval before clock edge, then tick the clock
        pc_gen->eval();
        tick();

        // Verification
        bool failed = false;
        if (pc_gen->pc_out != exp_pc_out) failed = true;
        if (pc_gen->predicted_pc != exp_predicted_pc) failed = true;
        if (pc_gen->misaligned_fetch != exp_misaligned) failed = true;

        if (failed) {
            std::cerr << "\033[1;31mPC_GEN TB FAILED at: " << name << "\033[0m\n"
                      << std::hex << std::setfill('0')
                      << "  Expected PC_OUT: 0x" << exp_pc_out 
                      << " | Got: 0x" << pc_gen->pc_out << "\n"
                      << "  Expected PRED  : 0x" << exp_predicted_pc 
                      << " | Got: 0x" << pc_gen->predicted_pc << "\n"
                      << std::dec
                      << "  Expected ALIGN : " << (int)exp_misaligned 
                      << " | Got: " << (int)pc_gen->misaligned_fetch << std::endl;
            assert(false);
        }
    };

    // =========================================================================
    // INITIALIZATION & RESET
    // =========================================================================
    pc_gen->rst = 1;
    tick();
    pc_gen->rst = 0;

    CtrlSignals ctrl; // Blank control structure (all zeros)

    // =========================================================================
    // SCENARIO 1: Instruction that NEVER jumps
    // =========================================================================
    // Normal sequential fetching (PC + 4)
    test_step("Seq Fetch 1", ctrl, 0x0004, 0x0008, 0);
    test_step("Seq Fetch 2", ctrl, 0x0008, 0x000C, 0);

    // =========================================================================
    // SCENARIO 2: Instruction that ALWAYS jumps (Learn and Predict)
    // =========================================================================
    // Branch located at 0x000C, target is 0x1000
    
    // Cycle 1: First time seeing it, BTB predicts sequential (0x0010)
    test_step("Always Jump - First Encounter (Predicts PC+4)", ctrl, 0x000C, 0x0010, 0);
    
    // Cycle 2: EX stage resolves mispredict, forces PC to 0x1000 and trains BTB
    ctrl.mispredict = 1; ctrl.actual_taken = 1; ctrl.correct_pc = 0x1000; ctrl.branch_pc = 0x000C;
    test_step("Always Jump - EX Mispredict Correction", ctrl, 0x1000, 0x1004, 0);
    
    // Cycle 3: Teleport back to 0x000C using a unique branch_pc (0x00A0) to avoid aliasing
    ctrl.mispredict = 1; ctrl.actual_taken = 1; ctrl.correct_pc = 0x000C; ctrl.branch_pc = 0x00A0; // Teleport
    test_step("Always Jump - Teleport back", ctrl, 0x000C, 0x1000, 0); // BTB hits, predicts 0x1000!
    
    // Cycle 4: Follows the prediction naturally without EX intervention
    ctrl = CtrlSignals(); // Reset controls to 0
    test_step("Always Jump - Follows BTB Prediction", ctrl, 0x1000, 0x1004, 0);


    // =========================================================================
    // SCENARIO 3: Instruction that jumps 50% of the time
    // =========================================================================
    // Branch located at 0x0040, target is 0x3000
    
    // Teleport to 0x0040 using a unique branch_pc (0x00B0) to avoid aliasing
    ctrl.mispredict = 1; ctrl.actual_taken = 1; ctrl.correct_pc = 0x0040; ctrl.branch_pc = 0x00B0;
    test_step("50% Jump - Teleport to 0x0040", ctrl, 0x0040, 0x0044, 0);

    // Case A (It Jumped): EX corrects PC to 0x3000 and BTB learns
    ctrl.mispredict = 1; ctrl.actual_taken = 1; ctrl.correct_pc = 0x3000; ctrl.branch_pc = 0x0040;
    test_step("50% Jump - Case A: Actually Jumped", ctrl, 0x3000, 0x3004, 0);

    // Teleport back to 0x0040 to test BTB
    ctrl.mispredict = 1; ctrl.actual_taken = 1; ctrl.correct_pc = 0x0040; ctrl.branch_pc = 0x00B0;
    test_step("50% Jump - Teleport back", ctrl, 0x0040, 0x3000, 0); // BTB predicts 0x3000

    // Follow prediction to 0x3000
    ctrl = CtrlSignals();
    test_step("50% Jump - Follow prediction", ctrl, 0x3000, 0x3004, 0);

    // Case B (It DID NOT Jump): EX corrects PC back to sequential (0x0044), BTB drops entry
    ctrl.mispredict = 1; ctrl.actual_taken = 0; ctrl.correct_pc = 0x0044; ctrl.branch_pc = 0x0040;
    test_step("50% Jump - Case B: Did NOT Jump", ctrl, 0x0044, 0x0048, 0);

    // Teleport back to 0x0040 one last time to confirm BTB dropped the prediction
    ctrl.mispredict = 1; ctrl.actual_taken = 1; ctrl.correct_pc = 0x0040; ctrl.branch_pc = 0x00B0;
    test_step("50% Jump - Confirm BTB Eviction", ctrl, 0x0040, 0x0044, 0); // Predicts sequential


    // =========================================================================
    // SCENARIO 4: Traps and Trap Returns
    // =========================================================================
    // Trigger an asynchronous trap (e.g., Timer Interrupt) to mtvec 0x80000000
    ctrl = CtrlSignals();
    ctrl.trap_take = 1; ctrl.trap_vector = 0x80000000;
    test_step("Trap Taken", ctrl, 0x80000000, 0x80000004, 0);

    // Trap handler fetches sequentially
    ctrl = CtrlSignals();
    test_step("Trap Handler Seq", ctrl, 0x80000004, 0x80000008, 0);

    // MRET back to interrupted code (e.g., 0x0044)
    ctrl.trap_return = 1; ctrl.trap_epc = 0x0044;
    test_step("Trap Return (MRET)", ctrl, 0x0044, 0x0048, 0);


    // =========================================================================
    // SCENARIO 5: Misaligned Fetch Verification
    // =========================================================================
    // Attempting to jump to an address not divisible by 4 (e.g., 0x2002)
    ctrl = CtrlSignals();
    ctrl.mispredict = 1; ctrl.actual_taken = 1; ctrl.correct_pc = 0x2002; ctrl.branch_pc = 0x0044;
    test_step("Misaligned Fetch Check", ctrl, 0x2002, 0x2006, 1); // misaligned_fetch should be 1

    
    // Green text for success
    std::cout << "\033[1;32mPC_GEN TB SUCCEEDED\033[0m\n";

    pc_gen->final();
    trace->close();

    return 0;
}