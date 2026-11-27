# =============================================================================
# Beresheet build system. `make` or `make help` lists the targets.
#
# Everything generated goes under $(BUILD_DIR). The rules live in mk/:
#   config.mk     layout, toolchain detection, options, soc_config.vh
#   boards/*.mk   one file per FPGA board, selected with FPGA=
#   software.mk   BIOS, custom bare-metal programs, OpenSBI
#   linux.mk      kernel, root filesystem, device tree, SD card set
#   sim.mk        full-SoC simulation, unit and SoC tests, lint
#   hardware.mk   synthesis, programming, reports
#   tools.mk      disassembler, QEMU, gdb, vmem converter, console
#   fast_sim.mk   core-only fast simulator
#   tests.mk      ISA test programs and test-isa
# =============================================================================

SHELL := /bin/bash
.DEFAULT_GOAL := help
.DELETE_ON_ERROR:

BUILD_DIR ?= build
CROSS     ?=

ifeq ($(strip $(BUILD_DIR)),)
$(error BUILD_DIR must not be empty)
endif

include mk/config.mk
include mk/software.mk
include mk/sim.mk
include mk/hardware.mk
include mk/linux.mk
include mk/tools.mk
include mk/help.mk
-include mk/fast_sim.mk mk/tests.mk

.PHONY: test clean distclean

test: test-isa test-units test-soc

# The FPGA build and the OpenSBI clone are slow to recreate, so clean keeps
# them; distclean removes everything.
clean:
	@if [ -d '$(BUILD_DIR)' ]; then \
	    find '$(BUILD_DIR)' -mindepth 1 -maxdepth 1 ! -name fpga ! -name opensbi -exec rm -rf {} +; \
	    if [ -d '$(BUILD_DIR)/opensbi' ]; then \
	        find '$(BUILD_DIR)/opensbi' -mindepth 1 -maxdepth 1 ! -name src -exec rm -rf {} +; fi; \
	fi; rm -rf impl
	@echo '  cleaned $(BUILD_DIR) (kept fpga/ and opensbi/src/)'

distclean:
	rm -rf '$(BUILD_DIR)' impl
