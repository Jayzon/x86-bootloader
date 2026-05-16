# Two-Stage FAT12 Bootloader

A minimal x86 real-mode bootloader written from scratch in NASM assembly. Boots from a 1.44 MB FAT12 floppy image, loads a second-stage binary from the filesystem, and drops you into a small interactive shell -- all before an operating system ever loads.

This is a learning project. Every line is commented to explain *why*, not just *what*.

```
BIOS
 └─ loads Stage 1 (MBR, 512 bytes) from sector 0
     └─ reads FAT12 directory, finds KRNLDR.SYS
         └─ walks cluster chain, loads Stage 2 to 0x0500
             └─ Stage 2 runs: clears screen, accepts keyboard input
```

---

## What you will see

```
Loading...
..............

================================================
  Stage 2 Bootloader - Real Mode Shell
================================================

Commands:
  help    - Show this message
  cls     - Clear the screen
  about   - About this project
  reboot  - Warm reboot

>
```

Type commands and press Enter. Backspace works. The shell is case-insensitive.

---

## Requirements

The only hard requirement is **NASM**. QEMU is optional but recommended for testing.

| Tool | Required | Purpose |
|---|---|---|
| `nasm` | Yes | Assembles `.asm` source to flat binary |
| `qemu-system-i386` | Recommended | Run the image without real hardware |
| `mtools` | Linux/macOS only | FAT image construction (not needed on Windows) |

---

## Build and run

### Windows

Install NASM from [nasm.us](https://nasm.us) (use the Windows installer and let it add itself to your PATH), then from PowerShell in the project folder:

```powershell
.\build.ps1          # assemble both stages, build floppy.img
.\build.ps1 -Run     # build and launch in QEMU
.\build.ps1 -Clean   # delete the build\ folder
```

The PowerShell script builds the entire FAT12 floppy image without any additional tools -- no WSL, no mtools, no Linux subsystem needed.

If you see a script execution error, run this once to allow local scripts:
```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

**QEMU for Windows:** download from [qemu.org/download/#windows](https://www.qemu.org/download/#windows). The script searches common install locations automatically.

### Linux / macOS

```bash
# Install dependencies
sudo apt install nasm mtools qemu-system-x86   # Debian/Ubuntu
sudo pacman -S nasm mtools qemu-system-x86     # Arch
brew install nasm mtools qemu                  # macOS

make        # assemble both stages, build floppy.img
make run    # build and launch in QEMU
make clean  # remove build/
```

### Run manually (any OS)

```
qemu-system-i386 -drive format=raw,file=build/floppy.img,if=floppy -boot a
```

---

## Project layout

```
.
├── build.ps1           Windows build script (PowerShell, no extra tools needed)
├── Makefile            Linux/macOS build script
├── README.md
├── stage1/
│   └── boot1.asm       Master Boot Record (exactly 512 bytes)
├── stage2/
│   └── stage2.asm      Second-stage loader / real-mode shell
└── build/              Created by build.ps1 or make
    ├── boot1.bin       Stage 1 binary (512 bytes)
    ├── KRNLDR.SYS     Stage 2 binary (any size)
    └── floppy.img      Bootable raw floppy image
```

---

## How it works

### The boot process

When a PC powers on the BIOS runs its POST, then reads the first 512 bytes of the boot device into memory at `0x0000:0x7C00` and jumps there. That is Stage 1.

Stage 1 has exactly 512 bytes to work with. Its entire job is to find and load Stage 2.

### Stage 1 — The MBR (`boot1.asm`)

**Memory layout at entry:**
```
0x0000:0x7C00  Stage 1 code  (we are here)
```

**What Stage 1 does, in order:**

1. **Set up segments.** The BIOS provides no guarantees about segment registers. We set `DS = ES = FS = GS = 0x07C0` so that `org 0` offsets resolve correctly against our load address of `0x7C00`.

2. **Establish a stack** at `0x0000:0xFFFF`, growing downward. This sits well below Stage 1 and leaves room for the FAT scratch buffer.

3. **BIOS Parameter Block (BPB).** The BPB at offset 3 describes the disk geometry to the BIOS and to our own disk routines: bytes per sector, sectors per track, number of heads, FAT count, root entry count, and so on. These values match a standard 1.44 MB floppy.

4. **Calculate the root directory location:**
   ```
   root_start = reserved_sectors + (num_FATs × sectors_per_FAT)
   root_size  = ceil(root_entries × 32 / bytes_per_sector)
   data_start = root_start + root_size
   ```

5. **Read the root directory** into `0x7C00:0x0200` using `INT 13h` (BIOS disk services). Each call reads one sector. A retry loop handles transient errors.

6. **LBA → CHS conversion.** `INT 13h` speaks CHS (cylinder/head/sector), not LBA. The conversion:
   ```
   sector = (LBA mod SectorsPerTrack) + 1
   head   = (LBA div SectorsPerTrack) mod NumHeads
   track  = (LBA div SectorsPerTrack) div NumHeads
   ```

7. **Search the root directory** for `KRNLDR  SYS` (FAT 8.3 format: 8 chars + 3 chars, space-padded, no dot). Each directory entry is 32 bytes; we compare 11 bytes per entry.

8. **Load the FAT table** (both copies share the same sector range) into the same scratch buffer.

9. **Walk the FAT12 cluster chain.** FAT12 stores 12-bit cluster numbers packed two entries per three bytes. For cluster N:
   - Byte offset into FAT = N + (N / 2)
   - Even cluster: mask the low 12 bits  (`& 0x0FFF`)
   - Odd cluster:  shift right 4 bits   (`>> 4`)
   - End-of-chain marker: `>= 0xFF0`

10. **Load each cluster** of `KRNLDR.SYS` to `0x0050:0x0000` (linear address `0x0500`), advancing the write pointer by `sectors_per_cluster × 512` bytes each iteration.

11. **Far-jump to Stage 2** using `retf` with `0x0050:0x0000` on the stack. `CS` will be `0x0050` when Stage 2 starts.

### Stage 2 — The real-mode shell (`stage2.asm`)

Stage 2 has no size limit -- the FAT loader handles files of any length.

At entry, `CS = 0x0050`. We immediately set `DS = CS` and re-establish the stack.

**What Stage 2 does:**

- **Clear the screen** using `INT 10h / AH=06h` (scroll window, zero lines = clear).
- **Print the banner and help text** using `INT 10h / AH=0Eh` (teletype output).
- **Input loop:** call `INT 16h / AH=00h` to block until a key is pressed. `AL` returns the ASCII value.
  - Printable characters are echoed to screen (`INT 10h`) and stored in a 64-byte command buffer.
  - Backspace erases the last character from the buffer and overwrites the glyph on screen (backspace + space + backspace).
  - Enter null-terminates the buffer and dispatches to a command handler.
- **Command dispatch:** a simple series of case-insensitive string comparisons against known keywords (`help`, `cls`, `about`, `reboot`).

---

## Key concepts explained

### Why `org 0` with `DS = 0x07C0`?

NASM's `org` sets the assumed base address for label arithmetic. We use `org 0` and point `DS` to `0x07C0`, so that a data reference like `[msgBoot]` evaluates to offset 0+N within the `0x07C0` segment, which resolves to linear `0x7C00 + N`. The alternative is `org 0x7C00` with `DS = 0`, which is equivalent but requires the segment trick to live in the linear address rather than the segment register.

### Why exactly 512 bytes for Stage 1?

The BIOS reads exactly one sector (512 bytes) and looks for the signature `0x55 0xAA` at bytes 510-511. If the signature is missing or the sector is the wrong size, the BIOS will not boot from that device. The `times 510-($-$$) db 0` directive pads the binary to exactly 510 bytes, and `dw 0xAA55` appends the two-byte signature.

### Why FAT12?

FAT12 is the simplest filesystem that gives Stage 1 a proper way to find Stage 2 by name -- without hardcoding a sector number. A real bootloader could use FAT16, FAT32, ext2, or any other filesystem; the cluster-walking logic would differ but the concept is identical.

### Why `retf` instead of `jmp`?

A far return pops `IP` then `CS` from the stack. By pushing `0x0050` then `0x0000` before the `retf`, we effectively do a far jump to `0x0050:0x0000` without needing a direct `jmp far` encoding. It is a common pattern in bootloader code.

---

## Where to go from here

This is where bootloader tutorials often stop. Here is what a real OS loader would do next, in order:

1. **Detect available memory** using `INT 15h / EAX=E820h`. The BIOS returns a map of usable and reserved physical memory ranges. You need this before setting up any data structures.

2. **Enable the A20 line.** The 8086 had 20 address lines. To maintain backward compatibility, the 21st line (A20) is disabled at boot. Without enabling it, addresses above 1 MB wrap around. There are several methods; the BIOS `INT 15h / AX=2401h` call is the most portable.

3. **Build a Global Descriptor Table (GDT).** Protected mode uses segment descriptors rather than raw segment values. You need at minimum a null descriptor, a code descriptor (execute/read), and a data descriptor (read/write).

4. **Switch to 32-bit protected mode.** Set bit 0 (`PE`) of `CR0`, perform a far jump to flush the instruction pipeline, and you are in 32-bit protected mode. Real-mode BIOS calls are no longer available.

5. **Load and jump to the kernel.** From protected mode you can access all of physical memory. Read the kernel binary from disk (using your own disk driver now, since BIOS INT 13h is gone), set up paging if desired, and jump to the kernel entry point.

Good references for the next steps:
- [OSDev Wiki](https://wiki.osdev.org) -- the canonical reference for bare-metal x86 development
- *Writing a Simple Operating System from Scratch* by Nick Blundell (free PDF)
- *The Little Book About OS Development* by Erik Helin and Adam Renberg (free online)

---

## Tested with

- NASM 2.15+
- QEMU 7.x / 8.x
- mtools 4.0+
- Runs on any x86/x86-64 host; should also boot on real hardware with a USB floppy adapter

---

## License

MIT. Use freely, learn from it, build on it.
