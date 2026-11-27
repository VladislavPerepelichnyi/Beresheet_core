# =============================================================================
# FPGA: synthesis and place-and-route (Gowin gw_sh), programming
# (openFPGALoader) and the timing/resource report. The board comes from
# mk/boards/$(FPGA).mk.
# =============================================================================

.PHONY: synth synth-report load flash check-sources check-nets

BITSTREAM    := $(FPGA_BUILD)/impl/pnr/$(GOWIN_OUTPUT).fs
FPGA_BOOT    := $(FPGA_BUILD)/$(BOARD_BOOT_IMAGE)
SYNTH_SRC    := $(CORE_SRC) $(BUS_SRC) $(SOC_SRC) $(PERIPH_SRC) $(RTL_HDRS) $(BOARD_SRC)

# Header-only files in the vendored UART; they are `included, not listed.
SYNTH_INCLUDE_ONLY := $(PERIPH_DIR)/uart16550/timescale.v $(PERIPH_DIR)/uart16550/uart_defines.v

# The Gowin IDE ships its own Qt; gw_sh needs it on the library path and the
# offscreen platform when there is no display.
GOWIN_ROOT := $(abspath $(dir $(GW_SH))..)
GOWIN_ENV  := env -u DISPLAY -u WAYLAND_DISPLAY -u XDG_SESSION_TYPE \
              LD_LIBRARY_PATH=$(GOWIN_ROOT)/lib \
              QT_QPA_PLATFORM=offscreen \
              QT_PLUGIN_PATH=$(GOWIN_ROOT)/plugins/qt \
              QT_QPA_PLATFORM_PLUGIN_PATH=$(GOWIN_ROOT)/plugins/qt/platforms \
              FPGA_BUILD_DIR=$(FPGA_BUILD)

# --- Boot RAM contents --------------------------------------------------------
# The hardware BIOS, or with BIOS_BR=<file.elf|file.bin> any program linked for
# the boot RAM at address 0 (make compile-bin LINK=boot). The source in use is
# recorded so that switching it rebuilds the bitstream.
ifneq ($(BIOS_BR),)
ifeq ($(wildcard $(BIOS_BR)),)
$(error BIOS_BR=$(BIOS_BR): no such file)
endif
endif
BOOT_SRC := $(if $(BIOS_BR),$(BIOS_BR),$(FW_BUILD)/bios.elf)

$(FPGA_BUILD)/boot_image.src: FORCE
	@$(call update-file,$@,'$(abspath $(BOOT_SRC))')

$(FPGA_BOOT): $(BOOT_SRC) $(FPGA_BUILD)/boot_image.src $(SCRIPTS)/translate_bin_to_vmem.py
	@$(PYTHON) $(SCRIPTS)/translate_bin_to_vmem.py $(BOOT_SRC) $@ --base 0 --size $(BOOT_RAM_BYTES)

# --- Synthesis ----------------------------------------------------------------
synth: check-sources $(BITSTREAM)

# build.tcl lists its sources explicitly; catch a file that was added to the
# tree but not to the script before a several-minute run finds it.
check-sources:
	$(require-board)
	@missing=''; for f in $(filter-out $(SYNTH_INCLUDE_ONLY) $(BOARD_TCL) %.vh,$(SYNTH_SRC)); do \
	    grep -q "$$f" $(BOARD_TCL) || missing="$$missing $$f"; done; \
	[ -z "$$missing" ] || { echo "$(BOARD_TCL) does not list:$$missing"; exit 1; }

# gw_sh writes ./impl relative to its working directory, so it runs from the
# repository root and the results are moved under build/.
$(BITSTREAM): $(SYNTH_SRC) $(FPGA_BUILD)/soc_config.vh $(FPGA_BOOT)
	$(require-board)
	@test -n "$(GW_SH)" || { echo 'gw_sh not found: set GOWIN_HOME or put gw_sh on PATH.'; exit 1; }
	@rm -rf impl $(FPGA_BUILD)/impl
	@echo '  SYNTH $(BOARD_NAME) ($(GOWIN_PART)), log $(FPGA_BUILD)/gw_sh.log'
	@$(GOWIN_ENV) $(GW_SH) $(BOARD_TCL) > $(FPGA_BUILD)/gw_sh.log 2>&1; rc=$$?; \
	    [ -d impl ] && mv impl $(FPGA_BUILD)/impl; \
	    if [ $$rc -ne 0 ] || [ ! -f $@ ]; then tail -30 $(FPGA_BUILD)/gw_sh.log; exit 1; fi
	@$(MAKE) --no-print-directory check-nets
	@echo '  -> $@'
	@$(MAKE) --no-print-directory synth-report

# Verilog turns a name used before its declaration into an implicit wire.
# Verilator merges it with the later declaration; Gowin makes a second,
# undriven net, so the design works in simulation and not on the board.
check-nets:
	@log=$(FPGA_BUILD)/impl/gwsynthesis/$(GOWIN_OUTPUT).log; \
	if [ -f "$$log" ] && grep -qE 'does not have a driver|already implicitly declared' "$$log"; then \
	    echo 'Synthesis found undriven or implicitly declared nets:'; \
	    grep -E 'does not have a driver|already implicitly declared|assumed default net type' "$$log" \
	        | sed 's/^/  /'; \
	    exit 1; \
	fi

# The SDC deliberately constrains tighter than the real clock, so the margin
# is recomputed against SOC_CLK_HZ.
synth-report:
	$(require-board)
	@test -d $(FPGA_BUILD)/impl/pnr || { echo 'No FPGA build: run make synth first.'; exit 1; }
	@$(PYTHON) -c "import sys; \
t=open('$(FPGA_BUILD)/impl/pnr/$(GOWIN_OUTPUT).rpt.txt',errors='ignore').read(); \
i=t.find('Resource Usage Summary'); j=t.find('=====', i); \
print(t[i:j].rstrip() if i>=0 else 'no resource report')"
	@echo 'Timing against the real clock:'
	@$(PYTHON) $(SCRIPTS)/timing_margin.py $(SOC_CLK_HZ) \
	    $(FPGA_BUILD)/impl/pnr/$(GOWIN_OUTPUT).timing_paths $(BOARD_SDC)

# --- Programming --------------------------------------------------------------
# load writes the FPGA's configuration SRAM (lost at power-off); flash writes
# the on-board flash. With FS=<file.fs> they program that bitstream, such as a
# release download, and need no Gowin tools; otherwise they program the one
# from make synth, rebuilding it first if it is stale.
FS ?=
ifneq ($(FS),)
ifeq ($(wildcard $(FS)),)
$(error FS=$(FS): no such file)
endif
endif
PROGRAM_FS := $(if $(FS),$(FS),$(BITSTREAM))

load: $(if $(FS),,$(BITSTREAM))
	$(LOADER) -b $(LOADER_BOARD) $(PROGRAM_FS)

flash: $(if $(FS),,$(BITSTREAM))
	$(LOADER) -b $(LOADER_BOARD) -f $(PROGRAM_FS)
