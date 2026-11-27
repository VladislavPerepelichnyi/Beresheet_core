# =============================================================================
# Full-SoC simulation (Verilator): core, caches, Wishbone bus, CLINT, PLIC,
# UART, SD card and SDRAM controllers, with behavioural SDRAM and SD card
# models. Plus the unit testbenches, the SoC regression and lint.
# =============================================================================

.PHONY: sim test-soc test-units lint

# --- Sources ------------------------------------------------------------------
CORE_SRC   := $(wildcard $(CORE_DIR)/*.v)
BUS_SRC    := $(wildcard $(BUS_DIR)/*.v)
SOC_SRC    := $(wildcard $(SOC_DIR)/*.v)
PERIPH_SRC := $(wildcard $(PERIPH_DIR)/*/*.v)
RTL_HDRS   := $(wildcard $(CORE_DIR)/*.vh $(BUS_DIR)/*.vh)
SOC_TB_SRC := $(wildcard $(SIM_RTL_DIR)/soc/*.v)
WAIVERS    := $(SIM_RTL_DIR)/verilator_waivers.vlt
RTL_INC    := +incdir+$(CORE_DIR) +incdir+$(BUS_DIR) +incdir+$(PERIPH_DIR)/uart16550

# --- SoC simulator ------------------------------------------------------------
# Warnings are reported but not fatal: the vendored UART and SD card cores are
# older Verilog, and newer Verilator releases add warnings. A missing port
# connection is always an error - an unconnected input reads as zero and the
# design misbehaves without any other sign.
#
# --threads is not used: the design is small and the time goes into the
# testbench's timing scheduler, so threads make it slower.
SOC_SIM_DIR := $(SIM_BUILD)/obj_soc
SOC_SIM     := $(SOC_SIM_DIR)/Vtb_soc
SOC_SIM_SRC := $(CORE_SRC) $(BUS_SRC) $(SOC_SRC) $(PERIPH_SRC) $(SOC_TB_SRC)
SOC_VFLAGS  := --binary --timing --top-module tb_soc -Wno-fatal -Werror-PINMISSING \
               -O3 --x-assign fast --x-initial fast -CFLAGS -O2 \
               --build-jobs $(JOBS)

$(SOC_SIM): $(SOC_SIM_SRC) $(RTL_HDRS) $(WAIVERS) $(SIM_BUILD)/soc_config.vh
	@echo '  VERILATE $@'
	@$(VERILATOR) $(SOC_VFLAGS) $(RTL_INC) +incdir+$(SIM_BUILD) \
	    -Mdir $(SOC_SIM_DIR) -o $(notdir $@) $(WAIVERS) $(SOC_SIM_SRC) \
	    > $(SOC_SIM_DIR).log 2>&1 || { tail -40 $(SOC_SIM_DIR).log; exit 1; }
	@echo '  -> $@ (build log $(SOC_SIM_DIR).log)'

# --- Simulated SD card --------------------------------------------------------
SD_DIR  := $(SIM_BUILD)/sd
SD_HEX  := $(SD_DIR)/sd_lba.hex $(SD_DIR)/sd_dat.hex
SD_ARGS := +sd_lba=$(SD_DIR)/sd_lba.hex +sd_dat=$(SD_DIR)/sd_dat.hex

$(SD_DIR)/sd_dat.hex: $(SD_DIR)/sd_lba.hex
$(SD_DIR)/sd_lba.hex: $(SCRIPTS)/mksdimage.py
	@echo '  GEN   $(SD_DIR)'
	@$(PYTHON) $(SCRIPTS)/mksdimage.py $(SD_DIR) >/dev/null

# --- make sim BIN=... ---------------------------------------------------------
#   (none)     the simulation BIOS: power-on self test, ends PASS or FAIL
#   BOOT.TXT   bios_preload plus the descriptor's images in SDRAM; the device
#              tree is rewritten for SIM_BAUD
#   ELF/.bin   the program in boot RAM (or SDRAM, entered through a jump stub);
#              its console is decoded at BAUD
#
# MAX_CYCLES limits the run (default 0: no limit). UART_IN=<file> types into the
# console, one line per shell prompt. SIM_ARGS passes extra tb_soc plusargs,
# e.g. +trace or +hist. BIN_ADDR is the load address of a raw binary.
SIM_RUN   := $(SIM_BUILD)/run
SIM_LOG   := $(SIM_BUILD)/sim.log
SIM_ARGS  ?=
UART_IN   ?=
BIN_ADDR  ?=
SIM_LIMIT  = +max_cycles=$(MAX_CYCLES)

SIM_IMAGE = $$($(PYTHON) $(SCRIPTS)/run_image.py sim --out $(SIM_RUN) $(1) $(BIN))

ifeq ($(BIN),)
SIM_DEPS := $(FW_BUILD)/bios_sim.vmem
SIM_LOAD  = +hex=$(FW_BUILD)/bios_sim.vmem +baud=$(SIM_BAUD)
else ifneq ($(filter %.txt %.TXT,$(BIN)),)
SIM_DEPS := $(FW_BUILD)/bios_preload.vmem
SIM_LOAD  = +hex=$(FW_BUILD)/bios_preload.vmem +baud=$(SIM_BAUD) +progress=20000000 \
            $(call SIM_IMAGE,--baud $(SIM_BAUD))
else
SIM_DEPS :=
SIM_LOAD  = +baud=$(BAUD) $(call SIM_IMAGE,--bin-addr $(or $(BIN_ADDR),0))
endif

ifneq ($(filter sim,$(MAKECMDGOALS)),)
ifneq ($(BIN),)
ifeq ($(wildcard $(BIN)),)
$(error BIN=$(BIN): no such file)
endif
endif
endif

sim: $(SOC_SIM) $(SD_HEX) $(SIM_DEPS)
	@rm -rf $(SIM_RUN)
	@set -o pipefail; args="$(SIM_LOAD)" || exit 1; \
	$(SOC_SIM) $$args $(SD_ARGS) $(SIM_LIMIT) $(if $(UART_IN),+uart_in=$(UART_IN)) $(SIM_ARGS) \
	    2>&1 | tee $(SIM_LOG)

# --- SoC regression -----------------------------------------------------------
# The functional tests from tests/rv32i (ELFs built by mk/tests.mk), run to
# EBREAK over the real bus, caches, CLINT and PLIC; then the simulation BIOS
# self test. The trap tests need the fast simulator's --expect-trap and run in
# test-isa only.
SOC_TESTS       := $(notdir $(basename $(wildcard $(TEST_DIR)/[0-9]*.S)))
SOC_TEST_ELF    := $(BUILD_DIR)/tests
SOC_TEST_DIR    := $(SIM_BUILD)/tests
SOC_TEST_CYCLES ?= 8000000

$(SOC_TEST_DIR)/%.vmem: $(SOC_TEST_ELF)/%.elf $(SCRIPTS)/translate_bin_to_vmem.py
	@mkdir -p $(@D)
	@$(PYTHON) $(SCRIPTS)/translate_bin_to_vmem.py $< $@ --base 0 --size $(BOOT_RAM_BYTES) >/dev/null

.PRECIOUS: $(SOC_TEST_DIR)/%.vmem

# Prints one PASS/FAIL line per run, the tail of the log for a failure, and
# fails if anything failed.
define run-soc-test
out=$$($(SOC_SIM) +hex=$(2) $(3) $(SD_ARGS) +quiet +max_cycles=$(SOC_TEST_CYCLES) 2>&1); \
if echo "$$out" | grep -q 'SoC TEST PASSED'; then \
    printf '  PASS  soc/%-24s %s\n' '$(1)' \
        "$$(echo "$$out" | awk '$$1=="cycles"{c=$$3} $$1=="instructions"{i=$$3} \
            END{printf "%9s cycles %8s instructions", c, i}')"; \
else \
    printf '  FAIL  soc/%s\n' '$(1)'; echo "$$out" | tail -25 | sed 's/^/        /'; fail=1; \
fi;
endef

test-soc: $(SOC_SIM) $(SD_HEX) $(FW_BUILD)/bios_sim.vmem \
          $(addprefix $(SOC_TEST_DIR)/,$(addsuffix .vmem,$(SOC_TESTS)))
	@fail=0; \
	$(foreach t,$(SOC_TESTS),$(call run-soc-test,$(t),$(SOC_TEST_DIR)/$(t).vmem,)) \
	$(call run-soc-test,bios_selftest,$(FW_BUILD)/bios_sim.vmem,+baud=$(SIM_BAUD)) \
	exit $$fail

# --- Unit testbenches ---------------------------------------------------------
# Drive one block directly, for properties that live within a single cycle and
# cannot be provoked from software.
UNIT_TESTS     := plic dcache mmu
UNIT_DIR       := $(SIM_BUILD)/unit
UNIT_SRC_plic   := $(PERIPH_DIR)/plic/plic_wb.v
UNIT_SRC_dcache := $(CORE_DIR)/cache.v
UNIT_SRC_mmu    := $(CORE_DIR)/MMU.v

$(UNIT_DIR)/%/Vtb: $(SIM_RTL_DIR)/unit/tb_%.v $(RTL_HDRS) $(WAIVERS) $(SIM_BUILD)/soc_config.vh \
                   $(UNIT_SRC_plic) $(UNIT_SRC_dcache) $(UNIT_SRC_mmu)
	@echo '  VERILATE $@'
	@mkdir -p $(@D)
	@$(VERILATOR) --binary --timing --top-module tb_$* -Wno-fatal $(RTL_INC) +incdir+$(SIM_BUILD) \
	    -Mdir $(@D) -o Vtb $(WAIVERS) $(UNIT_SRC_$*) $< > $(@D).log 2>&1 \
	    || { tail -40 $(@D).log; exit 1; }

test-units: $(foreach t,$(UNIT_TESTS),$(UNIT_DIR)/$(t)/Vtb)
	@fail=0; for t in $(UNIT_TESTS); do \
	    out=$$($(UNIT_DIR)/$$t/Vtb 2>&1); \
	    if echo "$$out" | grep -q 'TEST PASSED'; then printf '  PASS  unit/%s\n' $$t; \
	    else printf '  FAIL  unit/%s\n' $$t; echo "$$out" | tail -25 | sed 's/^/        /'; fail=1; fi; \
	done; exit $$fail

# --- Lint ---------------------------------------------------------------------
# Verilator -Wall. The core must be warning-free and the target fails if it is
# not; the whole synthesisable SoC is then linted for information only, since
# the vendored peripherals (uart16550, sdspi) are not ours to clean up.
# Waivers are in RTL/sim/verilator_waivers.vlt.
lint: $(SIM_BUILD)/soc_config.vh
	@echo '  LINT  riscv_core (warnings are errors)'
	@$(VERILATOR) --lint-only -Wall --top-module riscv_core $(RTL_INC) +incdir+$(SIM_BUILD) \
	    $(WAIVERS) $(CORE_SRC)
	@echo '  LINT  soc_wb (warnings reported)'
	@$(VERILATOR) --lint-only -Wall -Wno-fatal --no-timing --top-module soc_wb $(RTL_INC) \
	    +incdir+$(SIM_BUILD) $(WAIVERS) $(CORE_SRC) $(BUS_SRC) $(SOC_SRC) $(PERIPH_SRC) 2>&1 \
	    | grep -E '^%(Warning|Error)' ; true
	@echo '  lint done'
