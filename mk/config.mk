# =============================================================================
# Shared configuration: layout, tools, user options, the selected board and the
# generated soc_config.vh. Included first; every other fragment relies on it.
# =============================================================================

# --- Source tree --------------------------------------------------------------
CORE_DIR    := RTL/core
BUS_DIR     := RTL/bus
SOC_DIR     := RTL/soc
PERIPH_DIR  := RTL/peripherals
SIM_RTL_DIR := RTL/sim
TEST_DIR    := tests/rv32i
BIOS_DIR    := firmware/bios
DTS_DIR     := firmware/dts
LINUX_CFG_DIR := firmware/linux
SW_DIR      := software
SCRIPTS     := scripts

# --- Build tree (everything generated lives under BUILD_DIR) ------------------
FW_BUILD    := $(BUILD_DIR)/firmware
FPGA_BUILD  := $(BUILD_DIR)/fpga
SIM_BUILD   := $(BUILD_DIR)/sim
LINUX_BUILD := $(BUILD_DIR)/linux

# --- Bare-metal toolchain -----------------------------------------------------
# The first prefix found wins. All three build freestanding rv32 code:
#   riscv64-unknown-elf-  Debian/Ubuntu  gcc-riscv64-unknown-elf
#   riscv64-elf-          Arch           riscv64-elf-gcc
#   riscv64-linux-gnu-    Fedora         gcc-riscv64-linux-gnu
CROSS_CANDIDATES := riscv64-unknown-elf- riscv64-elf- riscv64-linux-gnu-
ifeq ($(CROSS),)
CROSS := $(firstword $(foreach p,$(CROSS_CANDIDATES),\
             $(if $(shell command -v $(p)gcc 2>/dev/null),$(p))))
endif

CC      := $(CROSS)gcc
OBJCOPY := $(CROSS)objcopy
OBJDUMP := $(CROSS)objdump
SIZE    := $(CROSS)size

MARCH      := rv32ima_zicsr_zifencei
MABI       := ilp32
ARCH_FLAGS := -march=$(MARCH) -mabi=$(MABI)

# libgcc named by path rather than -lgcc. Some toolchains (Arch's) carry no
# rv32ima multilib, and -lgcc then resolves to the rv64 library. The rv32im
# one is ABI-compatible and present everywhere. Evaluated once, on first use.
LIBGCC = $(eval LIBGCC := $(shell $(CC) -march=rv32im -mabi=ilp32 \
             -print-libgcc-file-name 2>/dev/null))$(LIBGCC)

# Stops a recipe that needs the cross compiler when none was found.
require-cross = @command -v $(CC) >/dev/null 2>&1 || { \
    echo 'No RISC-V cross compiler found (tried: $(CROSS_CANDIDATES)).'; \
    echo 'Install one, or set CROSS=<prefix>.'; exit 1; }

# --- Other tools --------------------------------------------------------------
PYTHON    := python3
VERILATOR := verilator
DTC       := dtc
QEMU      := qemu-system-riscv32
LOADER    := openFPGALoader

GDB_CANDIDATES := gdb-multiarch riscv64-elf-gdb riscv64-unknown-elf-gdb gdb
GDB ?= $(firstword $(foreach g,$(GDB_CANDIDATES),\
           $(if $(shell command -v $(g) 2>/dev/null),$(g))) gdb-multiarch)

# Gowin. GOWIN_HOME is the IDE directory; gw_sh on PATH is used otherwise.
GOWIN_HOME ?= $(HOME)/Electronics_tools/Gowin_EDA/IDE
GW_SH := $(firstword $(wildcard $(GOWIN_HOME)/bin/gw_sh) \
                     $(shell command -v gw_sh 2>/dev/null))

# --- User options (listed in `make help`) -------------------------------------
JOBS       ?= $(shell nproc 2>/dev/null || echo 4)
PORT       ?= /dev/ttyUSB1
BAUD       ?= 38400
SIM_BAUD   ?= 1500000
MAX_CYCLES ?= 0
BIN        ?=
SRC        ?=
OUT        ?=
BIOS_BR    ?=
INCL_PER   ?=

BUILDROOT  ?= $(HOME)/Electronics_tools/Buildroot/buildroot-2026.02
BR_OUTPUT  ?= $(BUILDROOT)/output-musl

# --- Board --------------------------------------------------------------------
FPGA   ?= tangnano20k
BOARDS := $(sort $(patsubst mk/boards/%.mk,%,$(wildcard mk/boards/*.mk)))
ifeq ($(filter $(FPGA),$(BOARDS)),)
$(error FPGA=$(FPGA) is not a known board (known: $(BOARDS)))
endif
include mk/boards/$(FPGA).mk

# Fails a recipe for a board that has a placeholder but no implementation.
require-board = @$(if $(BOARD_SUPPORTED),true,\
    { echo 'FPGA=$(FPGA): $(BOARD_NAME) is not supported yet.'; exit 1; })

# --- Optional peripherals -----------------------------------------------------
# INCL_PER=ethernet,hdmi selects peripherals to build into the SoC: comma or
# space separated, any case. Each becomes `define INCL_PER_<NAME> in
# soc_config.vh. Requesting one that is not implemented stops the build here,
# and the RTL refuses to elaborate as a second line of defence.
PERIPHERALS_KNOWN       := ethernet hdmi usb pcie
PERIPHERALS_IMPLEMENTED :=

comma := ,
lc = $(shell printf '%s' '$(1)' | tr '[:upper:]' '[:lower:]')
uc = $(shell printf '%s' '$(1)' | tr '[:lower:]' '[:upper:]')

INCL_PER_LIST := $(if $(strip $(INCL_PER)),$(sort $(call lc,$(subst $(comma), ,$(INCL_PER)))))
ifneq ($(filter-out $(PERIPHERALS_KNOWN),$(INCL_PER_LIST)),)
$(error INCL_PER: unknown peripheral(s) '$(filter-out $(PERIPHERALS_KNOWN),$(INCL_PER_LIST))'; known: $(PERIPHERALS_KNOWN))
endif
INCL_PER_MISSING := $(filter-out $(PERIPHERALS_IMPLEMENTED),$(INCL_PER_LIST))

# --- Generated files ----------------------------------------------------------
.PHONY: FORCE
FORCE:

# $(call update-file,<path>,<quoted lines>) - recipe fragment that rewrites
# <path> only when its content changes, so a target that depends on it (with
# FORCE behind it) rebuilds only when the configuration really moved.
update-file = mkdir -p $(dir $(1)) && printf '%s\n' $(2) > $(1).tmp && \
    if cmp -s $(1).tmp $(1); then rm -f $(1).tmp; \
    else mv -f $(1).tmp $(1); echo '  GEN   $(1)'; fi

# soc_config.vh: the build-time configuration of the SoC RTL. One copy per
# consumer (FPGA build, SoC simulation), each on that build's include path.
SOC_CONFIG_LINES := \
    '// Generated by make - do not edit.' \
    '`define SOC_CLK_HZ $(SOC_CLK_HZ)' \
    '`define BOARD_$(BOARD_DEFINE)' \
    $(foreach p,$(INCL_PER_LIST),'`define INCL_PER_$(call uc,$(p))')

$(FPGA_BUILD)/soc_config.vh $(SIM_BUILD)/soc_config.vh: FORCE
	$(require-board)
	@$(if $(INCL_PER_MISSING),{ echo 'INCL_PER: $(INCL_PER_MISSING) not implemented yet.'; exit 1; })
	@$(call update-file,$@,$(SOC_CONFIG_LINES))
