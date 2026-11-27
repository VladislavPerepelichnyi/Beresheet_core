# =============================================================================
# make help: the target menu. Keep it in step with the fragments.
# =============================================================================

.PHONY: help

define HELP_TEXT
Beresheet - RV32IMA core and Wishbone SoC on $(BOARD_NAME)

Software
  compile-bios                       hardware BIOS (boots from the SD card) -> build/firmware/bios.{elf,bin,vmem}
  compile-bin SRC=<f.c|f.S ...>      bare-metal program with software/common crt0 -> build/bin/<name>.elf
              [OUT=<f.elf>] [LINK=boot|sdram]
                                     boot: 32 KB boot RAM at 0x0 (sim, BIOS_BR); sdram: 0x80000000 (QEMU)
                                     example: SRC=software/examples/hello/hello.c
  compile-openSBI                    OpenSBI fw_dynamic at $(OPENSBI_ADDR), pinned revision -> build/opensbi/

Linux
  linux-toolchain                    Buildroot musl toolchain and kernel source (long, once)
  linux-kernel                       kernel Image from firmware/linux/linux.config -> build/linux/Image
  linux-rootfs                       static BusyBox initramfs -> build/linux/rootfs.cpio.gz
  dtb                                device tree with the initramfs range -> build/linux/beresheet.dtb
  sdcard                             stage BOOT.TXT, Image, rootfs, dtb, OpenSBI -> build/sdcard/
  sdcard-verify SD=<mount point>     compare a card with build/sdcard by checksum

Simulation
  sim [BIN=<elf|bin|BOOT.TXT>]       full SoC: core, caches, bus, CLINT/PLIC/UART, SDRAM and SD models
                                     no BIN: BIOS self test; BOOT.TXT: OpenSBI and Linux from SDRAM
  fast_sim BIN=<elf|bin|BOOT.TXT>    core only, no caches or peripherals; fast, multithreaded
  test                               test-isa + test-units + test-soc
  test-isa                           directed ISA tests on the fast simulator
  test-units                         unit testbenches: PLIC, data cache, MMU
  test-soc                           directed tests and the BIOS self test on the SoC simulation
  lint                               Verilator -Wall over the core and the SoC

Hardware  ($(FPGA))
  synth                              synthesis and place and route -> build/fpga/impl/pnr/$(GOWIN_OUTPUT).fs
  synth-report                       resource use and timing margin at the real clock
  load                               program the FPGA SRAM (lost at power-off)
  flash                              program the on-board flash (persistent)
  console                            interactive serial console on PORT (alias: monitor)

Tools
  disassembler BIN=<elf|bin>         objdump as rv32 (NO_ALIASES=1 for canonical instructions)
  qemu BIN=<elf|BOOT.TXT>            run on QEMU virt restricted to this CPU, as a reference
  qemu-gdb BIN=<elf|BOOT.TXT>        same, halted at reset, gdb server on :1234
  gdb [BIN=<elf>]                    attach $(GDB) to :1234
  translate_bin_to_vmem BIN=<bin|elf> [OUT=] [SIZE_BYTES=]
                                     $$readmemh image, one 32-bit little-endian word per line

Housekeeping
  clean                              remove build products; keep build/fpga and the OpenSBI clone
  distclean                          remove build/

Variables (current value)
endef
export HELP_TEXT

help-var = printf '  %-35s %s\n' '$(1)=$(subst $(HOME),~,$($(1)))' '$(2)';

help:
	@printf '%s\n' "$$HELP_TEXT"
	@$(call help-var,FPGA,board: $(BOARDS))
	@$(call help-var,BIOS_BR,synth: this ELF/bin in boot RAM instead of the BIOS)
	@$(call help-var,INCL_PER,peripherals: $(PERIPHERALS_KNOWN) - none implemented yet)
	@$(call help-var,BIN,program for sim / fast_sim / qemu / disassembler)
	@$(call help-var,SRC,sources for compile-bin)
	@$(call help-var,MAX_CYCLES,simulation cycle limit; 0 = none)
	@$(call help-var,THREADS,fast_sim model threads; 1 is fastest for this core)
	@$(call help-var,JOBS,parallel build jobs)
	@$(call help-var,PORT,board serial port)
	@$(call help-var,BAUD,board console baud: BIOS and compile-bin)
	@$(call help-var,BUILDROOT,Buildroot tree for the Linux targets)
	@$(call help-var,GOWIN_HOME,Gowin IDE; gw_sh on PATH also works)
	@$(call help-var,CROSS,bare-metal toolchain prefix; auto-detected)
