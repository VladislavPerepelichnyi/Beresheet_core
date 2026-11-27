# =============================================================================
# Linux: toolchain and kernel through Buildroot, a static BusyBox initramfs,
# the device tree, and the SD card boot set.
#
# Boot map (8 MB SDRAM). RV32 needs a 4 MiB-aligned kernel and the Image only
# fits in the first slot, so the kernel takes the base of memory and OpenSBI
# the top; the device tree declares 7 MiB so Linux never touches OpenSBI.
#
#   0x8000_0000  kernel Image
#   0x8040_0000  initramfs
#   0x806F_0000  device tree
#   0x8070_0000  OpenSBI fw_dynamic
# =============================================================================

.PHONY: linux-toolchain linux-kernel linux-rootfs dtb sdcard sdcard-verify

KERNEL_ADDR := 0x80000000
INITRD_ADDR := 0x80400000
DTB_ADDR    := 0x806F0000

# --- Toolchains ---------------------------------------------------------------
# BR_OUTPUT holds the musl toolchain built from firmware/linux/buildroot_defconfig
# (make linux-toolchain); BusyBox is linked statically against it.
#
# The kernel is built in a Buildroot kernel tree. By default that is the one
# under $(BUILDROOT)/output with its glibc toolchain, if present, otherwise the
# one Buildroot extracts into BR_OUTPUT.
ROOTFS_CROSS ?= $(BR_OUTPUT)/host/bin/riscv32-buildroot-linux-musl-
ifneq ($(wildcard $(BUILDROOT)/output/build/linux-6.9/Makefile),)
KERNEL_SRC   ?= $(BUILDROOT)/output/build/linux-6.9
KERNEL_CROSS ?= $(BUILDROOT)/output/host/bin/riscv32-buildroot-linux-gnu-
else
KERNEL_SRC   ?= $(BR_OUTPUT)/build/linux-6.9
KERNEL_CROSS ?= $(ROOTFS_CROSS)
endif

# Sub-builds of third-party trees get a clean make environment, so our
# command-line variables (BIN, SRC, OUT...) cannot leak into them.
SUBMAKE := env -u MAKEFLAGS -u MFLAGS -u MAKELEVEL make

# Buildroot reads paths from the defconfig; @TOPDIR@ becomes this repository.
BR_DEFCONFIG := $(LINUX_BUILD)/buildroot_defconfig

$(BR_DEFCONFIG): $(LINUX_CFG_DIR)/buildroot_defconfig
	@mkdir -p $(@D)
	@sed 's|@TOPDIR@|$(CURDIR)|g' $< > $@

linux-toolchain: $(BR_DEFCONFIG)
	@test -f $(BUILDROOT)/Makefile || { echo 'No Buildroot at $(BUILDROOT); set BUILDROOT.'; exit 1; }
	$(SUBMAKE) -C $(BUILDROOT) O=$(BR_OUTPUT) defconfig BR2_DEFCONFIG=$(abspath $(BR_DEFCONFIG))
	$(SUBMAKE) -C $(BUILDROOT) O=$(BR_OUTPUT) toolchain linux-extract

# --- Kernel -------------------------------------------------------------------
LINUX_IMAGE ?= $(firstword $(wildcard $(LINUX_BUILD)/Image) $(BUILDROOT)/output/images/Image)

linux-kernel:
	@test -f $(KERNEL_SRC)/Makefile || { echo 'No kernel source at $(KERNEL_SRC).'; \
	    echo 'Run make linux-toolchain, or set KERNEL_SRC.'; exit 1; }
	@mkdir -p $(LINUX_BUILD)
	cp $(LINUX_CFG_DIR)/linux.config $(KERNEL_SRC)/.config
	$(SUBMAKE) -C $(KERNEL_SRC) ARCH=riscv CROSS_COMPILE=$(KERNEL_CROSS) olddefconfig
	$(SUBMAKE) -C $(KERNEL_SRC) ARCH=riscv CROSS_COMPILE=$(KERNEL_CROSS) -j$(THREADS) Image
	cp $(KERNEL_SRC)/arch/riscv/boot/Image $(LINUX_BUILD)/Image
	@echo '  -> $(LINUX_BUILD)/Image'

# --- Root filesystem ----------------------------------------------------------
# BusyBox built directly (not as a Buildroot package) so it can be linked
# statically, then packed with the kernel's gen_init_cpio so /dev/console is a
# real device node without needing root.
BB_VERSION  := 1.37.0
BB_TARBALL  ?= $(BUILDROOT)/dl/busybox/busybox-$(BB_VERSION).tar.bz2
BB_BUILD    := $(LINUX_BUILD)/busybox-$(BB_VERSION)
BB_BIN      := $(BB_BUILD)/_install/bin/busybox
GEN_CPIO    := $(KERNEL_SRC)/usr/gen_init_cpio
SKEL        := $(LINUX_BUILD)/skeleton
SKEL_SRC    := $(wildcard $(LINUX_CFG_DIR)/initramfs/*)
ROOTFS      := $(LINUX_BUILD)/rootfs.cpio.gz
LINUX_INITRD ?= $(ROOTFS)

$(BB_BUILD)/.extracted: $(BB_TARBALL)
	@rm -rf $(BB_BUILD) && mkdir -p $(LINUX_BUILD)
	tar -xf $< -C $(LINUX_BUILD)
	@touch $@

# defconfig, then busybox.fragment merged on top (the fragment only disables
# things, and kconfig choice symbols cannot simply be appended).
$(BB_BUILD)/.config: $(BB_BUILD)/.extracted $(LINUX_CFG_DIR)/busybox.fragment $(SCRIPTS)/merge_kconfig.py
	$(SUBMAKE) -C $(BB_BUILD) defconfig >/dev/null
	$(PYTHON) $(SCRIPTS)/merge_kconfig.py $@ $(LINUX_CFG_DIR)/busybox.fragment
	$(SUBMAKE) -C $(BB_BUILD) CROSS_COMPILE=$(ROOTFS_CROSS) silentoldconfig >/dev/null
	@grep -q '^CONFIG_STATIC=y' $@ || { echo 'busybox: CONFIG_STATIC was lost'; exit 1; }

# -no-pie: the toolchain defaults to PIE, which cannot be linked fully static.
$(BB_BIN): $(BB_BUILD)/.config
	@test -x $(ROOTFS_CROSS)gcc || { echo 'No musl toolchain at $(ROOTFS_CROSS)gcc; run make linux-toolchain.'; exit 1; }
	$(SUBMAKE) -C $(BB_BUILD) CROSS_COMPILE=$(ROOTFS_CROSS) \
	    CFLAGS_EXTRA="-Os -no-pie" LDFLAGS="-no-pie -static" -j$(THREADS)
	$(SUBMAKE) -C $(BB_BUILD) CROSS_COMPILE=$(ROOTFS_CROSS) install >/dev/null
	$(ROOTFS_CROSS)strip $@

$(ROOTFS): $(BB_BIN) $(SKEL_SRC) $(SCRIPTS)/mkinitramfs.py
	@test -x $(GEN_CPIO) || { echo 'No gen_init_cpio at $(GEN_CPIO); build the kernel first.'; exit 1; }
	@rm -rf $(SKEL) && mkdir -p $(SKEL)/etc/init.d
	@cp $(addprefix $(LINUX_CFG_DIR)/initramfs/,inittab profile passwd group) $(SKEL)/etc/
	@cp $(addprefix $(LINUX_CFG_DIR)/initramfs/,rcS mountall) $(SKEL)/etc/init.d/
	@chmod +x $(SKEL)/etc/init.d/*
	$(PYTHON) $(SCRIPTS)/mkinitramfs.py $(BB_BUILD)/_install $(SKEL) $(GEN_CPIO) $@

linux-rootfs: $(ROOTFS)

# --- Device tree --------------------------------------------------------------
# The kernel finds the initramfs through linux,initrd-start/-end in /chosen,
# which depend on the archive's size, so they are filled in after compiling.
LINUX_DTS := $(DTS_DIR)/beresheet.dts
LINUX_DTB := $(LINUX_BUILD)/beresheet.dtb

$(LINUX_BUILD)/dtb.cfg: FORCE
	@$(call update-file,$@,'$(abspath $(LINUX_INITRD))' '$(SOC_CLK_HZ)')

$(LINUX_DTB): $(LINUX_DTS) $(LINUX_INITRD) $(LINUX_BUILD)/dtb.cfg
	@test -f '$(LINUX_INITRD)' || { echo 'No initramfs at $(LINUX_INITRD): run make linux-rootfs or set LINUX_INITRD.'; exit 1; }
	@mkdir -p $(@D)
	$(DTC) -q -I dts -O dtb -o $@ $<
	fdtput -t i $@ /cpus/cpu@0 clock-frequency $(SOC_CLK_HZ)
	fdtput -t i $@ /soc/serial@10000000 clock-frequency $(SOC_CLK_HZ)
	fdtput -t x $@ /chosen linux,initrd-start $(INITRD_ADDR)
	fdtput -t x $@ /chosen linux,initrd-end \
	    $$(printf '%x' $$(( $(INITRD_ADDR) + $$(stat -L -c %s $(LINUX_INITRD)) )))

dtb: $(LINUX_DTB)

# --- SD card ------------------------------------------------------------------
# Stages everything the BIOS loads into build/sdcard: copy the files to the
# root of the card's FAT32 partition, then check with make sdcard-verify.
SDCARD := $(BUILD_DIR)/sdcard

sdcard: $(LINUX_DTB) $(OPENSBI_BIN)
	@test -f '$(LINUX_IMAGE)' || { echo 'No kernel at $(LINUX_IMAGE): run make linux-kernel or set LINUX_IMAGE.'; exit 1; }
	@rm -rf $(SDCARD) && mkdir -p $(SDCARD)
	@cp $(LINUX_IMAGE)  $(SDCARD)/Image
	@cp $(LINUX_INITRD) $(SDCARD)/rootfs.gz
	@cp $(LINUX_DTB)    $(SDCARD)/beresheet.dtb
	@cp $(OPENSBI_BIN)  $(SDCARD)/fw_dynamic.bin
	@printf '%s\n' \
	    '# Boot descriptor, read by the BIOS: <role> <file> <load address>.' \
	    '#   kernel  entered by OpenSBI in supervisor mode' \
	    '#   load    copied and left alone (the initramfs)' \
	    '#   dtb     passed to OpenSBI and the kernel in a1' \
	    '#   sbi     entered in machine mode' \
	    '' \
	    'kernel  Image           $(KERNEL_ADDR)' \
	    'load    rootfs.gz       $(INITRD_ADDR)' \
	    'dtb     beresheet.dtb   $(DTB_ADDR)' \
	    'sbi     fw_dynamic.bin  $(OPENSBI_ADDR)' > $(SDCARD)/BOOT.TXT
	@$(PYTHON) $(SCRIPTS)/check_boot_map.py \
	    kernel:$(KERNEL_ADDR):$(SDCARD)/Image initrd:$(INITRD_ADDR):$(SDCARD)/rootfs.gz \
	    dtb:$(DTB_ADDR):$(SDCARD)/beresheet.dtb opensbi:$(OPENSBI_ADDR):$(SDCARD)/fw_dynamic.bin
	@cd $(SDCARD) && md5sum BOOT.TXT Image rootfs.gz beresheet.dtb fw_dynamic.bin > MANIFEST.md5
	@echo '  -> $(SDCARD): copy these files to the FAT32 partition, then'
	@echo '     make sdcard-verify SD=<mount point>'

# Compares the card with the staged files by checksum: a stale file with the
# right name is the usual cause of a boot that fails far from the real fault.
sdcard-verify:
	@test -n '$(SD)' -a -d '$(SD)' || { echo 'Usage: make sdcard-verify SD=<card mount point>'; exit 1; }
	@test -f $(SDCARD)/MANIFEST.md5 || { echo 'Run make sdcard first.'; exit 1; }
	@cd '$(SD)' && md5sum -c $(abspath $(SDCARD))/MANIFEST.md5
