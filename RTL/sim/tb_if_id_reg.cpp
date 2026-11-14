#include <iostream>
#include <memory>
#include <cassert>
#include <string>
#include <iomanip>

#include "verilated.h"
#include "verilated_vcd_c.h"

#include "Vif_id_reg.h"

// Struct to hold all input signals cleanly
struct CtrlSignals {
    uint8_t  flush           = 0;
    uint8_t  stall           = 0;
    uint32_t instruction_in  = 0;
    uint32_t pc_in           = 0;
    uint32_t predicted_pc_in = 0;
    uint8_t  fault_in        = 0;
};

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Verilated::traceEverOn(true); 

    auto if_id = std::make_unique<Vif_id_reg>();
    auto trace = std::make_unique<VerilatedVcdC>();
    if_id->trace(trace.get(), 99); 
    
    // Save VCD directly to the build directory
    trace->open("build/sim/if_id_reg/waveform.vcd");

    uint64_t sim_time = 0;

    // Clock generation and evaluation helper
    auto tick = [&]() {
        if_id->clk = 0;
        if_id->eval();
        trace->dump(sim_time++);
        
        if_id->clk = 1;
        if_id->eval();
        trace->dump(sim_time++);
    };

    // Helper to apply inputs, advance clock, and verify passthrough logic
    auto test_step = [&](
        const std::string& name,
        const CtrlSignals& in,
        bool check_data, // If true, we check exact payload; if false, we only check valid/fault
        uint32_t exp_inst, 
        uint32_t exp_pc, 
        uint32_t exp_pred,
        uint8_t  exp_fault,
        uint8_t  exp_valid
    ) {
        if_id->flush           = in.flush;
        if_id->stall           = in.stall;
        if_id->instruction_in  = in.instruction_in;
        if_id->pc_in           = in.pc_in;
        if_id->predicted_pc_in = in.predicted_pc_in;
        if_id->fault_in        = in.fault_in;

        if_id->eval();
        tick();

        bool failed = false;
        
        if (if_id->valid_out != exp_valid) failed = true;
        if (if_id->fault_out != exp_fault) failed = true;
        
        if (check_data) {
            if (if_id->instruction_out != exp_inst) failed = true;
            if (if_id->pc_out != exp_pc) failed = true;
            if (if_id->predicted_pc_out != exp_pred) failed = true;
        }

        if (failed) {
            std::cerr << "\033[1;31mIF/ID REG TB FAILED at: " << name << "\033[0m\n"
                      << "  Expected Valid : " << (int)exp_valid 
                      << " | Got: " << (int)if_id->valid_out << "\n"
                      << "  Expected Fault : " << (int)exp_fault 
                      << " | Got: " << (int)if_id->fault_out << "\n";
            if (check_data) {
                std::cerr << std::hex << std::setfill('0')
                          << "  Expected Inst  : 0x" << exp_inst 
                          << " | Got: 0x" << if_id->instruction_out << "\n"
                          << "  Expected PC    : 0x" << exp_pc   
                          << " | Got: 0x" << if_id->pc_out << "\n"
                          << "  Expected Pred  : 0x" << exp_pred 
                          << " | Got: 0x" << if_id->predicted_pc_out << "\n"
                          << std::dec;
            }
            assert(false);
        }
    };

    // =========================================================================
    // INITIALIZATION & RESET
    // =========================================================================
    if_id->rst = 1;
    tick();
    if_id->rst = 0;
    if_id->eval(); // Force combinational update after reset drops
    
    // Check that reset cleared the valid bit without calling test_step!
    if (if_id->valid_out != 0) {
        std::cerr << "\033[1;31mIF/ID REG TB FAILED at: Post-Reset state\033[0m\n";
        assert(false);
    }

    CtrlSignals ctrl; 

    // =========================================================================
    // NORMAL PASSTHROUGH
    // =========================================================================
    ctrl.instruction_in  = 0xDEADBEEF;
    ctrl.pc_in           = 0x1000;
    ctrl.predicted_pc_in = 0x1004;
    ctrl.fault_in        = 0;
    test_step("Normal Fetch", ctrl, true, 0xDEADBEEF, 0x1000, 0x1004, 0, 1);

    ctrl.instruction_in  = 0xCAFEBABE;
    ctrl.pc_in           = 0x1004;
    ctrl.predicted_pc_in = 0x1008;
    test_step("Next Fetch", ctrl, true, 0xCAFEBABE, 0x1004, 0x1008, 0, 1);

    // =========================================================================
    // STALL (Pipeline freeze, should ignore inputs and hold previous data)
    // =========================================================================
    ctrl.stall           = 1;
    ctrl.instruction_in  = 0x11111111; // New incoming data to be ignored
    ctrl.pc_in           = 0x22222222;
    ctrl.predicted_pc_in = 0x33333333;
    // We expect the outputs from "Next Fetch" to remain held
    test_step("Stall pipeline", ctrl, true, 0xCAFEBABE, 0x1004, 0x1008, 0, 1);

    // =========================================================================
    // FLUSH (Branch mispredict or Trap, should kill valid bit)
    // =========================================================================
    ctrl.stall           = 0;
    ctrl.flush           = 1;
    ctrl.instruction_in  = 0x99999999;
    ctrl.pc_in           = 0x4000;
    // We only check valid=0 and fault=0, exact data is defined by I_NOP macro
    test_step("Flush pipeline", ctrl, false, 0, 0, 0, 0, 0);

    // =========================================================================
    // POISONED SLOT (Instruction page fault)
    // =========================================================================
    ctrl.flush           = 0;
    ctrl.instruction_in  = 0x00000000; // Garbage instruction due to fault
    ctrl.pc_in           = 0x8000;     // The PC that caused the fault
    ctrl.predicted_pc_in = 0x0000;
    ctrl.fault_in        = 1;
    // The slot must remain VALID so the trap logic sees it and triggers the exception!
    test_step("Page Fault Fetch", ctrl, true, 0x00000000, 0x8000, 0x0000, 1, 1);

    // Green text for success
    std::cout << "\033[1;32mIF/ID REG TB SUCCEEDED\033[0m\n";

    if_id->final();
    trace->close();

    return 0;
}