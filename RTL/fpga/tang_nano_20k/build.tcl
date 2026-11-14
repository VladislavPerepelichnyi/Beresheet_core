# =============================================================================
# Gowin synthesis and place-and-route, driven from gw_sh.
#
#   gw_sh RTL/fpga/tang_nano_20k/build.tcl
#
# Run from the repository root; every path below is relative to it. The Makefile
# target `make fpga` does that and stages the BIOS image first.
#
# Device: GW2AR-LV18QN88C8/I7, the Tang Nano 20K part. The "R" is what matters -
# it is the variant with the 64 Mbit SDRAM in the package.
# =============================================================================

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

# The simulation-only memories in RTL/core (instruction_rom.v, data_ram.v) are
# deliberately not listed: on hardware the boot memory is a Wishbone slave.

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

# SD card, SPI mode. The four rtl/spi files are ZipCPU's, unmodified.
add_file -type verilog RTL/peripherals/sdcard/llsdspi.v
add_file -type verilog RTL/peripherals/sdcard/spicmd.v
add_file -type verilog RTL/peripherals/sdcard/spirxdata.v
add_file -type verilog RTL/peripherals/sdcard/spitxdata.v
add_file -type verilog RTL/peripherals/sdcard/sdspi.v
add_file -type verilog RTL/peripherals/sdcard/sdspi_wb.v
# Puts `default_nettype back; see the file. Must stay directly after the above.
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
add_file -type verilog RTL/fpga/tang_nano_20k/gowin_rpll.v
add_file -type verilog RTL/fpga/tang_nano_20k/top_tang_nano_20k.v

# --- Constraints --------------------------------------------------------------
add_file -type cst RTL/fpga/tang_nano_20k/tang_nano_20k.cst
add_file -type sdc RTL/fpga/tang_nano_20k/tang_nano_20k.sdc

# --- Options ------------------------------------------------------------------
set_option -top_module top_tang_nano_20k
set_option -verilog_std v2001
set_option -output_base_name custom_riscv

# Where `include and $readmemh look. build/fpga holds the staged BIOS image.
set_option -include_path {RTL/core;RTL/bus;RTL/peripherals/uart16550;build/fpga}

# Keep the SDRAM's tristate data bus as a real bidirectional pad.
set_option -use_sspi_as_gpio 1
set_option -use_mspi_as_gpio 1
set_option -use_ready_as_gpio 1
set_option -use_done_as_gpio 1

# Place and route writes impl/pnr/custom_riscv.fs
run all
