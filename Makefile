# =============================================================================
# custom_riscv - build, simulation, firmware and FPGA
#
# Simulator : Verilator (pure-Verilog testbenches, built with --binary)
# Toolchain : riscv64-unknown-elf-gcc, multilib rv32im/ilp32
# FPGA      : Gowin gw_sh, Tang Nano 20K (GW2AR-18)
# Programmer: openFPGALoader
#
# Everything generated lands under build/. Nothing is written to the source
# tree, and `make clean` leaves only checked-in files behind.
#
# Run "make help" for the full target list.
# =============================================================================

SHELL := /bin/bash

# -----------------------------------------------------------------------------
# Layout
# -----------------------------------------------------------------------------
CORE_DIR   := RTL/core
BUS_DIR    := RTL/bus
SOC_DIR    := RTL/soc
PERIPH_DIR := RTL/peripherals
SDRAM_DIR  := $(PERIPH_DIR)/sdram
UART_DIR   := $(PERIPH_DIR)/uart16550
CLINT_DIR  := $(PERIPH_DIR)/clint
GPIO_DIR   := $(PERIPH_DIR)/gpio
FPGA_DIR   := RTL/fpga/tang_nano_20k
SIM_DIR    := RTL/sim
TEST_DIR   := tests/rv32i
TRAP_DIR   := $(TEST_DIR)/traps
BIOS_DIR   := firmware/bios
SCRIPT_DIR := scripts

BUILD_DIR  := build
OBJ_DIR    := $(BUILD_DIR)/obj_dir
TRACE_DIR  := $(BUILD_DIR)/obj_dir_trace
SOC_OBJ    := $(BUILD_DIR)/obj_soc
TESTBIN    := $(BUILD_DIR)/tests
WAVE_DIR   := $(BUILD_DIR)/waves
FW_DIR     := $(BUILD_DIR)/firmware
FPGA_BUILD := $(BUILD_DIR)/fpga

# -----------------------------------------------------------------------------
# Sources
# -----------------------------------------------------------------------------
WAIVERS  := $(SIM_DIR)/verilator_waivers.vlt
# Work in progress that is not wired into the design yet.
#
# RTL/core is globbed, so anything dropped in there joins every build and every
# lint immediately - and lint treats warnings as errors. That means an unfinished
# draft stops the whole regression, which is exactly backwards: a draft should be
# free to be broken.
#
# List drafts here and they are excluded until they are ready. Promoting one is
# deleting a line.
# Nothing is excluded any more: cache.v and MMU.v both build. The originals are
# in RTL/core/drafts/, which is outside this glob.
CORE_SRC := $(wildcard $(CORE_DIR)/*.v)

# Headers are dependencies too. They were not, and it cost a confusing hour: a
# change to CSRdefinitions.vh left every simulator binary stale, so a rebuilt
# design silently ran the old encodings. Verilator reads them through
# +incdir+, so make cannot infer them - they have to be listed.
CORE_HDRS := $(wildcard $(CORE_DIR)/*.vh)
BUS_HDRS  := $(wildcard $(BUS_DIR)/*.vh)
RTL_HDRS  := $(CORE_HDRS) $(BUS_HDRS)
SIM_SRC  := $(SIM_DIR)/soc_sim.v $(SIM_DIR)/tb_rv32i.v
ALL_SRC  := $(WAIVERS) $(CORE_SRC) $(SIM_SRC)
DEPS     := $(CORE_SRC) $(SIM_SRC) $(RTL_HDRS) $(WAIVERS)

TOP := tb_rv32i

# --- Full SoC: core + Wishbone + peripherals, shared by simulation and FPGA ---
BUS_SRC   := $(wildcard $(BUS_DIR)/*.v)
# Every peripheral directory, so adding a device needs no Makefile edit. The
# vendored reference tree under RTL/perepherical_reference is deliberately not
# swept: it holds whole third-party projects, not sources we build.
PERIPH_SRC := $(wildcard $(PERIPH_DIR)/*/*.v)
SDRAM_SRC := $(wildcard $(SDRAM_DIR)/*.v)
UART_SRC  := $(wildcard $(UART_DIR)/*.v)
SOC_SRC   := $(SOC_DIR)/soc_wb.v
SOC_TB    := $(SIM_DIR)/sdram_model.v $(SIM_DIR)/sd_model.v $(SIM_DIR)/tb_soc.v

SOC_ALL   := $(WAIVERS) $(CORE_SRC) $(BUS_SRC) $(SOC_SRC) \
             $(PERIPH_SRC) $(SOC_TB)
# build/fpga is on this list because wb_defines.vh includes the generated
# clk_config.vh from there. Miss it off any one tool and that tool alone fails
# with "cannot find include file", which reads as a broken checkout.
SOC_INC   := +incdir+$(CORE_DIR) +incdir+$(BUS_DIR) +incdir+$(UART_DIR) +incdir+$(FPGA_BUILD)
SOC_TOP   := tb_soc
SOC_BIN   := $(SOC_OBJ)/sim_soc

# -----------------------------------------------------------------------------
# Tools
# -----------------------------------------------------------------------------
VERILATOR  := verilator
GTKWAVE    := gtkwave

# --- Gowin. The IDE ships its own Qt, which clashes with the system's, and
#     gw_sh insists on a GUI platform unless pointed at the offscreen one.
GOWIN_HOME ?= $(HOME)/Electronics_tools/Gowin_EDA/IDE
GW_SH      := $(GOWIN_HOME)/bin/gw_sh
GOWIN_ENV  := env -u DISPLAY -u WAYLAND_DISPLAY -u XDG_SESSION_TYPE \
              LD_LIBRARY_PATH=$(GOWIN_HOME)/lib \
              QT_QPA_PLATFORM=offscreen \
              QT_PLUGIN_PATH=$(GOWIN_HOME)/plugins/qt \
              QT_QPA_PLATFORM_PLUGIN_PATH=$(GOWIN_HOME)/plugins/qt/platforms

LOADER     := openFPGALoader
BOARD      := tangnano20k
BITSTREAM  := $(FPGA_BUILD)/impl/pnr/custom_riscv.fs

# --- Serial. Interface 01 of the on-board FT2232 is the UART; 00 is JTAG.
PORT       ?= /dev/ttyUSB1
BAUD       ?= 38400
MON_SECS   ?= 750000

CROSS      := riscv64-unknown-elf-
CC         := $(CROSS)gcc
OBJCOPY    := $(CROSS)objcopy
OBJDUMP    := $(CROSS)objdump

VFLAGS     := --binary --timing --top-module $(TOP) +incdir+$(CORE_DIR) +incdir+$(BUS_DIR) +incdir+$(FPGA_BUILD) -Wall
SIM_BIN    := $(OBJ_DIR)/sim_rv32i
TRACE_BIN  := $(TRACE_DIR)/sim_rv32i_trace

# rv32i, freestanding, no standard runtime
# Zicsr became a separate extension letter, so the assembler needs it named
# explicitly before it will accept csrrw and friends. Zifencei joined it when
# FENCE.I stopped being a no-op: with an instruction cache in the design, a
# program that writes instructions has to be able to say so.
#
# Neither appears in misa. The Z extensions are not represented there, so the
# value stays 0x4014_1101 - claiming a bit for these would be claiming a bit
# that means something else.
ARCH_FLAGS := -march=rv32ima_zicsr_zifencei -mabi=ilp32

# --- BIOS firmware ------------------------------------------------------------
BIOS_SRC  := $(BIOS_DIR)/crt0.S $(BIOS_DIR)/main.c \
             $(BIOS_DIR)/sdcard.c $(BIOS_DIR)/fat32.c $(BIOS_DIR)/boot.c \
             $(BIOS_DIR)/uart.c  $(BIOS_DIR)/memtest.c $(BIOS_DIR)/trap.c
BIOS_HDRS := $(wildcard $(BIOS_DIR)/*.h)
BIOS_LD   := $(BIOS_DIR)/bios.ld
BOOT_BYTES := 32768

BIOS_CFLAGS := $(ARCH_FLAGS) -Os -g -ffreestanding -nostdlib -nostartfiles \
               -fno-builtin -Wall -Wextra -I$(BIOS_DIR)
# -lgcc supplies the compiler support routines: RV32 has no 64-bit divide
# instruction, so printing a 64-bit counter in decimal needs __udivdi3 and
# __umoddi3. -nostdlib suppresses the automatic -lgcc, so it goes back
# explicitly. This is libgcc, not libc - no runtime, no syscalls.
BIOS_LDFLAGS := -T $(BIOS_LD) -Wl,--no-warn-rwx-segments
# Libraries go after the objects: the linker resolves left to right, so -lgcc
# placed with the other flags is searched before anything needs it.
BIOS_LIBS := -lgcc

# Hardware runs the link at 38400 and tests every word.
# CLK18 is sticky, for exactly the reason SDBOOT is.
#
# A bare command-line variable leaves no trace in any file, so make cannot see
# that it changed and a later `make prog` re-evaluates it as unset. That cost a
# bring-up session once already with SDBOOT: `make board` silently rebuilt the
# BIOS in the other mode and programmed it. Repeating it here was worse,
# because the failure is a garbled console rather than a missing feature - the
# BIOS prints at the clock it was compiled for, then OpenSBI reprograms the
# divisor from a device tree describing a different clock, and everything after
# the BIOS banner is noise.
#
# DRY_RUN is defined further down with the SDBOOT block, so this file is read
# but only written by a real invocation.
CLK18_FILE := $(FPGA_BUILD)/.clk18
ifeq ($(origin CLK18),undefined)
CLK18 := $(shell cat $(CLK18_FILE) 2>/dev/null)
else
ifeq ($(findstring n,$(firstword -$(MAKEFLAGS))),)
$(shell mkdir -p $(FPGA_BUILD); printf '%s' '$(CLK18)' > $(CLK18_FILE))
endif
endif

# CLK18=1 builds the board at 18 MHz instead of 24. One define reaches both the
# RTL (via wb_defines.vh) and the PLL, and SOC_CLK_HZ below follows it so the
# reported margin and the device tree agree with the silicon.
ifeq ($(CLK18),1)
SOC_CLK_HZ ?= 18000000
CLK_CONFIG := `define CLK18
else
SOC_CLK_HZ ?= 24000000
CLK_CONFIG := // 24 MHz: CLK18 not defined
endif

# Written whenever it would change, so switching the clock actually rebuilds.
# The comparison value is single-quoted, not double: CLK_CONFIG contains a
# backtick (Verilog's define prefix), and inside double quotes the shell treats
# that as command substitution and dies with "unexpected EOF".
# Not a phony recipe: this has to exist before synthesis reads wb_defines.vh.
CLK_CONFIG_FILE := $(FPGA_BUILD)/clk_config.vh
ifeq ($(DRY_RUN),)
$(shell mkdir -p $(FPGA_BUILD))
$(shell [ "$$(cat $(CLK_CONFIG_FILE) 2>/dev/null)" = '$(CLK_CONFIG)' ] || \
        printf '%s\n' '$(CLK_CONFIG)' > $(CLK_CONFIG_FILE))
endif

# HW_DEFS below expands SOC_CLK_HZ immediately (:=), so the clock block has to
# come first. It used to sit 1100 lines further down, which expanded to
# -DCPU_HZ=u and would have failed the BIOS compile.
HW_DEFS  := -DBAUD=38400u    -DMEMTEST_STRIDE=1    -DSTARTUP_DELAY_MS=1500u \
            -DCPU_HZ=$(SOC_CLK_HZ)u
# Simulation transmits at the real bit rate, so 400 characters at 38400 baud
# would be 113 ms of simulated time. A divisor of 1 gives 1.6875 Mbaud, and a
# stride samples the array instead of walking two million words.
SIM_DEFS := -DBAUD=1500000u  -DMEMTEST_STRIDE=8192 -DSTARTUP_DELAY_MS=0u -DSIMULATION
CFLAGS     := $(ARCH_FLAGS) -O0 -g -nostdlib -nostartfiles -ffreestanding \
              -x assembler-with-cpp -I$(TEST_DIR)
LDFLAGS    := -T $(TEST_DIR)/test.ld -Wl,--no-warn-rwx-segments
# The SoC's boot memory is half the size the core-only testbench models
SOC_LDFLAGS := -T $(TEST_DIR)/soc.ld -Wl,--no-warn-rwx-segments

# -----------------------------------------------------------------------------
# Test inventory. Functional tests expect a0 == 0; trap tests expect a specific
# mcause, given after the colon.
# -----------------------------------------------------------------------------
FUNC_TESTS := 01_raw_alu 02_branches 03_jumps 04_loadstore 05_hazard_stress \
              06_muldiv 07_muldiv_random 08_csr 09_traps 12_atomics 13_privilege \
              14_trap_timing 15_fence
TRAP_TESTS := trap_illegal:2 trap_load_misaligned:4 \
              trap_store_misaligned:6 trap_jump_misaligned:0 \
              trap_csr_nonexistent:2 trap_csr_readonly:2

FUNC_HEX := $(addprefix $(TESTBIN)/,$(addsuffix .hex,$(FUNC_TESTS)))
TRAP_HEX := $(addprefix $(TESTBIN)/,$(addsuffix .hex,$(basename $(subst :,.,$(TRAP_TESTS)))))

# Default program for the sim targets when no path is given on the command line
DEFAULT_PROG := $(TESTBIN)/05_hazard_stress.hex

# Overridable knobs
TIMEOUT ?= 200000
TRACE   ?= 0
VCD     ?= $(WAVE_DIR)/wave.vcd

TRACE_ARG := $(if $(filter-out 0,$(TRACE)),+trace,)

# -----------------------------------------------------------------------------
# Program argument capture.
#
# "make sim_no_graphics_rv32I /path/to/bin/riscv" hands the path to make as a
# second goal. Pick it up here and neutralise it so make does not try to build
# it. A PROG=<path> variable works too.
# -----------------------------------------------------------------------------
SIM_GOALS := sim_no_graphics_rv32I sim_graphics_rv32I
ifneq ($(filter $(SIM_GOALS),$(MAKECMDGOALS)),)
  EXTRA_GOALS := $(filter-out $(SIM_GOALS),$(MAKECMDGOALS))
  ifneq ($(EXTRA_GOALS),)
    PROG ?= $(firstword $(EXTRA_GOALS))
    # Declared phony so make neither tries to build the path nor announces it
    .PHONY: $(EXTRA_GOALS)
    $(foreach g,$(EXTRA_GOALS),$(eval $(g): ; @:))
  endif
endif
PROG ?=

.PHONY: help all sim verilate verilate-trace tests trap-tests test check run-soc \
        test-soc-tests test-plic test-dcache test-mmu \
        sim_no_graphics_rv32I sim_graphics_rv32I lint dump run wave clean distclean \
        regen-random bios bios-sim soc verilate-soc test-soc wave-soc \
        sdimage fpga-check-nets linux-sim sdcard \
        fpga prog flash monitor board board-clean fpga-report \
        opensbi opensbi-sim dtb

# -----------------------------------------------------------------------------
# Help
# -----------------------------------------------------------------------------
help:
	@echo ''
	@echo 'custom_riscv - RV32IM core, Wishbone SoC, Tang Nano 20K'
	@echo ''
	@echo 'Primary targets'
	@echo '  make sim_no_graphics_rv32I /path/to/bin/riscv'
	@echo '        Build the testbench and run the given program in batch mode.'
	@echo '        The program may be an ELF, a raw binary or a hex image; the'
	@echo '        type is detected automatically. With no path, runs'
	@echo '        $(DEFAULT_PROG).'
	@echo ''
	@echo '  make sim_graphics_rv32I /path/to/bin/riscv'
	@echo '        Same, but with waveform tracing enabled, then opens gtkwave'
	@echo '        on the resulting VCD.'
	@echo ''
	@echo 'Test suite'
	@echo '  make test              Build and run every test, print a summary'
	@echo '  make tests             Build the test programs only'
	@echo '  make run TEST=<name>   Run one test, e.g. TEST=02_branches'
	@echo '  make wave TEST=<name>  Run one test with tracing, open gtkwave'
	@echo '  make dump TEST=<name>  Disassemble one test program'
	@echo '  make regen-random      Regenerate the randomised RV32M test'
	@echo '                         CASES=<n> SEED=<n> to change coverage'
	@echo '  make test-dcache       Cache unit testbench, plus its own memory model'
	@echo '  make test-plic         PLIC unit testbench, driven directly rather'
	@echo '                         than through the bus, for cycle-level checks'
	@echo ''
	@echo 'SoC simulation  (core + Wishbone + SDRAM model + real UART)'
	@echo '  make soc               Build the BIOS and run the whole SoC in simulation'
	@echo '  make wave-soc          Same, with a waveform, then gtkwave'
	@echo '  make test-soc          SoC simulation as a pass/fail regression'
	@echo ''
	@echo 'OpenSBI  (simulation only)'
	@echo '  make opensbi           Clone and build OpenSBI for this SoC'
	@echo '  make dtb               Compile the device tree'
	@echo '  make opensbi-sim       Boot OpenSBI in the SoC simulation and hand'
	@echo '                         off to S-mode. BOOT_NEXT_MODE=0 for U-mode.'
	@echo ''
	@echo '  make sdimage           Build the simulated FAT32 SD card image'
	@echo '                         SD_SECRET=file to place it as CLAUDE.TXT'
	@echo ''
	@echo 'Hardware  (Tang Nano 20K)'
	@echo '  make board             Synthesise, program and open the serial monitor'
	@echo '  make bios              Build the BIOS for hardware'
	@echo '  make fpga              Synthesis and place-and-route only'
	@echo '  make prog              Load the bitstream into SRAM (volatile)'
	@echo '  make flash             Write the bitstream to flash (survives power off)'
	@echo '  make monitor           Watch the serial port'
	@echo '  make fpga-report       Resource usage and timing summary'
	@echo ''
	@echo 'Build and checks'
	@echo '  make verilate          Build the batch simulator'
	@echo '  make verilate-trace    Build the tracing simulator'
	@echo '  make lint              Verilator lint of the RTL, -Wall'
	@echo '  make clean             Remove build products (keeps the FPGA build and'
	@echo '                         the OpenSBI clone, both slow to regenerate)'
	@echo '  make board-clean       Remove the FPGA build'
	@echo '  make distclean         Remove everything under build/'
	@echo ''
	@echo 'Variables'
	@echo '  PROG=<path>            Program to run, instead of a bare argument'
	@echo '  TIMEOUT=<cycles>       Simulation cycle limit (default $(TIMEOUT))'
	@echo '  TRACE=1                Print every retired instruction'
	@echo '  VCD=<file>             Waveform output path (default $(VCD))'
	@echo '  PORT=<dev>             Serial port (default $(PORT))'
	@echo '  BAUD=<n>               Serial baud (default $(BAUD))'
	@echo '  MON_SECS=<n>           How long `make monitor` listens (default $(MON_SECS))'
	@echo '  GOWIN_HOME=<path>      Gowin IDE location'
	@echo ''
	@echo 'Available tests'
	@echo '  functional : $(FUNC_TESTS)'
	@echo '  traps      : $(foreach t,$(TRAP_TESTS),$(firstword $(subst :, ,$(t))))'
	@echo '  soc only   : $(SOC_ONLY_TESTS)'
	@echo '               (need real bus latency, a CLINT or a PLIC; run with'
	@echo '                make run-soc TEST=<name>)'
	@echo ''

all: verilate tests

# -----------------------------------------------------------------------------
# Verilator builds
# -----------------------------------------------------------------------------
verilate: $(SIM_BIN)
sim: $(SIM_BIN)

$(SIM_BIN): $(DEPS)
	@mkdir -p $(OBJ_DIR)
	$(VERILATOR) $(VFLAGS) -Mdir $(OBJ_DIR) -o $(notdir $(SIM_BIN)) $(ALL_SRC)

verilate-trace: $(TRACE_BIN)

$(TRACE_BIN): $(DEPS)
	@mkdir -p $(TRACE_DIR)
	$(VERILATOR) $(VFLAGS) --trace -Mdir $(TRACE_DIR) -o $(notdir $(TRACE_BIN)) $(ALL_SRC)

# Two passes: the synthesisable SoC on its own, then the whole thing including
# the behavioural testbench.
lint:
	@echo '--- lint: core + SoC (synthesisable) ---'
	$(VERILATOR) --lint-only -Wall --top-module soc_sim +incdir+$(CORE_DIR) \
	    +incdir+$(BUS_DIR) +incdir+$(FPGA_BUILD) \
	    $(WAIVERS) $(CORE_SRC) $(SIM_DIR)/soc_sim.v
	@echo '--- lint: full design + testbench ---'
	$(VERILATOR) --lint-only -Wall --timing --top-module $(TOP) \
	    +incdir+$(CORE_DIR) +incdir+$(BUS_DIR) +incdir+$(FPGA_BUILD) $(ALL_SRC)
	@echo 'lint: clean'

# -----------------------------------------------------------------------------
# Test programs
# -----------------------------------------------------------------------------
tests: $(FUNC_HEX) $(TRAP_HEX)

$(TESTBIN)/%.elf: $(TEST_DIR)/%.S $(TEST_DIR)/test_macros.h $(TEST_DIR)/test.ld
	@mkdir -p $(TESTBIN)
	$(CC) $(CFLAGS) $(LDFLAGS) $< -o $@

$(TESTBIN)/%.elf: $(TRAP_DIR)/%.S $(TEST_DIR)/test_macros.h $(TEST_DIR)/test.ld
	@mkdir -p $(TESTBIN)
	$(CC) $(CFLAGS) $(LDFLAGS) $< -o $@

$(TESTBIN)/%.hex: $(TESTBIN)/%.elf
	$(OBJCOPY) -O verilog $< $@

# --- The same tests, linked for and run inside the full SoC ------------------
# Hazards that depend on a stalled memory access cannot be observed with
# zero-latency memory, so the hazard-sensitive tests are run over the Wishbone
# bus as well as against the bare core.
$(TESTBIN)/soc_%.elf: $(TEST_DIR)/%.S $(TEST_DIR)/test_macros.h $(TEST_DIR)/soc.ld
	@mkdir -p $(TESTBIN)
	$(CC) $(CFLAGS) $(SOC_LDFLAGS) $< -o $@

$(TESTBIN)/soc_%.wordhex: $(TESTBIN)/soc_%.elf
	$(OBJCOPY) -O binary $< $(basename $@).bin
	$(SCRIPT_DIR)/bin_to_wordhex.py $(basename $@).bin $@ $(BOOT_BYTES)

.PRECIOUS: $(TESTBIN)/soc_%.elf

.PRECIOUS: $(TESTBIN)/%.elf

# -----------------------------------------------------------------------------
# BIOS firmware
#
# Two configurations from one source tree: HW_DEFS for the board, SIM_DEFS for
# simulation. Both produce a word-oriented image, which is what wb_ram loads
# whether it is a simulation memory or a synthesised block RAM - so hardware and
# simulation run byte-identical firmware.
# -----------------------------------------------------------------------------
bios:     $(FPGA_BUILD)/bios.wordhex
bios-sim: $(FW_DIR)/bios_sim.wordhex

# SDBOOT=1 builds the BIOS as a boot loader: after the self tests it mounts the
# card, reads BOOT.TXT and loads whatever that names into SDRAM, then hands off.
# Without it the BIOS ends in the LED demo, which is the right default for
# bring-up - a board that always tries to boot an OS is a board you cannot test.
#
# Makefile is a dependency because SDBOOT arrives as a -D flag defined here.
# The boot mode is sticky, and it has to be.
#
# `prog` and `board` depend on the bitstream, so a bare `make board` after a
# `make fpga SDBOOT=1` re-evaluates SDBOOT as empty, rebuilds the BIOS in the
# other mode, re-synthesises and programs *that* - silently. The board then runs
# firmware nobody asked for and the only symptom is that it behaves like an
# older build. Requiring every target to repeat the flag is not a fix; it is the
# bug waiting to happen again.
#
# So the choice is remembered. Pass SDBOOT=1 once to turn it on, SDBOOT=0 to
# turn it off, and nothing afterwards needs to know.
DRY_RUN     := $(findstring n,$(firstword -$(MAKEFLAGS)))
SDBOOT_FILE := $(FPGA_BUILD)/.sdboot
ifeq ($(origin SDBOOT),undefined)
SDBOOT := $(shell cat $(SDBOOT_FILE) 2>/dev/null)
else
ifeq ($(DRY_RUN),)
$(shell mkdir -p $(FPGA_BUILD); printf '%s' '$(SDBOOT)' > $(SDBOOT_FILE))
endif
endif

ifeq ($(SDBOOT),1)
BOOT_DEFS := -DBOOT_FROM_SD
else
BOOT_DEFS :=
endif

# The build variant has to be part of the dependency graph, because a
# command-line variable is not.
#
# make compares timestamps, and SDBOOT leaves no trace in any file. So both
# `make fpga` and `make fpga SDBOOT=1` find bios.elf newer than its sources and
# do nothing - the bitstream keeps whichever BIOS happened to be built last, and
# switching modes silently has no effect. Which BIOS is in a given bitstream then
# becomes unknowable from the outside, and that is exactly how an afternoon gets
# spent wondering why the board is running the previous firmware.
#
# So the flags are written to a file whose contents change when they do, and
# bios.elf depends on it.
BIOS_FLAGS      := $(HW_DEFS) $(BOOT_DEFS)
BIOS_FLAGS_FILE := $(FPGA_BUILD)/.bios_flags
#
# Not under -n. $(shell) runs while the Makefile is parsed, which means a dry
# run would rewrite the stamp and schedule a real rebuild for next time - a
# `make -n` that changes what `make` will do is worse than no dry run at all.
# This was found the hard way: inspecting the build with -n is what left the
# bitstream carrying a BIOS built with the other flags.
ifeq ($(DRY_RUN),)
$(shell mkdir -p $(FPGA_BUILD))
$(shell [ "$$(cat $(BIOS_FLAGS_FILE) 2>/dev/null)" = "$(BIOS_FLAGS)" ] || \
        printf '%s' '$(BIOS_FLAGS)' > $(BIOS_FLAGS_FILE))
endif

$(FPGA_BUILD)/bios.elf: $(BIOS_SRC) $(BIOS_HDRS) $(BIOS_LD) Makefile \
                        $(BIOS_FLAGS_FILE)
	@mkdir -p $(FPGA_BUILD)
	$(CC) $(BIOS_CFLAGS) $(HW_DEFS) $(BOOT_DEFS) $(BIOS_LDFLAGS) \
	    -Wl,-Map=$(FPGA_BUILD)/bios.map $(BIOS_SRC) $(BIOS_LIBS) -o $@
	@$(CROSS)size $@

$(FW_DIR)/bios_sim.elf: $(BIOS_SRC) $(BIOS_HDRS) $(BIOS_LD) Makefile
	@mkdir -p $(FW_DIR)
	$(CC) $(BIOS_CFLAGS) $(SIM_DEFS) $(BOOT_DEFS) $(BIOS_LDFLAGS) \
	    -Wl,-Map=$(FW_DIR)/bios_sim.map $(BIOS_SRC) $(BIOS_LIBS) -o $@
	@$(CROSS)size $@

%.wordhex: %.elf
	$(OBJCOPY) -O binary $< $(basename $@).bin
	$(SCRIPT_DIR)/bin_to_wordhex.py $(basename $@).bin $@ $(BOOT_BYTES)

.PRECIOUS: $(FPGA_BUILD)/bios.elf $(FW_DIR)/bios_sim.elf \
           $(FW_DIR)/bios_boot.elf

# -----------------------------------------------------------------------------
# SoC simulation
# -----------------------------------------------------------------------------
verilate-soc: $(SOC_BIN)

# -Wno-fatal, not -Wall: the vendored uart16550 and the derived SDRAM controller
# are older Verilog and trip dozens of style rules. The core and the bus are
# still linted strictly by the `lint` target.
#
# PINMISSING is the one exception, promoted back to an error. An unconnected
# input port is never intentional, and it fails silently: the port reads as zero
# and the design merely behaves wrongly. That is exactly how the CLINT's
# interrupt pins ended up disconnected from the core, costing a debug session
# for something the tool already knew.
#
# $(CLK_CONFIG_FILE) is a prerequisite because the testbench and soc_wb take
# SOC_CLK_HZ from it. It was missing, so a CLK18 round trip left an 18 MHz
# simulator behind a 24 MHz BIOS and device tree, and `make linux-sim` printed
# nothing but noise from the first byte (1.5 Mbaud is divisor 1 only at 24 MHz).
#
# SOC_VOPT: measured 1.47x on the Linux boot (97.5 s -> 66.1 s per 10 M cycles),
# UART output byte-identical. --threads was tried and is slower (28.8 s vs
# 20.1 s per 3 M cycles): the design is small and the time goes to the timing
# scheduler, not to logic. Most of the remaining cost is the `#` delays in the
# testbench and models (~59 delay events per clock cycle under gprof).
SOC_VOPT ?= -O3 --x-assign fast --x-initial fast -CFLAGS "-O3 -march=native" \
            --build-jobs $(shell nproc)
$(SOC_BIN): $(CORE_SRC) $(BUS_SRC) $(SOC_SRC) $(PERIPH_SRC) $(SOC_TB) \
            $(RTL_HDRS) $(WAIVERS) $(CLK_CONFIG_FILE)
	@mkdir -p $(SOC_OBJ)
	$(VERILATOR) --binary --timing --top-module $(SOC_TOP) $(SOC_INC) \
	    -Wno-fatal -Werror-PINMISSING $(SOC_VOPT) \
	    -Mdir $(SOC_OBJ) -o $(notdir $(SOC_BIN)) $(SOC_ALL)

# -----------------------------------------------------------------------------
# PLIC unit testbench.
#
# Separate from the SoC run because it drives the device directly, which is the
# only way to reach properties that live inside a single clock cycle - over the
# bus a program cannot place an event in a chosen cycle. Seconds to build and
# instant to run, so it belongs in the default `test`.
# -----------------------------------------------------------------------------
DCACHE_TB  := $(SIM_DIR)/tb_dcache.v
DCACHE_OBJ := $(BUILD_DIR)/obj_dcache
DCACHE_BIN := $(DCACHE_OBJ)/sim_dcache

$(DCACHE_BIN): $(CORE_DIR)/cache.v $(DCACHE_TB) $(RTL_HDRS) $(WAIVERS)
	@mkdir -p $(DCACHE_OBJ)
	$(VERILATOR) --binary --timing --top-module tb_dcache +incdir+$(CORE_DIR) \
	    +incdir+$(BUS_DIR) +incdir+$(FPGA_BUILD) \
	    -Wall $(WAIVERS) -Mdir $(DCACHE_OBJ) -o $(notdir $(DCACHE_BIN)) \
	    $(CORE_DIR)/cache.v $(DCACHE_TB)

.PHONY: test-dcache
test-dcache: $(DCACHE_BIN)
	@$(DCACHE_BIN)

# The same SoC with DCACHE=0, so a measurement can be attributed. Separate
# object directory: sharing one would rebuild on every switch and, worse, race.
SOC_NC_OBJ := $(BUILD_DIR)/obj_soc_nocache
SOC_NC_BIN := $(SOC_NC_OBJ)/sim_soc_nocache

$(SOC_NC_BIN): $(CORE_SRC) $(BUS_SRC) $(SOC_SRC) $(PERIPH_SRC) $(SOC_TB) \
               $(RTL_HDRS) $(WAIVERS)
	@mkdir -p $(SOC_NC_OBJ)
	$(VERILATOR) --binary --timing --top-module $(SOC_TOP) $(SOC_INC) \
	    -Wno-fatal -Werror-PINMISSING -GDCACHE=0 \
	    -Mdir $(SOC_NC_OBJ) -o $(notdir $(SOC_NC_BIN)) $(SOC_ALL)

.PHONY: soc-nocache
soc-nocache: $(SOC_NC_BIN) $(FW_DIR)/bios_sim.wordhex $(SD_IMG_HEX)
	$(SOC_NC_BIN) +hex=$(FW_DIR)/bios_sim.wordhex +baud=1500000 \
	    +timeout=$(SOC_TIMEOUT) $(TRACE_ARG)

MMU_TB   := $(SIM_DIR)/tb_mmu.v
MMU_OBJ  := $(BUILD_DIR)/obj_mmu
MMU_BIN  := $(MMU_OBJ)/sim_mmu

$(MMU_BIN): $(CORE_DIR)/MMU.v $(MMU_TB) $(RTL_HDRS) $(WAIVERS)
	@mkdir -p $(MMU_OBJ)
	$(VERILATOR) --binary --timing --top-module tb_mmu +incdir+$(CORE_DIR) \
	    -Wall $(WAIVERS) -Mdir $(MMU_OBJ) -o $(notdir $(MMU_BIN)) \
	    $(CORE_DIR)/MMU.v $(MMU_TB)

.PHONY: test-mmu
test-mmu: $(MMU_BIN)
	@$(MMU_BIN)

PLIC_TB   := $(SIM_DIR)/tb_plic.v
PLIC_OBJ  := $(BUILD_DIR)/obj_plic
PLIC_BIN  := $(PLIC_OBJ)/sim_plic

$(PLIC_BIN): $(PERIPH_DIR)/plic/plic_wb.v $(PLIC_TB) $(RTL_HDRS) $(WAIVERS)
	@mkdir -p $(PLIC_OBJ)
	$(VERILATOR) --binary --timing --top-module tb_plic +incdir+$(BUS_DIR) +incdir+$(FPGA_BUILD) \
	    -Wall $(WAIVERS) -Mdir $(PLIC_OBJ) -o $(notdir $(PLIC_BIN)) \
	    $(PERIPH_DIR)/plic/plic_wb.v $(PLIC_TB)

.PHONY: test-plic
test-plic: $(PLIC_BIN)
	@$(PLIC_BIN)


# -----------------------------------------------------------------------------
# OpenSBI, in simulation only.
#
# OpenSBI is ~280 KB of text, so it cannot live in the 32 KB boot RAM - it runs
# from SDRAM, and something has to put it there. On hardware that will be the SD
# card loader; here the testbench preloads the SDRAM model, which is the same
# handoff with a different courier.
#
# The bare-metal toolchain cannot build it: mainline OpenSBI requires a linker
# that can produce PIEs and riscv64-unknown-elf-ld cannot. The Buildroot rv32
# Linux toolchain can, so that one is used for OpenSBI and only for OpenSBI -
# the core, the BIOS and the tests all still build with riscv64-unknown-elf.
# -----------------------------------------------------------------------------
OPENSBI_DIR  := $(BUILD_DIR)/opensbi
OPENSBI_SRC  := $(OPENSBI_DIR)/src
OPENSBI_REPO := https://github.com/riscv-software-src/opensbi
# fw_dynamic, not fw_payload: it lets this loader name the next privilege mode,
# which is what makes the cold-boot lottery pass on a hart without S-mode. See
# boot_next_stage() in firmware/bios/main.c.
OPENSBI_FW   := $(OPENSBI_SRC)/build/platform/generic/firmware/fw_dynamic.bin

# Override if the toolchain lives elsewhere.
BR_TOOLCHAIN ?= $(HOME)/Electronics_tools/Buildroot/buildroot-2026.02/output/host/bin
BR_PREFIX    ?= riscv32-buildroot-linux-gnu-

# Where each blob is loaded. OpenSBI's own footprint runs to about 0x84000, so
# the device tree sits a comfortable megabyte clear of it.
OPENSBI_LOAD := 80000000
DTB_LOAD     := 80100000

# -----------------------------------------------------------------------------
# Booting Linux: a different memory map, forced by one line of kernel source.
#
# On RV32 the kernel maps its own text with Sv32 megapages, so setup_vm insists
# the load address is 4 MiB aligned (arch/riscv/mm/init.c, best_map_size returns
# PMD_SIZE). With 8 MiB of SDRAM at 0x8000_0000 that leaves exactly two legal
# slots - 0x8000_0000 and 0x8040_0000 - and a 4.15 MB Image only fits in the
# first. So the kernel takes the base of memory and OpenSBI moves up, which is
# the reverse of the usual arrangement and the reason for a separate build.
#
# OpenSBI goes at the *top* of memory and the device tree tells Linux the machine
# has 7 MiB, not 8. Relying on OpenSBI's reserved-memory fixup instead was tried
# and did not hold: Linux allocated over the firmware and zeroed it, and the next
# SBI call trapped into a page of zeroes, raised an illegal instruction, vectored
# to mtvec, found zeroes again, and looped there forever. Excluding the region
# from the memory node leaves nothing to get wrong.
# -----------------------------------------------------------------------------
LINUX_LOAD      := 80000000
LINUX_INITRD_LOAD := 80400000
LINUX_DTB_LOAD  := 806F0000
LINUX_SBI_LOAD  := 80700000

BUILDROOT   ?= $(HOME)/Electronics_tools/Buildroot/buildroot-2026.02
LINUX_IMAGE ?= $(BUILDROOT)/output/images/Image

DTB          := $(FW_DIR)/custom_riscv.dtb
DTB_SIM      := $(FW_DIR)/custom_riscv_sim.dtb
DTS          := firmware/dts/custom_riscv.dts

$(DTB): $(DTS)
	@mkdir -p $(FW_DIR)
	dtc -I dts -O dtb -o $@ $<
	@echo "dtb: $$(stat -c %s $@) bytes"

# The simulation device tree differs in exactly one value: the console baud.
#
# Simulation transmits at the real bit rate, so 38400 baud makes a few hundred
# characters dominate the entire run - which is why the simulation BIOS uses a
# divisor of 1. A next-stage firmware reprograms the UART from `current-speed`
# in the device tree, so unless that says the same thing, it starts transmitting
# at 38400 into a testbench still decoding at 1.6875 Mbaud. The symptom is a
# character count that climbs while nothing legible appears, which reads like a
# dead console rather than a baud mismatch.
$(DTB_SIM): $(DTS)
	@mkdir -p $(FW_DIR)
	sed 's/current-speed = <38400>/current-speed = <1500000>/' $< > $(FW_DIR)/custom_riscv_sim.dts
	dtc -I dts -O dtb -o $@ $(FW_DIR)/custom_riscv_sim.dts
	@echo "dtb (sim): $$(stat -c %s $@) bytes"

.PHONY: dtb
dtb: $(DTB) $(DTB_SIM)

# Cloned rather than vendored: third-party source does not belong in this tree,
# and build/ is what `make distclean` removes.
$(OPENSBI_SRC)/Makefile:
	@mkdir -p $(OPENSBI_DIR)
	git clone --depth 1 $(OPENSBI_REPO) $(OPENSBI_SRC)

# OpenSBI linked high, for the Linux map above. Built into its own directory so
# it does not fight the 0x8000_0000 build over object files.
OPENSBI_FW_LINUX := $(OPENSBI_SRC)/build-linux/platform/generic/firmware/fw_dynamic.bin

$(OPENSBI_FW_LINUX): $(OPENSBI_SRC)/Makefile
	@test -x $(BR_TOOLCHAIN)/$(BR_PREFIX)gcc || { \
	    echo 'No rv32 Linux toolchain at $(BR_TOOLCHAIN).'; exit 1; }
	PATH=$(BR_TOOLCHAIN):$$PATH $(MAKE) -C $(OPENSBI_SRC) \
	    O=build-linux \
	    PLATFORM=generic CROSS_COMPILE=$(BR_PREFIX) \
	    PLATFORM_RISCV_XLEN=32 PLATFORM_RISCV_ABI=ilp32 \
	    PLATFORM_RISCV_ISA=rv32ima_zicsr_zifencei \
	    FW_TEXT_START=0x$(LINUX_SBI_LOAD)
	@ls -l $@

$(OPENSBI_FW): $(OPENSBI_SRC)/Makefile
	@test -x $(BR_TOOLCHAIN)/$(BR_PREFIX)gcc || { \
	    echo 'No rv32 Linux toolchain at $(BR_TOOLCHAIN).'; \
	    echo 'OpenSBI needs a linker that can make PIEs; the bare-metal one cannot.'; \
	    echo 'Set BR_TOOLCHAIN=<dir> to point at one.'; exit 1; }
	PATH=$(BR_TOOLCHAIN):$$PATH $(MAKE) -C $(OPENSBI_SRC) \
	    PLATFORM=generic CROSS_COMPILE=$(BR_PREFIX) \
	    PLATFORM_RISCV_XLEN=32 PLATFORM_RISCV_ABI=ilp32 \
	    PLATFORM_RISCV_ISA=rv32ima_zicsr_zifencei \
	    FW_TEXT_START=0x$(OPENSBI_LOAD) FW_PAYLOAD_OFFSET=0x50000
	@ls -l $@

.PHONY: opensbi
opensbi: $(OPENSBI_FW)

# The BIOS built for a handoff instead of the LED demo.
#
# Makefile is a real dependency here, not clutter: the load addresses arrive as
# -D flags defined in this file, so changing one changes the binary without
# changing a source. This project has now been caught by that twice - a changed
# -march that did not trigger a rebuild, and moving the device tree while the
# BIOS carried on passing the old address in a1, which looks exactly like
# OpenSBI failing to parse a perfectly good tree.
$(FW_DIR)/bios_boot.elf: $(BIOS_SRC) $(BIOS_HDRS) $(BIOS_LD) Makefile
	@mkdir -p $(FW_DIR)
	$(CC) $(BIOS_CFLAGS) $(SIM_DEFS) \
	    -DBOOT_ENTRY=0x$(OPENSBI_LOAD)u -DBOOT_DTB=0x$(DTB_LOAD)u -DBOOT_DYNAMIC \
	    -DBOOT_NEXT_MODE=$(BOOT_NEXT_MODE)u \
	    $(BIOS_LDFLAGS) -Wl,-Map=$(FW_DIR)/bios_boot.map \
	    $(BIOS_SRC) $(BIOS_LIBS) -o $@
	@$(CROSS)size $@

# -----------------------------------------------------------------------------
# Booting Linux in simulation
#
# The images are placed in SDRAM by the testbench rather than read off the SD
# card, and that is a deliberate split rather than a shortcut. A 4 MB kernel is
# 8 192 sectors over a 6 MHz SPI link: about 5.6 seconds of simulated time, which
# is billions of cycles. The loader is tested against small files; the kernel is
# tested against the machine. Trying to do both at once tests neither.
# -----------------------------------------------------------------------------
LINUX_DTS := firmware/dts/custom_riscv_linux.dts
LINUX_DTB := $(FW_DIR)/custom_riscv_linux.dtb

# An initrd is described by two properties in /chosen, and they are physical
# addresses - so they can only be filled in once the archive's size is known.
# dtc cannot do arithmetic, so the node is added here rather than written into
# the source tree with numbers that would go stale.
# Rebuilt on every run (FORCE), because initrd-end depends on which initrd
# LINUX_INITRD names and how big it is, and that variable is defined further
# down and can come from the command line - make cannot see it change. dtc
# takes milliseconds; a stale initrd-end has cost whole sessions.
.PHONY: FORCE
FORCE:
$(LINUX_DTB): $(LINUX_DTS) FORCE
	@mkdir -p $(FW_DIR)
	@# Simulation baud, as for $(DTB_SIM): the real bit rate makes 38400
	@# dominate the run, and OpenSBI reprograms the UART from this property.
	@#
	@# Only current-speed and console= are rewritten. earlycon carries no baud
	@# in the source tree at all, at either rate, because a command-line
	@# earlycon has no clock-frequency to read and invents one:
	@#
	@#   given a baud, parse_options() assumes uartclk = BASE_BAUD*16 = 1843200
	@#     at 38400   -> divisor 3 -> 500000 baud on our 24 MHz clock (13x fast)
	@#     at 1500000 -> divisor 0 -> a 16550 with divisor 0 emits nothing
	@#
	@# so there is no rate at which stating it is correct. Given no baud,
	@# early_serial8250_setup() skips init_port() and inherits the divisor the
	@# BIOS set, which is right at both rates. An earlier revision of this
	@# comment claimed hardware got away with divisor 3 "by luck"; it does not,
	@# and the board printed 13x-fast garbage from the first kernel character.
	@sed -e 's/current-speed = <38400>/current-speed = <1500000>/' \
	     -e 's/console=ttyS0,38400/console=ttyS0,1500000/' \
	     -e 's/clock-frequency = <24000000>/clock-frequency = <$(SOC_CLK_HZ)>/g' \
	     -e 's|rdinit=/init"|rdinit=/init$(if $(LINUX_BOOTARGS_EXTRA), $(LINUX_BOOTARGS_EXTRA))"|' \
	     $< > $(FW_DIR)/_lx.dts
	@if [ -n "$(LINUX_INITRD)" ] && [ -f "$(LINUX_INITRD)" ]; then \
	    end=$$(printf '0x%x' $$(( 0x$(LINUX_INITRD_LOAD) + $$(stat -c %s $(LINUX_INITRD)) ))); \
	    sed "s|bootargs = |linux,initrd-start = <0x$(LINUX_INITRD_LOAD)>;\n\t\tlinux,initrd-end = <$$end>;\n\t\tbootargs = |" \
	        $(FW_DIR)/_lx.dts > $(FW_DIR)/custom_riscv_linux.dts; \
	    echo "  initrd 0x$(LINUX_INITRD_LOAD) .. $$end"; \
	else \
	    echo "  WARNING: no initrd at '$(LINUX_INITRD)'"; \
	    echo "           /chosen will NOT describe one, so a kernel booted with"; \
	    echo "           rdinit= panics in mount_root_generic looking for a disk"; \
	    cp $(FW_DIR)/_lx.dts $(FW_DIR)/custom_riscv_linux.dts; \
	fi
	dtc -I dts -O dtb -o $@ $(FW_DIR)/custom_riscv_linux.dts
	@grep -q 'linux,initrd-end' $(FW_DIR)/custom_riscv_linux.dts \
	    || echo "  (device tree has no initrd - see the warning above)"
	@echo "linux dtb: $$(stat -c %s $@) bytes"

# The BIOS built to hand off to OpenSBI-at-0x80400000, which then enters the
# kernel at 0x80000000 in S-mode.
# Makefile is a real dependency here, not clutter: the load addresses arrive as
# -D flags defined in this file, so changing one changes the binary without
# changing a source. This project has now been caught by that twice - a changed
# -march that did not trigger a rebuild, and moving the device tree while the
# BIOS carried on passing the old address in a1, which looks exactly like
# OpenSBI failing to parse a perfectly good tree.
$(FW_DIR)/bios_linux.elf: $(BIOS_SRC) $(BIOS_HDRS) $(BIOS_LD) Makefile
	@mkdir -p $(FW_DIR)
	$(CC) $(BIOS_CFLAGS) $(SIM_DEFS) \
	    -DBOOT_ENTRY=0x$(LINUX_SBI_LOAD)u -DBOOT_DTB=0x$(LINUX_DTB_LOAD)u \
	    -DBOOT_DYNAMIC -DBOOT_NEXT_ADDR=0x$(LINUX_LOAD)u -DBOOT_NEXT_MODE=1u \
	    $(BIOS_LDFLAGS) -Wl,-Map=$(FW_DIR)/bios_linux.map \
	    $(BIOS_SRC) $(BIOS_LIBS) -o $@
	@$(CROSS)size $@

# -----------------------------------------------------------------------------
# Building the Linux side
#
# The configs live in this repository, not in the Buildroot tree, so that what
# the machine boots is version controlled with the machine.
# -----------------------------------------------------------------------------
LINUX_CFG     := firmware/linux/linux.config
BR_DEFCONFIG  := firmware/linux/buildroot_defconfig
# Prefer the locally built BusyBox rootfs when one exists, and fall back to
# whatever Buildroot last produced. `make linux-rootfs` builds the former; the
# latter is what `make linux-buildroot` leaves behind.
#
# One line, and $(strip) on top of that. A backslash-newline inside the then or
# else part of $(if ...) becomes a leading space in the result: $(if) strips
# whitespace from the *condition* only. Written across three lines this expanded
# to " build/linux/rootfs.cpio.gz", and that leading space survived into
#
#     [ -f "$(LINUX_INITRD)" ]        quoted - space is part of the name - false
#
# while
#
#     cp $(LINUX_INITRD) ...          word-split by the shell - copies fine
#
# so the card got the right rootfs.gz and a device tree that never mentioned
# it. The kernel reports that as
#
#     VFS: Unable to mount root fs on "" or unknown-block(0,0)
#
# which names neither the initrd nor the device tree, and arrives after a
# completely healthy-looking boot.
LINUX_INITRD  ?= $(strip $(if $(wildcard build/linux/rootfs-musl.cpio.gz),build/linux/rootfs-musl.cpio.gz,$(if $(wildcard build/linux/rootfs.cpio.gz),build/linux/rootfs.cpio.gz,$(BUILDROOT)/output/images/rootfs.cpio.gz)))

.PHONY: linux-config
linux-config:
	@test -d $(BUILDROOT)/output/build/linux-6.9 || { \
	    echo 'No kernel source at $(BUILDROOT)/output/build/linux-6.9'; exit 1; }
	cp $(LINUX_CFG) $(BUILDROOT)/output/build/linux-6.9/.config
	$(MAKE) -C $(BUILDROOT)/output/build/linux-6.9 ARCH=riscv \
	    CROSS_COMPILE=$(BR_TOOLCHAIN)/$(BR_PREFIX) olddefconfig
	@echo ''
	@echo 'Config applied. `make linux-kernel` builds it.'

# The kernel with the rootfs built into it, which is how linux-on-litex ships
# and one fewer thing to get wrong: no rootfs.gz on the card, no load address,
# and no linux,initrd-start/-end in /chosen. Those properties have already cost
# one bring-up session - a stale dtb described the old archive's length and the
# kernel panicked in mount_root_generic naming neither.
#
# INITRAMFS_SOURCE takes the *uncompressed* cpio: gen_initramfs.sh compresses it
# itself and will not accept a .gz it did not make. The archive still has to be
# built by gen_init_cpio rather than from a directory, because a directory tree
# cannot carry /dev/console as a real device node without root.
ROOTFS_CPIO ?= $(strip $(if $(wildcard build/linux/rootfs-musl.cpio),build/linux/rootfs-musl.cpio,build/linux/rootfs.cpio))

KSRC := $(BUILDROOT)/output/build/linux-6.9

.PHONY: linux-kernel-embedded
linux-kernel-embedded:
	@test -f $(ROOTFS_CPIO) || { echo 'No cpio at $(ROOTFS_CPIO)'; \
	    echo 'Run `make linux-rootfs-musl` first.'; exit 1; }
	@test -d $(KSRC) || { echo 'No kernel source at $(KSRC)'; exit 1; }
	cp $(LINUX_CFG) $(KSRC)/.config
	@# A kconfig *symbol*, so it has to be written into .config. Passing
	@# INITRAMFS_SOURCE= on the make command line does nothing at all and
	@# quietly yields a kernel with an empty built-in initramfs.
	$(KSRC)/scripts/config --file $(KSRC)/.config \
	    --set-str INITRAMFS_SOURCE "$(CURDIR)/$(ROOTFS_CPIO)" \
	    --enable INITRAMFS_COMPRESSION_GZIP \
	    --enable BLK_DEV_INITRD \
	    --enable RD_GZIP
	$(MAKE) -C $(KSRC) ARCH=riscv \
	    CROSS_COMPILE=$(BR_TOOLCHAIN)/$(BR_PREFIX) olddefconfig >/dev/null
	@grep -q "^CONFIG_INITRAMFS_SOURCE=\"$(CURDIR)/$(ROOTFS_CPIO)\"" $(KSRC)/.config || { \
	    echo 'INITRAMFS_SOURCE did not survive olddefconfig:'; \
	    grep '^CONFIG_INITRAMFS_SOURCE' $(KSRC)/.config; exit 1; }
	$(MAKE) -C $(KSRC) ARCH=riscv \
	    CROSS_COMPILE=$(BR_TOOLCHAIN)/$(BR_PREFIX) -j$(shell nproc) Image
	@mkdir -p build/linux
	@cp $(KSRC)/arch/riscv/boot/Image build/linux/Image-embedded
	@echo ''
	@ls -l build/linux/Image-embedded
	@echo 'Use it with:  make sdcard LINUX_IMAGE=$(CURDIR)/build/linux/Image-embedded EMBEDDED_ROOTFS=1'

.PHONY: linux-kernel
linux-kernel: linux-config
	$(MAKE) -C $(BUILDROOT)/output/build/linux-6.9 ARCH=riscv \
	    CROSS_COMPILE=$(BR_TOOLCHAIN)/$(BR_PREFIX) -j$(shell nproc) Image
	@cp $(BUILDROOT)/output/build/linux-6.9/arch/riscv/boot/Image \
	    $(BUILDROOT)/output/images/Image
	@ls -l $(BUILDROOT)/output/images/Image
	@$(CROSS)size $(BUILDROOT)/output/build/linux-6.9/vmlinux

# The full Buildroot run: toolchain, kernel and a gzipped cpio rootfs. Long,
# and only needed when the C library or the package set changes - which, for the
# musl switch this defconfig asks for, means the whole toolchain.
#
# The defconfig in this repository refers to its own files through @TOPDIR@
# rather than BR2_EXTERNAL_*_PATH. The external-tree variables only exist once a
# tree is registered with BR2_EXTERNAL= and carries an external.desc, and this
# repository is not one; passing the variable on the command line looks like it
# works because kconfig stores the string unexpanded, and then the *second*
# make - the one that actually builds - expands it to nothing and reads the
# kernel config from /firmware/linux/linux.config. A generated defconfig with
# absolute paths has no such failure mode.
BR_DEFCONFIG_GEN := build/linux/buildroot_defconfig

#
# Everything below builds into $(BR_OUTPUT), not Buildroot's default output/.
#
# Changing the C library invalidates the entire toolchain, and the documented
# way to do that in-tree is `make clean`, which deletes the working glibc
# toolchain, the kernel build tree, and gen_init_cpio along with it. Buildroot
# supports out-of-tree builds via O=, so the musl tree is built alongside the
# glibc one instead and the known-good tree stays bootable. Disk is cheaper
# than a toolchain rebuild, and cheaper still than having no fallback if musl
# turns out not to fit either.
BR_OUTPUT     ?= $(BUILDROOT)/output-musl
BR_MUSL_TC    := $(BR_OUTPUT)/host/bin
BR_MUSL_PREFIX := riscv32-buildroot-linux-musl-

$(BR_DEFCONFIG_GEN): $(BR_DEFCONFIG) Makefile
	@mkdir -p build/linux
	@sed 's|@TOPDIR@|$(CURDIR)|g' $(BR_DEFCONFIG) > $@
	@grep -q '@TOPDIR@' $@ && { echo 'unsubstituted @TOPDIR@ in $@'; exit 1; } || true

.PHONY: linux-buildroot
linux-buildroot: $(BR_DEFCONFIG_GEN)
	$(MAKE) -C $(BUILDROOT) O=$(BR_OUTPUT) defconfig \
	    BR2_DEFCONFIG=$(CURDIR)/$(BR_DEFCONFIG_GEN)
	$(MAKE) -C $(BUILDROOT) O=$(BR_OUTPUT)

# Just the toolchain: binutils, gcc and musl. This is all we actually need from
# Buildroot, because the rootfs is assembled by `make linux-rootfs` from our own
# inittab and skeleton, and the kernel already builds from linux.config in the
# glibc tree. Skipping the target filesystem saves most of the wall clock.
.PHONY: linux-musl-toolchain
linux-musl-toolchain: $(BR_DEFCONFIG_GEN)
	$(MAKE) -C $(BUILDROOT) O=$(BR_OUTPUT) defconfig \
	    BR2_DEFCONFIG=$(CURDIR)/$(BR_DEFCONFIG_GEN)
	$(MAKE) -C $(BUILDROOT) O=$(BR_OUTPUT) toolchain
	@echo ''
	@$(BR_MUSL_TC)/$(BR_MUSL_PREFIX)gcc -Q --help=target 2>/dev/null \
	    | grep -E '^\s+-(march|mabi)=' | head -2
	@echo ''
	@echo 'Now: make linux-rootfs-musl'

# The same BusyBox build as `linux-rootfs`, against the musl toolchain and in a
# separate build directory so both libcs can coexist and be compared.
.PHONY: linux-rootfs-musl
linux-rootfs-musl:
	@test -x $(BR_MUSL_TC)/$(BR_MUSL_PREFIX)gcc || { \
	    echo 'No musl toolchain at $(BR_MUSL_TC)'; \
	    echo 'Run `make linux-musl-toolchain` first.'; exit 1; }
	$(MAKE) linux-rootfs \
	    BR_TOOLCHAIN=$(BR_MUSL_TC) \
	    BR_PREFIX=$(BR_MUSL_PREFIX) \
	    BB_BUILD=build/linux/busybox-$(BB_VERSION)-musl \
	    ROOTFS_GZ=build/linux/rootfs-musl.cpio.gz

# -----------------------------------------------------------------------------
# A BusyBox userspace, built directly rather than through Buildroot
#
# Buildroot will not produce a static rootfs on the toolchain that is currently
# built, and the arithmetic is not close:
#
#     BR2_STATIC_LIBS  depends on !BR2_TOOLCHAIN_USES_GLIBC     (Config.in:680)
#
# so with glibc the only rootfs Buildroot offers is a dynamic one, and a dynamic
# one has to carry the loader and the C library:
#
#     busybox                          940 KiB
#     libc.so.6                       1635 KiB
#     ld-linux-riscv32-ilp32.so.1      190 KiB
#     -----------------------------------------
#                                     2765 KiB   of 3440 KiB free after boot
#
# An initramfs is unpacked into a ramfs that is never reclaimed, so that figure
# is permanent RAM, not disk. Linking one static binary instead drops the loader
# and pulls in only the parts of libc that BusyBox actually calls.
#
# BusyBox's own CONFIG_STATIC=y is a BusyBox option and knows nothing about
# Buildroot's kconfig dependency, so building the package directly sidesteps the
# restriction entirely. The toolchain is reused as-is: its defaults are already
# rv32ima_zicsr_zifencei / ilp32, which is exactly this core.
#
# The musl route in buildroot_defconfig is still the better answer and roughly
# halves this again. It needs a musl tarball in $(BUILDROOT)/dl and a full
# toolchain rebuild, so it is `make linux-buildroot`, not this target.
# -----------------------------------------------------------------------------
BB_VERSION  := 1.37.0
BB_TARBALL  := $(BUILDROOT)/dl/busybox/busybox-$(BB_VERSION).tar.bz2
BB_BUILD    := build/linux/busybox-$(BB_VERSION)
BB_INSTALL  := $(BB_BUILD)/_install
BB_FRAGMENT := firmware/linux/busybox.fragment
SKEL        := build/linux/skeleton
GEN_CPIO    := $(BUILDROOT)/output/build/linux-6.9/usr/gen_init_cpio
ROOTFS_GZ   := build/linux/rootfs.cpio.gz

# Extracted via a staging directory and renamed, because the tarball always
# unpacks to busybox-$(BB_VERSION) while BB_BUILD may be overridden to something
# else - `linux-rootfs-musl` points it at busybox-$(BB_VERSION)-musl so the two
# libc builds can coexist and be compared rather than overwrite each other.
$(BB_BUILD)/.extracted: $(BB_TARBALL)
	@mkdir -p build/linux
	@test -f $(BB_TARBALL) || { echo 'No busybox tarball at $(BB_TARBALL)'; exit 1; }
	@rm -rf $(BB_BUILD) build/linux/.bb-extract
	@mkdir -p build/linux/.bb-extract
	tar -xf $(BB_TARBALL) -C build/linux/.bb-extract
	mv build/linux/.bb-extract/busybox-$(BB_VERSION) $(BB_BUILD)
	@rmdir build/linux/.bb-extract
	@touch $@

# defconfig, then the fragment on top. Order is the point: the fragment only
# ever turns things off, so it has to be applied second and then re-resolved,
# which is what settles the sub-options the removals orphaned.
#
# BusyBox's kconfig is old enough to predate `olddefconfig`; `silentoldconfig`
# is the equivalent that takes the default for every new symbol without asking.
# Plain `oldconfig` prompts, which in a Makefile means it reads the recipe's own
# stdin and answers a few hundred questions with whatever it finds there.
#
# The fragment is merged, not appended. Appending relies on kconfig's last-wins
# read, which works for plain symbols but is fatal for one inside a `choice`
# block - CONFIG_SH_IS_ASH is in one, and a second assignment to it is reported
# as an inconsistent choice state and stops the build.
$(BB_BUILD)/.config: $(BB_BUILD)/.extracted $(BB_FRAGMENT) $(SCRIPT_DIR)/merge_kconfig.py Makefile
	$(MAKE) -C $(BB_BUILD) defconfig >/dev/null
	$(SCRIPT_DIR)/merge_kconfig.py $(BB_BUILD)/.config $(BB_FRAGMENT)
	$(MAKE) -C $(BB_BUILD) CROSS_COMPILE=$(BR_TOOLCHAIN)/$(BR_PREFIX) \
	    silentoldconfig >/dev/null
	@grep -q '^CONFIG_STATIC=y' $(BB_BUILD)/.config || \
	    { echo 'CONFIG_STATIC did not survive the reconfigure'; exit 1; }
	@for s in ASH MOUNT INIT DMESG FREE PS UNAME; do \
	    grep -q "^CONFIG_$$s=y" $(BB_BUILD)/.config || \
	        { echo "busybox config lost CONFIG_$$s"; exit 1; }; \
	done

# -no-pie is not optional. This toolchain defaults to PIE, and a position
# independent executable cannot also be statically linked the classic way; the
# link fails on relocations against the static libc rather than at configure
# time, so the error names a symbol and not the cause.
$(BB_INSTALL)/bin/busybox: $(BB_BUILD)/.config
	$(MAKE) -C $(BB_BUILD) CROSS_COMPILE=$(BR_TOOLCHAIN)/$(BR_PREFIX) \
	    CFLAGS_EXTRA="-Os -no-pie" LDFLAGS="-no-pie -static" -j$(shell nproc)
	$(MAKE) -C $(BB_BUILD) CROSS_COMPILE=$(BR_TOOLCHAIN)/$(BR_PREFIX) install
	@$(BR_TOOLCHAIN)/$(BR_PREFIX)strip $(BB_INSTALL)/bin/busybox
	@file $(BB_INSTALL)/bin/busybox
	@ls -l $(BB_INSTALL)/bin/busybox

SKEL_SRC := $(wildcard firmware/linux/initramfs/*)

$(ROOTFS_GZ): $(BB_INSTALL)/bin/busybox $(SKEL_SRC) $(SCRIPT_DIR)/mkinitramfs.py
	@test -x $(GEN_CPIO) || { echo 'No gen_init_cpio at $(GEN_CPIO)'; \
	    echo 'Build the kernel once (make linux-kernel) to get it.'; exit 1; }
	@rm -rf $(SKEL) && mkdir -p $(SKEL)/etc/init.d
	@cp firmware/linux/initramfs/inittab $(SKEL)/etc/inittab
	@cp firmware/linux/initramfs/rcS     $(SKEL)/etc/init.d/rcS
	@cp firmware/linux/initramfs/mountall $(SKEL)/etc/init.d/mountall
	@# A syscall-only static binary that reports through /dev/kmsg, so it can
	@# say whether userspace runs even when no console or stdio works. Built
	@# by `make probe-init`; skipped silently when absent so the normal
	@# rootfs does not depend on it.
	@# ROOTFS_PROBE=0 leaves it out: it is 545 KiB of glibc, a third of the
	@# image, and with it the musl rootfs OOM-killed its own unpack.
	@if [ "$(ROOTFS_PROBE)" != 0 ] && [ -f build/linux/probe_init ]; then \
	    cp build/linux/probe_init $(SKEL)/probe-init; \
	    chmod +x $(SKEL)/probe-init; \
	    echo "  including /probe-init ($$(stat -c %s build/linux/probe_init) bytes)"; \
	fi
	@cp firmware/linux/initramfs/profile $(SKEL)/etc/profile
	@cp firmware/linux/initramfs/passwd  $(SKEL)/etc/passwd
	@cp firmware/linux/initramfs/group   $(SKEL)/etc/group
	@chmod +x $(SKEL)/etc/init.d/rcS $(SKEL)/etc/init.d/mountall
	$(SCRIPT_DIR)/mkinitramfs.py $(BB_INSTALL) $(SKEL) $(GEN_CPIO) $@

PROBE_CC ?= $(BR_TOOLCHAIN)/$(BR_PREFIX)

.PHONY: probe-init
probe-init: build/linux/probe_init

build/linux/probe_init: firmware/linux/initramfs/probe_init.c
	@mkdir -p build/linux
	$(PROBE_CC)gcc -static -Os -o $@ $<
	@$(PROBE_CC)strip $@
	@$(PROBE_CC)readelf -h $@ | grep -E 'Type|Flags'
	@ls -l $@

# A diagnostic rootfs holding nothing but the probe: no busybox, no shell.
#
# Size is the reason it exists separately. The last boot reported
#
#     present:7168kB   managed:2908kB   1065 pages reserved
#
# and 2908 KiB is the entire budget the allocator ever sees. An initramfs is
# unpacked into shmem that cannot be reclaimed, and during the unpack the
# compressed copy is still held too, so the peak is roughly
# uncompressed + compressed + inode/dentry slab. The probe plus busybox came to
# 1551 KiB uncompressed and 816 KiB compressed, which OOM-killed the unpack
# inside gunzip. The probe alone is 545 KiB - the same size as the rootfs that
# unpacked successfully - so this image answers the question without the memory
# question interfering with it.
#
# Built straight from a gen_init_cpio manifest rather than through
# mkinitramfs.py: there is no busybox install to walk, and /sbin/init does not
# exist here, which mkinitramfs.py rightly refuses to produce.
PROBE_CPIO := build/linux/rootfs-probe.cpio

$(PROBE_CPIO): build/linux/probe_init
	@test -x $(GEN_CPIO) || { echo 'No gen_init_cpio at $(GEN_CPIO)'; exit 1; }
	@mkdir -p build/linux
	@printf '%s\n' \
	  'dir /dev 0755 0 0' \
	  'nod /dev/console 0600 0 0 c 5 1' \
	  'nod /dev/kmsg 0622 0 0 c 1 11' \
	  'nod /dev/null 0666 0 0 c 1 3' \
	  'nod /dev/tty 0666 0 0 c 5 0' \
	  'nod /dev/ttyS0 0600 0 0 c 4 64' \
	  'dir /proc 0755 0 0' \
	  'file /probe-init $(CURDIR)/build/linux/probe_init 0755 0 0' \
	  'slink /init /probe-init 0777 0 0' \
	  > $@.manifest
	$(GEN_CPIO) $@.manifest > $@
	@ls -l $@

.PHONY: linux-rootfs-probe
linux-rootfs-probe: $(PROBE_CPIO)
	@echo ''
	@echo 'Build it into the kernel with:'
	@echo '  make linux-kernel-embedded ROOTFS_CPIO=$(PROBE_CPIO)'

# Assembly-only /init images: firmware/linux/initramfs/asm_<name>.S becomes
# build/linux/rootfs-asm_<name>.cpio.gz, holding /dev nodes and /init alone.
# No libc, a couple of KB in total, so the kernel unpacks it in a blink - in
# simulation that removes ~37 s of simulated time (the busybox unpack runs at
# ~26 KiB/s) and makes "does user mode run at all" a sub-hour question.
#
#   make linux-sim-asm                 asm_init.S   (user mode reached?)
#   make linux-sim-asm ASM=probe2      stack, brk, fork/COW, SIGSEGV
#   make linux-sim-asm ASM=probe3      atomics, misaligned, mmap
#   make linux-sim-asm ASM=div         divu/remu/mul in user mode
ASM ?= init
ASM_INITRD = build/linux/rootfs-asm_$(ASM).cpio.gz

build/linux/asm_%: firmware/linux/initramfs/asm_%.S
	@mkdir -p build/linux
	$(PROBE_CC)gcc -nostdlib -static -march=rv32ima -mabi=ilp32 -o $@ $<
	@ls -l $@

.PRECIOUS: build/linux/asm_% build/linux/rootfs-asm_%.cpio
build/linux/rootfs-asm_%.cpio: build/linux/asm_%
	@test -x $(GEN_CPIO) || { echo 'No gen_init_cpio at $(GEN_CPIO)'; exit 1; }
	@printf '%s\n' \
	  'dir /dev 0755 0 0' \
	  'nod /dev/console 0600 0 0 c 5 1' \
	  'nod /dev/kmsg 0622 0 0 c 1 11' \
	  'nod /dev/null 0666 0 0 c 1 3' \
	  'nod /dev/tty 0666 0 0 c 5 0' \
	  'nod /dev/ttyS0 0600 0 0 c 4 64' \
	  'file /init $(CURDIR)/$< 0755 0 0' \
	  > $@.manifest
	$(GEN_CPIO) $@.manifest > $@

build/linux/rootfs-asm_%.cpio.gz: build/linux/rootfs-asm_%.cpio
	gzip -9 -n -c $< > $@
	@ls -l $@

.PHONY: linux-sim-asm
linux-sim-asm: $(ASM_INITRD)
	$(MAKE) linux-sim LINUX_INITRD=$(ASM_INITRD)

# Boot to a busybox shell in simulation. The musl busybox, no glibc probe
# (545 KiB that the board's RAM cannot spare), and *uncompressed*: gunzip at
# this machine's ~1.5 MIPS was most of the boot. About 540 M cycles to the
# prompt - roughly 45 minutes of wall clock.
#
#   make linux-sim-shell
#   make linux-sim-shell UART_IN=cmds.txt     and type into it
SHELL_INITRD := build/linux/rootfs-bb.cpio

$(SHELL_INITRD): $(SKEL_SRC) $(SCRIPT_DIR)/mkinitramfs.py
	$(MAKE) linux-rootfs BR_TOOLCHAIN=$(BR_MUSL_TC) BR_PREFIX=$(BR_MUSL_PREFIX) \
	    BB_BUILD=build/linux/busybox-$(BB_VERSION)-musl \
	    ROOTFS_GZ=build/linux/rootfs-bb.cpio.gz ROOTFS_PROBE=0

.PHONY: linux-sim-shell
linux-sim-shell: $(SHELL_INITRD)
	$(MAKE) linux-sim LINUX_INITRD=$(SHELL_INITRD)

.PHONY: linux-rootfs
linux-rootfs: $(ROOTFS_GZ)
	@echo ''
	@echo 'Use it with:  make sdcard LINUX_INITRD=$(CURDIR)/$(ROOTFS_GZ)'

# -----------------------------------------------------------------------------
# Staging the SD card
#
# Everything the board needs to boot Linux, in one directory, ready to copy to
# the FAT32 partition. The device tree is built here rather than shipped, because
# the initrd's address and length go into /chosen and both depend on the file.
#
# This tree keeps the hardware console speed. The simulation device tree is a
# different file for exactly that reason - see $(LINUX_DTB).
# -----------------------------------------------------------------------------
SD_STAGE  := build/sdcard

# The BOOT.TXT line for a separate rootfs, empty when it is inside the Image.
# Kept out of the recipe so the line continuation is not part of the $(if).
BOOT_LOAD_LINE := $(if $(filter 1,$(EMBEDDED_ROOTFS)),,'load    rootfs.gz       0x80400000')
HW_DTB    := $(FW_DIR)/custom_riscv_hw.dtb

# UART_POLLED=1 strips the serial node's interrupt properties, which makes the
# 8250 driver fall back to a polling timer:
#
#     of_platform_serial_setup()   "IRQ support not mandatory" -> port->irq = 0
#     univ8250_setup_irq()         if (!port->irq) mod_timer(...); return 0;
#
# It exists to separate two failures that look identical from the console - a
# dead UART interrupt and a userspace that never runs - because kernel printk
# polls THRE directly via uart_console_write() and works either way, while a
# userspace write() only reaches the wire from the TX interrupt handler.
#
# It is also a legitimate way to run a 38400 console permanently: polling costs
# a timer tick and this machine has one UART.
DTB_FLAGS      := $(if $(UART_POLLED),polled,irq)
DTB_FLAGS_FILE := $(FW_DIR)/.dtb_flags
ifeq ($(DRY_RUN),)
$(shell mkdir -p $(FW_DIR))
$(shell [ "$$(cat $(DTB_FLAGS_FILE) 2>/dev/null)" = "$(DTB_FLAGS)" ] || \
        printf '%s' '$(DTB_FLAGS)' > $(DTB_FLAGS_FILE))
endif

$(HW_DTB): $(LINUX_DTS) $(DTB_FLAGS_FILE) Makefile
	@mkdir -p $(FW_DIR)
ifeq ($(UART_POLLED),1)
	@echo "  uart: polled (interrupt properties removed from the serial node)"
	@sed -e '/interrupt-parent = <&plic>;/d' -e '/interrupts = <1>;/d' \
	    $(LINUX_DTS) > $(FW_DIR)/_hw_in.dts
	@grep -q 'interrupts = <1>' $(FW_DIR)/_hw_in.dts && \
	    { echo 'serial interrupts survived the strip'; exit 1; } || true
else
	@cp $(LINUX_DTS) $(FW_DIR)/_hw_in.dts
endif
	@# Both clock-frequency properties follow the build clock. The UART one
	@# feeds the 8250 divisor in Linux AND OpenSBI's console; a stale 24 MHz on
	@# an 18 MHz board picks divisor 39 instead of 29 and every kernel message
	@# is garbage. The CPU node's is informational but must not lie either.
	@sed -i 's/clock-frequency = <24000000>/clock-frequency = <$(SOC_CLK_HZ)>/g' \
	    $(FW_DIR)/_hw_in.dts
	@if [ "$(EMBEDDED_ROOTFS)" = "1" ]; then \
	    echo "  rootfs: built into the Image, so /chosen names no initrd"; \
	    cp $(FW_DIR)/_hw_in.dts $(FW_DIR)/custom_riscv_hw.dts; \
	elif [ -f "$(LINUX_INITRD)" ]; then \
	    end=$$(printf '0x%x' $$(( 0x$(LINUX_INITRD_LOAD) + $$(stat -c %s $(LINUX_INITRD)) ))); \
	    sed "s|bootargs = |linux,initrd-start = <0x$(LINUX_INITRD_LOAD)>;\n\t\tlinux,initrd-end = <$$end>;\n\t\tbootargs = |" \
	        $(FW_DIR)/_hw_in.dts > $(FW_DIR)/custom_riscv_hw.dts; \
	else \
	    echo "  WARNING: no initrd at '$(LINUX_INITRD)'"; \
	    echo "           /chosen will NOT describe one, so a kernel booted with"; \
	    echo "           rdinit= panics in mount_root_generic looking for a disk"; \
	    cp $(FW_DIR)/_hw_in.dts $(FW_DIR)/custom_riscv_hw.dts; \
	fi
	dtc -I dts -O dtb -o $@ $(FW_DIR)/custom_riscv_hw.dts
	@# The card is only ever staged for an initramfs boot, so a device tree
	@# without one is a build error here rather than a warning. This is the
	@# check that would have caught the whitespace bug at the source.
ifneq ($(EMBEDDED_ROOTFS),1)
	@grep -q 'linux,initrd-end' $(FW_DIR)/custom_riscv_hw.dts || { \
	    echo "$(HW_DTB): no linux,initrd-end - refusing to stage an unbootable card"; \
	    rm -f $@; exit 1; }
endif

.PHONY: sdcard
sdcard: $(HW_DTB) $(OPENSBI_FW_LINUX)
	@test -f $(LINUX_IMAGE)  || { echo 'No kernel at $(LINUX_IMAGE)'; exit 1; }
	@rm -rf $(SD_STAGE) && mkdir -p $(SD_STAGE)
	@cp $(LINUX_IMAGE)        $(SD_STAGE)/Image
	@cp $(OPENSBI_FW_LINUX)   $(SD_STAGE)/fw_dynamic.bin
	@cp $(HW_DTB)             $(SD_STAGE)/custom.dtb
ifneq ($(EMBEDDED_ROOTFS),1)
	@test -f $(LINUX_INITRD) || { echo 'No initramfs at $(LINUX_INITRD)'; exit 1; }
	@cp $(LINUX_INITRD)       $(SD_STAGE)/rootfs.gz
endif
	@printf '%s\n' \
	  '# BOOT.TXT - read by the BIOS on this board.' \
	  '#' \
	  '# One entry per line: role, file, load address. Roles:' \
	  '#   sbi     jumped to in machine mode' \
	  '#   kernel  what the SBI enters next, in supervisor mode' \
	  '#   dtb     passed to it in a1' \
	  '#   load    copied in and left alone - the initramfs' \
	  '#' \
	  '# The addresses are not free choices. RV32 setup_vm needs a 4 MiB' \
	  '# aligned kernel, and a 3 MB Image only fits the first such slot in' \
	  '# 8 MiB, so the kernel takes the base of memory and OpenSBI goes to' \
	  '# the top - outside the 7 MiB the device tree declares, so Linux' \
	  '# never allocates over it.' \
	  '' \
	  'kernel  Image           0x80000000' \
	  $(BOOT_LOAD_LINE) \
	  'dtb     custom.dtb      0x806F0000' \
	  'sbi     fw_dynamic.bin  0x80700000' \
	  > $(SD_STAGE)/BOOT.TXT
	@$(SCRIPT_DIR)/check_boot_map.py \
	    kernel:$(LINUX_LOAD):$(SD_STAGE)/Image \
	    $(if $(filter 1,$(EMBEDDED_ROOTFS)),,initrd:$(LINUX_INITRD_LOAD):$(SD_STAGE)/rootfs.gz) \
	    dtb:$(LINUX_DTB_LOAD):$(SD_STAGE)/custom.dtb \
	    opensbi:$(LINUX_SBI_LOAD):$(SD_STAGE)/fw_dynamic.bin
	@echo ''
	@echo 'Copy these to the root of the FAT32 partition on the card:'
	@ls -l $(SD_STAGE) | tail -n +2 | awk '{printf "    %-16s %10s bytes\n", $$9, $$5}'
	@echo ''
	@printf '    total %s bytes; at 6 MHz SPI the BIOS reads that in about %s seconds\n' \
	    "$$(du -cb $(SD_STAGE) | tail -1 | cut -f1)" \
	    "$$(( $$(du -cb $(SD_STAGE) | tail -1 | cut -f1) * 8 / 6000000 + 1 ))"
	@cd $(SD_STAGE) && md5sum $$(ls BOOT.TXT custom.dtb fw_dynamic.bin Image rootfs.gz 2>/dev/null) > MANIFEST.md5
	@echo ''
	@echo 'Then: make sdcard-verify SD=<mountpoint>   (after copying)'
	@echo '      make fpga SDBOOT=1 && make prog && make monitor'

# -----------------------------------------------------------------------------
# Is the card actually holding what we built?
#
# Three separate bring-up sessions have now been lost to a file that was correct
# in build/ and stale where it was read from:
#
#   BOOT_DTB   the BIOS kept passing the old dtb address in a1
#   SDBOOT     a bare `make board` rebuilt the BIOS in the other mode
#   custom.dtb the initrd grew and /chosen still described the old length,
#              so the kernel unpacked 27% of a gzip and panicked in
#              mount_root_generic with no mention of the initrd at all
#
# The third is the nastiest, because the file that is stale is not the file that
# appears to be broken, and the kernel's complaint names neither. One md5sum
# comparison rules all of it out in a second.
# -----------------------------------------------------------------------------
.PHONY: sdcard-verify
sdcard-verify:
	@test -n "$(SD)" || { echo 'Usage: make sdcard-verify SD=<card mountpoint>'; exit 1; }
	@test -d "$(SD)" || { echo 'No such directory: $(SD)'; exit 1; }
	@test -f $(SD_STAGE)/MANIFEST.md5 || { echo 'Run `make sdcard` first.'; exit 1; }
	@cd "$(SD)" && md5sum -c $(CURDIR)/$(SD_STAGE)/MANIFEST.md5 2>&1 \
	  | sed 's/: OK/: ok/' \
	  || { echo ''; \
	       echo 'The card does not match build/sdcard. Copy the failing files again;'; \
	       echo 'a stale custom.dtb in particular will panic the kernel in'; \
	       echo 'mount_root_generic without ever mentioning the initrd.'; \
	       exit 1; }
	@echo ''
	@echo 'Card matches build/sdcard.'

# tb_soc counts cycles in a 32-bit integer and refuses more than 2147483647.
# The old default (40 G) was over that, so plain `make linux-sim` stopped at
# once. 2.1 G cycles is ~87 s of machine time at 24 MHz.
LINUX_TIMEOUT ?= 2100000000
# PCSAMPLE=<cycles> profiles the run (see +pcsample in tb_soc.v and
# scripts/pcprofile.py). 100000 is ~4 ms of machine time per sample.
# LINUX_STOPAT=<hex pc> ends the run when that PC retires and prints the last
# 512 retired instructions - e.g. the address of `panic` from System.map.
PCSAMPLE ?=
# Stop with the full halt dump (stall reasons, TLBs, page walk, last 512
# retired instructions) if nothing retires for this many cycles. An idle
# kernel at HZ=100 retires every ~240 k cycles, so this cannot fire on idling.
LINUX_STALL ?= 5000000
# UART_IN=<file> types the file into the console, one line per shell prompt.
UART_IN ?=
# Appended to the simulation kernel command line, e.g.
#   LINUX_BOOTARGS_EXTRA=initcall_debug   per-initcall timing in the log
LINUX_BOOTARGS_EXTRA ?=
LINUX_STOPAT ?=

.PHONY: linux-sim
linux-sim: $(SOC_BIN) $(FW_DIR)/bios_linux.wordhex $(OPENSBI_FW_LINUX) $(LINUX_DTB) \
           $(SD_IMG_HEX)
	@test -f $(LINUX_IMAGE) || { \
	    echo 'No kernel at $(LINUX_IMAGE).'; \
	    echo 'Set LINUX_IMAGE=<path> or BUILDROOT=<dir>.'; exit 1; }
	@$(SCRIPT_DIR)/bin_to_wordhex.py $(LINUX_IMAGE) $(FW_DIR)/linux.wordhex
	@$(SCRIPT_DIR)/bin_to_wordhex.py $(OPENSBI_FW_LINUX) $(FW_DIR)/opensbi_linux.wordhex
	@$(SCRIPT_DIR)/bin_to_wordhex.py $(LINUX_DTB) $(FW_DIR)/linux_dtb.wordhex
	@if [ -f "$(LINUX_INITRD)" ]; then \
	    $(SCRIPT_DIR)/bin_to_wordhex.py $(LINUX_INITRD) $(FW_DIR)/initrd.wordhex; \
	fi
	@echo ''
	@$(SCRIPT_DIR)/check_boot_map.py \
	    kernel:$(LINUX_LOAD):$(LINUX_IMAGE) \
	    opensbi:$(LINUX_SBI_LOAD):$(OPENSBI_FW_LINUX) \
	    dtb:$(LINUX_DTB_LOAD):$(LINUX_DTB)
	@echo ''
	@$(SOC_BIN) +hex=$(FW_DIR)/bios_linux.wordhex +baud=1500000 \
	    +sdram0=$(FW_DIR)/linux.wordhex        +sdram0_at=$(LINUX_LOAD) \
	    +sdram1=$(FW_DIR)/opensbi_linux.wordhex +sdram1_at=$(LINUX_SBI_LOAD) \
	    +sdram2=$(FW_DIR)/linux_dtb.wordhex    +sdram2_at=$(LINUX_DTB_LOAD) \
	    $(if $(wildcard $(LINUX_INITRD)),+sdram3=$(FW_DIR)/initrd.wordhex +sdram3_at=$(LINUX_INITRD_LOAD),) \
	    +timeout=$(LINUX_TIMEOUT) +progress=20000000 $(TRACE_ARG) \
	    $(if $(PCSAMPLE),+pcsample=$(PCSAMPLE) +pcfile=$(FW_DIR)/pcsample.txt,) \
	    $(if $(LINUX_STOPAT),+stopat=$(LINUX_STOPAT),) \
	    +stall=$(LINUX_STALL) +hist \
	    $(if $(UART_IN),+uart_in=$(UART_IN),) \
	    2>&1 | tee $(FW_DIR)/linux.log
	@if [ -n "$(PCSAMPLE)" ]; then \
	    echo ''; echo 'PC profile (whole run):'; \
	    $(SCRIPT_DIR)/pcprofile.py $(FW_DIR)/pcsample.txt $(KSRC)/System.map \
	        $(OPENSBI_SRC)/build-linux/platform/generic/firmware/fw_dynamic.elf; \
	fi

# OpenSBI needs about 4 M instructions to reach its banner and hand off, and it
# runs from SDRAM with no instruction cache, so CPI is around 8 - call it 36 M
# cycles, or several minutes of wall clock. 80 M leaves headroom.
#
# This default was 12 M while the honest outcome was a fast refusal in
# sbi_hart_hang at 3.9 M. It was not raised when S-mode made the boot actually
# work, so `make opensbi-sim` with no override stopped in the middle of libfdt
# and looked like a hang. Do not tune this down again without checking what the
# successful path costs.
OPENSBI_TIMEOUT ?= 80000000

# Privilege mode to hand OpenSBI. 3 = M, 1 = S, 0 = U.
#
# S now that S-mode is implemented, which is what OpenSBI expects and what a
# kernel needs. M is still refused by OpenSBI by design (sbi_domain.c), and 0
# hands off to U-mode instead, which is legal and occasionally useful.
BOOT_NEXT_MODE ?= 1

# The clock the board runs at. RTL/bus/wb_defines.vh is the source of truth for
# the design; this is only for reporting, and the two have to agree.


.PHONY: opensbi-sim
# OpenSBI stops by jumping to sbi_hart_hang, which is a wfi loop. Stopping the
# simulation there instead of waiting for a timeout turns a twelve-million-cycle
# wait into a four-million-cycle one and, more usefully, distinguishes "OpenSBI
# decided to give up" from "the simulation ran out of time". The address is read
# out of the ELF rather than hardcoded, because it moves with every rebuild.
SBI_HANG = $(shell $(CROSS)nm $(OPENSBI_SRC)/build/platform/generic/firmware/fw_dynamic.elf \
                   2>/dev/null | awk '$$3=="sbi_hart_hang"{print $$1}')

# And the address the payload spins at when it has finished. An S-mode payload
# cannot halt the machine - that is an M-mode act - so it parks instead and the
# simulation stops on the address.
PAYLOAD_DONE = $(shell $(CROSS)nm $(FW_DIR)/bios_boot.elf 2>/dev/null \
                   | awk '$$3=="sbi_payload_done"{print $$1}')

opensbi-sim: $(SOC_BIN) $(FW_DIR)/bios_boot.wordhex $(OPENSBI_FW) $(DTB_SIM)
	@$(SCRIPT_DIR)/bin_to_wordhex.py $(OPENSBI_FW) $(FW_DIR)/opensbi.wordhex
	@$(SCRIPT_DIR)/bin_to_wordhex.py $(DTB_SIM) $(FW_DIR)/dtb.wordhex
	@echo ''
	@echo 'Booting OpenSBI. Expected outcome with BOOT_NEXT_MODE=$(BOOT_NEXT_MODE):'
ifeq ($(BOOT_NEXT_MODE),3)
	@echo '  OpenSBI refuses M-mode as a next stage and stops in sbi_hart_hang.'
	@echo '  That is by design in sbi_domain.c, not a fault in this build.'
else
	@echo '  cold boot, banner, then a handoff to mode $(BOOT_NEXT_MODE).'
	@echo ''
	@echo 'This takes roughly 4 M instructions and 36 M cycles - a few minutes.'
	@echo 'Expect a long silent stretch after "Handing off": that is OpenSBI'
	@echo 'relocating itself and parsing the device tree, before its console'
	@echo 'exists. A heartbeat line every 5 M cycles shows it is still moving.'
endif
	@echo ''
	@$(SOC_BIN) +hex=$(FW_DIR)/bios_boot.wordhex +baud=1500000 \
	    +sdram0=$(FW_DIR)/opensbi.wordhex +sdram0_at=$(OPENSBI_LOAD) \
	    +sdram1=$(FW_DIR)/dtb.wordhex     +sdram1_at=$(DTB_LOAD) \
	    +timeout=$(OPENSBI_TIMEOUT) +progress=5000000 \
	    $(if $(SBI_HANG),+stopat=$(SBI_HANG),) \
	    $(if $(PAYLOAD_DONE),+stopat2=$(PAYLOAD_DONE),) $(TRACE_ARG) \
	    2>&1 | tee $(FW_DIR)/opensbi.log; \
	  if grep -q 'next stage running' $(FW_DIR)/opensbi.log; then \
	    echo ''; \
	    echo '----------------------------------------------------------------'; \
	    echo ' OpenSBI cold-booted and handed off. The payload ran in mode'; \
	    echo ' $(BOOT_NEXT_MODE) and made SBI calls back into the firmware.'; \
	    echo '----------------------------------------------------------------'; \
	  elif grep -q 'reached the requested pc' $(FW_DIR)/opensbi.log; then \
	    echo ''; \
	    echo '----------------------------------------------------------------'; \
	    echo ' OpenSBI stopped in sbi_hart_hang. This is the expected result.'; \
	    echo ''; \
	    echo ' It is not a bug in the core, the bus, the atomics or this build.'; \
	    echo ' OpenSBI requires a privilege mode below M and refuses to boot'; \
	    echo ' without one, in two separate places:'; \
	    echo ''; \
	    echo '   sbi_domain.c  sanitize_domain() rejects any next_mode that is'; \
	    echo '                 not S or U          -> returns -3 (SBI_EINVAL)'; \
	    echo '   sbi_init.c    only a hart whose misa advertises the next mode'; \
	    echo '                 may become the cold-boot hart'; \
	    echo ''; \
	    echo ' This core is M-mode only, so both checks fail. See section 3l of'; \
	    echo ' PROGRESS_REPORT.md; U-mode alone is enough to clear it.'; \
	    echo '----------------------------------------------------------------'; \
	  fi

SOC_TIMEOUT ?= 8000000

# -----------------------------------------------------------------------------
# SD card image for simulation.
#
# The filesystem is laid out by mkfs.vfat and sfdisk rather than by our own
# code, so the parser is tested against someone else's reading of the FAT
# specification. See scripts/mksdimage.py.
#
# SD_SECRET names a file to store as CLAUDE.TXT; without it a placeholder is
# used. The hex files are read by RTL/sim/sd_model.v at run time, not compiled
# in, so changing the image needs no rebuild.
# -----------------------------------------------------------------------------
SD_IMG_DIR := build/sd
SD_IMG_HEX := $(SD_IMG_DIR)/sd_lba.hex $(SD_IMG_DIR)/sd_dat.hex

sdimage: $(SD_IMG_HEX)

$(SD_IMG_HEX): scripts/mksdimage.py
	@mkdir -p $(SD_IMG_DIR)
	@echo "sd image"
	@python3 scripts/mksdimage.py $(SD_SECRET)

soc: $(SOC_BIN) $(FW_DIR)/bios_sim.wordhex $(SD_IMG_HEX)
	$(SOC_BIN) +hex=$(FW_DIR)/bios_sim.wordhex +baud=1500000 \
	    +timeout=$(SOC_TIMEOUT) $(TRACE_ARG)

wave-soc: $(SOC_BIN) $(FW_DIR)/bios_sim.wordhex $(SD_IMG_HEX)
	@mkdir -p $(WAVE_DIR)
	$(SOC_BIN) +hex=$(FW_DIR)/bios_sim.wordhex +baud=1500000 \
	    +timeout=$(SOC_TIMEOUT) +vcd=$(WAVE_DIR)/soc.vcd
	$(GTKWAVE) $(WAVE_DIR)/soc.vcd > /dev/null 2>&1 &

# Tests that only mean something with real bus latency or a real CLINT.
# 10_interrupts and 11_plic have no interrupt source at all against the bare
# core - the CLINT and the PLIC are both bus slaves.
SOC_ONLY_TESTS := 08_csr 09_traps 10_interrupts 11_plic 06_muldiv 12_atomics \
                  13_privilege 14_trap_timing 15_fence 16_mmu 17_umode_mem 18_div_irq \
                  19_mip_seip_rmw 20_ifault_phantom_load

test-soc-tests: $(SOC_BIN) $(SD_IMG_HEX) $(addprefix $(TESTBIN)/soc_,$(addsuffix .wordhex,$(SOC_ONLY_TESTS)))
	@pass=0; fail=0; \
	for t in $(SOC_ONLY_TESTS); do \
	    out=$$($(SOC_BIN) +hex=$(TESTBIN)/soc_$$t.wordhex \
	           +timeout=$(SOC_TIMEOUT) +quiet 2>&1); \
	    if echo "$$out" | grep -q 'SoC TEST PASSED'; then \
	        printf '  \033[32mPASS\033[0m  soc/%-16s %s\n' "$$t" \
	          "$$(echo "$$out" | grep -E 'instructions|CSR accesses' | tr -s ' ' | tr '\n' ' ')"; \
	        pass=$$((pass+1)); \
	    else \
	        printf '  \033[31mFAIL\033[0m  soc/%-16s\n' "$$t"; \
	        echo "$$out" | tail -25 | sed 's/^/          /'; fail=$$((fail+1)); \
	    fi; \
	done; \
	[ "$$fail" -eq 0 ]

test-soc: $(SOC_BIN) $(FW_DIR)/bios_sim.wordhex $(SD_IMG_HEX)
	@out=$$($(SOC_BIN) +hex=$(FW_DIR)/bios_sim.wordhex +baud=1500000 \
	         +timeout=$(SOC_TIMEOUT) +quiet 2>&1); \
	if echo "$$out" | grep -q 'SoC TEST PASSED'; then \
	    printf '  \033[32mPASS\033[0m  %-20s %s\n' 'soc_bios' \
	      "$$(echo "$$out" | grep -E 'cycles|instructions|uart chars' | tr -s ' ' | tr '\n' ' ')"; \
	else \
	    printf '  \033[31mFAIL\033[0m  %-20s\n' 'soc_bios'; \
	    echo "$$out" | tail -30 | sed 's/^/          /'; false; \
	fi

# -----------------------------------------------------------------------------
# FPGA: Tang Nano 20K
#
# gw_sh writes into ./impl relative to its working directory and offers no way
# to redirect that, so the build runs from the repository root and the results
# are moved under build/ afterwards. That keeps the source tree clean.
# -----------------------------------------------------------------------------
# The Gowin script lists every source explicitly, which is exactly what makes it
# possible to add a core file and forget it here - synthesis then reports the
# module as unknown, several minutes in. Compare the two lists up front instead.
.PHONY: fpga-check-sources
fpga-check-sources:
	@missing=''; for f in $(CORE_SRC) $(BUS_SRC) $(SOC_SRC) $(PERIPH_SRC); do \
	    case "$$f" in \
	        */instruction_rom.v|*/data_ram.v) continue ;; \
	        */uart16550/*) continue ;; \
	    esac; \
	    grep -q "$$f" $(FPGA_DIR)/build.tcl || missing="$$missing $$f"; \
	done; \
	if [ -n "$$missing" ]; then \
	    echo "build.tcl is missing:$$missing"; exit 1; \
	fi; \
	echo 'fpga-check-sources: build.tcl covers every synthesisable source'

fpga: fpga-check-sources $(BITSTREAM)

$(BITSTREAM): $(CORE_SRC) $(BUS_SRC) $(SOC_SRC) $(PERIPH_SRC) $(RTL_HDRS) $(CLK_CONFIG_FILE) \
              $(FPGA_DIR)/top_tang_nano_20k.v $(FPGA_DIR)/gowin_rpll.v \
              $(FPGA_DIR)/tang_nano_20k.cst $(FPGA_DIR)/tang_nano_20k.sdc \
              $(FPGA_DIR)/build.tcl $(FPGA_BUILD)/bios.wordhex
	@test -x $(GW_SH) || { echo 'gw_sh not found at $(GW_SH); set GOWIN_HOME'; exit 1; }
	rm -rf impl $(FPGA_BUILD)/impl
	$(GOWIN_ENV) $(GW_SH) $(FPGA_DIR)/build.tcl
	@mkdir -p $(FPGA_BUILD)
	mv impl $(FPGA_BUILD)/impl
	@$(MAKE) --no-print-directory fpga-check-nets
	@echo ''
	@echo 'bitstream: $(BITSTREAM)'
	@$(MAKE) --no-print-directory fpga-report

# An undriven net is never intentional, and Verilog will not tell you about it:
# a name used before it is declared quietly becomes an implicit wire. Verilator
# merges that with the real declaration and simulates correctly; Gowin makes two
# nets and leaves one with no driver. The design then works in simulation and
# hangs on the board.
#
# That is not hypothetical - it cost a long bring-up session. FENCE.I waited on
# `cache_flush_busy`, which was used one line above its declaration, so on
# hardware the core waited for a signal that could not arrive. The synthesiser
# said so, in the log, and the build carried on and passed.
#
# So the build now fails on it, the same way it fails on a missing pin.
fpga-check-nets:
	@log=$(FPGA_BUILD)/impl/gwsynthesis/custom_riscv.log; \
	if [ -f "$$log" ] && grep -qE 'does not have a driver|already implicitly declared' "$$log"; then \
	    echo ''; \
	    echo 'FPGA BUILD REJECTED: undriven or implicitly declared net'; \
	    grep -E 'does not have a driver|already implicitly declared|assumed default net type' "$$log" | sed 's/^/  /'; \
	    echo ''; \
	    echo '  A name used before it is declared becomes an implicit wire.'; \
	    echo '  Declare it with the other wires, above its first use.'; \
	    exit 1; \
	fi

fpga-report: 
	@python3 -c "import re,sys; \
t=open('$(FPGA_BUILD)/impl/pnr/custom_riscv.rpt.txt',errors='ignore').read(); \
i=t.find('Resource Usage Summary'); print(t[i:i+1250] if i>=0 else 'no resource report')" \
	  2>/dev/null || true
	@python3 -c "import re,html; \
t=open('$(FPGA_BUILD)/impl/pnr/custom_riscv_tr_content.html',errors='ignore').read(); \
t=re.sub(r'<[^>]+>','\n',t); t=html.unescape(t); \
L=[l.strip() for l in t.split('\n') if l.strip()]; \
[print(' '.join(L[i:i+8])) for i,l in enumerate(L) if 'Max Frequency Summary' in l][:1]; \
[print(l,'=>',L[i+1]) for i,l in enumerate(L) if 'Violated Endpoints' in l]" \
	  2>/dev/null || true
	@echo ''
	@echo 'Timing against the clock the board actually runs at:'
	@$(SCRIPT_DIR)/timing_margin.py $(SOC_CLK_HZ) \
	    $(FPGA_BUILD)/impl/pnr/custom_riscv.timing_paths 2>/dev/null || true

prog: $(BITSTREAM)
	$(LOADER) -b $(BOARD) $(BITSTREAM)

# Writes the on-board flash, so the design survives a power cycle.
flash: $(BITSTREAM)
	$(LOADER) -b $(BOARD) -f $(BITSTREAM)

# Attach after programming, not before: openFPGALoader re-opens the FT2232 at
# the chip level and resets the serial channel's line settings, so a monitor
# opened first only sees noise. The BIOS waits ~1.5 s before its first output so
# that attaching right afterwards still catches the whole log.
monitor:
	@echo 'listening on $(PORT) at $(BAUD) for $(MON_SECS)s (Ctrl-C to stop)'
	@$(SCRIPT_DIR)/uart_monitor.py $(PORT) $(BAUD) $(MON_SECS)

board: prog
	@sleep 1
	@$(MAKE) --no-print-directory monitor

# -----------------------------------------------------------------------------
# The two headline simulation targets
# -----------------------------------------------------------------------------
sim_no_graphics_rv32I: $(SIM_BIN)
	@set -e; \
	if [ -n '$(PROG)' ]; then \
	    $(SCRIPT_DIR)/prog_to_hex.sh '$(PROG)' $(BUILD_DIR)/run.hex; \
	    IMAGE=$(BUILD_DIR)/run.hex; \
	else \
	    echo 'no program given, using $(DEFAULT_PROG)'; \
	    $(MAKE) --no-print-directory $(DEFAULT_PROG); \
	    IMAGE=$(DEFAULT_PROG); \
	fi; \
	$(SIM_BIN) +hex=$$IMAGE +timeout=$(TIMEOUT) $(TRACE_ARG)

sim_graphics_rv32I: $(TRACE_BIN)
	@set -e; \
	mkdir -p $(WAVE_DIR); \
	if [ -n '$(PROG)' ]; then \
	    $(SCRIPT_DIR)/prog_to_hex.sh '$(PROG)' $(BUILD_DIR)/run.hex; \
	    IMAGE=$(BUILD_DIR)/run.hex; \
	else \
	    echo 'no program given, using $(DEFAULT_PROG)'; \
	    $(MAKE) --no-print-directory $(DEFAULT_PROG); \
	    IMAGE=$(DEFAULT_PROG); \
	fi; \
	$(TRACE_BIN) +hex=$$IMAGE +timeout=$(TIMEOUT) +vcd=$(VCD) $(TRACE_ARG); \
	echo "waveform: $(VCD)"; \
	$(GTKWAVE) $(VCD) $(SIM_DIR)/rv32i.gtkw > /dev/null 2>&1 &

# -----------------------------------------------------------------------------
# Regression
# -----------------------------------------------------------------------------
test check: $(SIM_BIN) tests
	@pass=0; fail=0; \
	echo '================================================================'; \
	echo ' RV32I regression'; \
	echo '================================================================'; \
	for t in $(FUNC_TESTS); do \
	    out=$$($(SIM_BIN) +hex=$(TESTBIN)/$$t.hex +timeout=$(TIMEOUT) 2>&1); \
	    stat=$$(echo "$$out" | grep -oE 'TEST (PASSED|FAILED)' || echo 'NO RESULT'); \
	    info=$$(echo "$$out" | grep -E 'instructions|CPI|a0 ' | tr -s ' ' | tr '\n' ' '); \
	    if [ "$$stat" = 'TEST PASSED' ]; then \
	        printf '  \033[32mPASS\033[0m  %-20s %s\n' "$$t" "$$info"; pass=$$((pass+1)); \
	    else \
	        printf '  \033[31mFAIL\033[0m  %-20s %s\n' "$$t" "$$info"; fail=$$((fail+1)); \
	        echo "$$out" | sed 's/^/          /'; \
	    fi; \
	done; \
	for spec in $(TRAP_TESTS); do \
	    t=$${spec%%:*}; c=$${spec##*:}; \
	    out=$$($(SIM_BIN) +hex=$(TESTBIN)/$$t.hex +timeout=5000 +expect_trap=$$c 2>&1); \
	    stat=$$(echo "$$out" | grep -oE 'TEST (PASSED|FAILED)' || echo 'NO RESULT'); \
	    if [ "$$stat" = 'TEST PASSED' ]; then \
	        printf '  \033[32mPASS\033[0m  %-20s expected mcause=%s\n' "$$t" "$$c"; pass=$$((pass+1)); \
	    else \
	        printf '  \033[31mFAIL\033[0m  %-20s expected mcause=%s\n' "$$t" "$$c"; fail=$$((fail+1)); \
	        echo "$$out" | sed 's/^/          /'; \
	    fi; \
	done; \
	echo '----------------------------------------------------------------'; \
	printf ' %d passed, %d failed\n' "$$pass" "$$fail"; \
	echo '================================================================'; \
	[ "$$fail" -eq 0 ]
	@echo ''
	@echo '--- unit testbenches, for properties that live in one clock cycle ---'
	@$(MAKE) --no-print-directory test-plic
	@$(MAKE) --no-print-directory test-dcache
	@echo ''
	@echo '--- over the Wishbone bus, where the stalls and the CLINT are real ---'
	@$(MAKE) --no-print-directory test-soc-tests
	@$(MAKE) --no-print-directory test-soc

TEST ?= 05_hazard_stress

run: $(SIM_BIN) $(TESTBIN)/$(TEST).hex
	$(SIM_BIN) +hex=$(TESTBIN)/$(TEST).hex +timeout=$(TIMEOUT) $(TRACE_ARG)

# One directed test, run inside the full SoC so memory really does stall
run-soc: $(SOC_BIN) $(TESTBIN)/soc_$(TEST).wordhex
	$(SOC_BIN) +hex=$(TESTBIN)/soc_$(TEST).wordhex +timeout=$(SOC_TIMEOUT) \
	    +quiet $(TRACE_ARG)

wave: $(TRACE_BIN) $(TESTBIN)/$(TEST).hex
	@mkdir -p $(WAVE_DIR)
	$(TRACE_BIN) +hex=$(TESTBIN)/$(TEST).hex +timeout=$(TIMEOUT) \
	    +vcd=$(WAVE_DIR)/$(TEST).vcd $(TRACE_ARG)
	$(GTKWAVE) $(WAVE_DIR)/$(TEST).vcd $(SIM_DIR)/rv32i.gtkw > /dev/null 2>&1 &

dump: $(TESTBIN)/$(TEST).elf
	$(OBJDUMP) -d -M no-aliases,numeric $<

# Regenerate the randomised RV32M test from its reference model.
# CASES and SEED are overridable: "make regen-random CASES=2000 SEED=7".
CASES ?= 320
SEED  ?= 20260820

regen-random:
	$(SCRIPT_DIR)/gen_muldiv_random.py $(CASES) $(SEED) > $(TEST_DIR)/07_muldiv_random.S
	@echo 'regenerated $(TEST_DIR)/07_muldiv_random.S with $(CASES) cases, seed $(SEED)'

# -----------------------------------------------------------------------------
# Housekeeping
# -----------------------------------------------------------------------------
clean:
	rm -rf $(OBJ_DIR) $(TRACE_DIR) $(SOC_OBJ) $(PLIC_OBJ) \
	       $(TESTBIN) $(FW_DIR) \
	       $(BUILD_DIR)/run.hex
	rm -rf impl        # in case a gw_sh run was interrupted before the move

# Drops the FPGA build too, which costs several minutes to regenerate.
board-clean:
	rm -rf $(FPGA_BUILD) impl

distclean: clean board-clean
	rm -rf $(BUILD_DIR)
