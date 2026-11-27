# =============================================================================
# Gowin synthesis and place-and-route for the Tang Nano 20K.
#
#   gw_sh RTL/fpga/tangnano20k/build.tcl
#
# Run from the repository root; all source paths are relative to it. gw_sh
# writes its results to ./impl (output base name "beresheet").
#
# The build directory must already hold the generated soc_config.vh and the
# BIOS image bios.wordhex; both are found through the include path. It is
# build/fpga unless the environment variable FPGA_BUILD_DIR names another.
#
# Device: GW2AR-LV18QN88C8/I7 (GW2AR-18 with in-package 64 Mbit SDRAM).
# =============================================================================

if {[info exists ::env(FPGA_BUILD_DIR)]} {
    set build_dir $::env(FPGA_BUILD_DIR)
} else {
    set build_dir build/fpga
}

set_device -name GW2AR-18C GW2AR-LV18QN88C8/I7

# --- CPU core -----------------------------------------------------------------
add_file -type verilog RTL/core/alu.v
add_file -type verilog RTL/core/branch_unit.v
add_file -type verilog RTL/core/cache.v
add_file -type verilog RTL/core/control_unit.v
add_file -type verilog RTL/core/CSR_unit.v
add_file -type verilog RTL/core/decode_exec.v
add_file -type verilog RTL/core/div_unit.v
add_file -type verilog RTL/core/ex_mem_reg.v
add_file -type verilog RTL/core/file_register.v
add_file -type verilog RTL/core/if_id_reg.v
add_file -type verilog RTL/core/imm_gen.v
add_file -type verilog RTL/core/mem_wb.v
add_file -type verilog RTL/core/MMU.v
add_file -type verilog RTL/core/mul_unit.v
add_file -type verilog RTL/core/muldiv.v
add_file -type verilog RTL/core/pc_gen.v
add_file -type verilog RTL/core/riscv_core.v

# --- Wishbone bus -------------------------------------------------------------
add_file -type verilog RTL/bus/wb_master_bridge.v
add_file -type verilog RTL/bus/wb_arbiter.v
add_file -type verilog RTL/bus/wb_intercon.v
add_file -type verilog RTL/bus/wb_ram.v

# --- Peripherals --------------------------------------------------------------
add_file -type verilog RTL/peripherals/sdram/sdram_core.v
add_file -type verilog RTL/peripherals/sdram/sdram_wb.v

add_file -type verilog RTL/peripherals/clint/clint_wb.v
add_file -type verilog RTL/peripherals/plic/plic_wb.v
add_file -type verilog RTL/peripherals/gpio/led_pwm_wb.v

# SD card: ZipCPU sdspi (upstream) and its bus wrapper
add_file -type verilog RTL/peripherals/sdcard/llsdspi.v
add_file -type verilog RTL/peripherals/sdcard/spicmd.v
add_file -type verilog RTL/peripherals/sdcard/spirxdata.v
add_file -type verilog RTL/peripherals/sdcard/spitxdata.v
add_file -type verilog RTL/peripherals/sdcard/sdspi.v
add_file -type verilog RTL/peripherals/sdcard/sdspi_wb.v
# Resets `default_nettype after the sdspi sources; must follow them directly.
add_file -type verilog RTL/peripherals/sdcard/nettype_restore.v

add_file -type verilog RTL/peripherals/uart16550/raminfr.v
add_file -type verilog RTL/peripherals/uart16550/uart_rfifo.v
add_file -type verilog RTL/peripherals/uart16550/uart_tfifo.v
add_file -type verilog RTL/peripherals/uart16550/uart_sync_flops.v
add_file -type verilog RTL/peripherals/uart16550/uart_receiver.v
add_file -type verilog RTL/peripherals/uart16550/uart_transmitter.v
add_file -type verilog RTL/peripherals/uart16550/uart_debug_if.v
add_file -type verilog RTL/peripherals/uart16550/uart_regs.v
add_file -type verilog RTL/peripherals/uart16550/uart_wb.v
add_file -type verilog RTL/peripherals/uart16550/uart_top.v
add_file -type verilog RTL/peripherals/uart16550/uart_wb_slave.v

# --- SoC and board ------------------------------------------------------------
add_file -type verilog RTL/soc/soc_wb.v
add_file -type verilog RTL/fpga/tangnano20k/gowin_rpll.v
add_file -type verilog RTL/fpga/tangnano20k/top_tang_nano_20k.v

# --- Constraints --------------------------------------------------------------
add_file -type cst RTL/fpga/tangnano20k/tang_nano_20k.cst
add_file -type sdc RTL/fpga/tangnano20k/tang_nano_20k.sdc

# --- Options ------------------------------------------------------------------
set_option -top_module top_tang_nano_20k
set_option -verilog_std v2001
set_option -output_base_name beresheet

# `include and $readmemh search path
set_option -include_path "RTL/core;RTL/bus;RTL/peripherals/uart16550;$build_dir"

# Release the dual-purpose configuration pins for use as ordinary I/O
set_option -use_sspi_as_gpio 1
set_option -use_mspi_as_gpio 1
set_option -use_ready_as_gpio 1
set_option -use_done_as_gpio 1

run all
