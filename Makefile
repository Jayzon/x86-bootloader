# =============================================================================
# Makefile - Two-Stage FAT12 Bootloader
#
# Targets:
#   make          - build the bootable floppy image
#   make run      - build and launch in QEMU
#   make clean    - remove all build artifacts
#
# Requirements:
#   nasm          (assembler)
#   mtools        (mformat, mcopy - FAT floppy image manipulation)
#   qemu-system-i386 (for 'make run')
#
# Install on Debian/Ubuntu:
#   sudo apt install nasm mtools qemu-system-x86
# Install on Arch:
#   sudo pacman -S nasm mtools qemu-system-x86
# Install on macOS (Homebrew):
#   brew install nasm mtools qemu
# =============================================================================

NASM        := nasm
MFORMAT     := mformat
MCOPY       := mcopy
QEMU        := qemu-system-i386

BUILD_DIR   := build
STAGE1_SRC  := stage1/boot1.asm
STAGE2_SRC  := stage2/stage2.asm
STAGE1_BIN  := $(BUILD_DIR)/boot1.bin
STAGE2_BIN  := $(BUILD_DIR)/KRNLDR.SYS
IMG         := $(BUILD_DIR)/floppy.img

# Floppy geometry: 1.44 MB, 80 tracks, 2 heads, 18 sectors/track, 512 B/sector
FLOPPY_SECTORS := 2880

.PHONY: all run clean

all: $(IMG)

# -------------------------------------------------------------------------
# Assemble Stage 1: must assemble to exactly 512 bytes (NASM enforces this
# because we have 'times 510-($-$$) db 0' plus the 0xAA55 signature).
# -------------------------------------------------------------------------
$(STAGE1_BIN): $(STAGE1_SRC) | $(BUILD_DIR)
	$(NASM) -f bin $< -o $@
	@size=$$(wc -c < $@); \
	if [ "$$size" -ne 512 ]; then \
		echo "ERROR: boot1.bin is $$size bytes, expected 512"; exit 1; \
	fi
	@echo "Stage 1 assembled: $@ ($$(wc -c < $@) bytes)"

# -------------------------------------------------------------------------
# Assemble Stage 2: no size restriction; the FAT loader handles any length.
# -------------------------------------------------------------------------
$(STAGE2_BIN): $(STAGE2_SRC) | $(BUILD_DIR)
	$(NASM) -f bin $< -o $@
	@echo "Stage 2 assembled: $@ ($$(wc -c < $@) bytes)"

# -------------------------------------------------------------------------
# Build the floppy disk image:
#
#   1. Create a blank 1.44 MB raw image (2880 * 512-byte sectors).
#   2. Format it as FAT12 using mformat (no root device needed).
#   3. Write Stage 1 (MBR) into the first 512 bytes with dd.
#      IMPORTANT: we skip the BPB region (bytes 3-61) so we don't clobber
#      the FAT12 metadata mformat wrote. We write the first 3 bytes (the
#      JMP instruction) and then bytes 62-510 (the bootloader code proper),
#      leaving the BPB that mformat wrote intact.
#   4. Copy KRNLDR.SYS onto the FAT filesystem using mcopy.
# -------------------------------------------------------------------------
$(IMG): $(STAGE1_BIN) $(STAGE2_BIN)
	@echo "Building floppy image..."

	# Step 1: blank raw image
	dd if=/dev/zero of=$(IMG) bs=512 count=$(FLOPPY_SECTORS) status=none

	# Step 2: FAT12 format (mformat writes its own BPB; we will overwrite
	# most of it with our Stage 1 BPB in the next step)
	$(MFORMAT) -i $(IMG) -f 1440 ::

	# Step 3: Write our Stage 1 MBR.
	# We write ALL 512 bytes of boot1.bin into the boot sector.
	# Our BPB values match what mformat uses for a standard 1.44 MB floppy,
	# so overwriting the whole sector is safe here.
	dd if=$(STAGE1_BIN) of=$(IMG) conv=notrunc bs=512 count=1 status=none

	# Step 4: Install KRNLDR.SYS into the FAT filesystem
	$(MCOPY) -i $(IMG) $(STAGE2_BIN) ::KRNLDR.SYS

	@echo "Image ready: $(IMG)"
	@echo ""
	@echo "Run with:  make run"
	@echo "     or:   qemu-system-i386 -drive format=raw,file=$(IMG),if=floppy -boot a"

# -------------------------------------------------------------------------
# Launch in QEMU. The -nographic flag uses the terminal as the display
# (output goes to stdio). Remove it and add -display gtk if you prefer
# a graphical window.
# -------------------------------------------------------------------------
run: $(IMG)
	$(QEMU) \
		-drive format=raw,file=$(IMG),if=floppy \
		-boot order=a \
		-display sdl 2>/dev/null || \
	$(QEMU) \
		-drive format=raw,file=$(IMG),if=floppy \
		-boot order=a \
		-nographic

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

clean:
	rm -rf $(BUILD_DIR)
