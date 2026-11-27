# =============================================================================
# Sipeed Tang Nano 20K: Gowin GW2AR-18 with 8 MB of in-package SDRAM.
# =============================================================================

BOARD_NAME      := Sipeed Tang Nano 20K
BOARD_SUPPORTED := yes
BOARD_DEFINE    := TANGNANO20K

# System clock. The PLL settings in gowin_rpll.v are fixed for this value and
# the top level refuses to elaborate with any other.
SOC_CLK_HZ      := 24000000

BOARD_RTL_DIR   := RTL/fpga/tangnano20k
BOARD_TCL       := $(BOARD_RTL_DIR)/build.tcl
BOARD_SDC       := $(BOARD_RTL_DIR)/tang_nano_20k.sdc
BOARD_SRC       := $(wildcard $(BOARD_RTL_DIR)/*.v) $(BOARD_RTL_DIR)/tang_nano_20k.cst \
                   $(BOARD_SDC) $(BOARD_TCL)

# gw_sh output: impl/pnr/<base>.fs, with <base> set by build.tcl.
GOWIN_PART      := GW2AR-LV18QN88C8/I7
GOWIN_OUTPUT    := beresheet

# Boot RAM image name the top level loads through the include path.
BOARD_BOOT_IMAGE := bios.wordhex

# openFPGALoader -b
LOADER_BOARD    := tangnano20k
