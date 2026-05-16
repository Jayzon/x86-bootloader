# =============================================================================
# build.ps1 - Windows build script for the Two-Stage FAT12 Bootloader
#
# Requirements:
#   nasm.exe  - download the Windows installer from https://nasm.us
#               and ensure it is on your PATH, or place nasm.exe in this folder
#
# Usage (from PowerShell in the project root):
#   .\build.ps1           # build floppy.img in .\build\
#   .\build.ps1 -Clean    # delete the build folder and exit
#   .\build.ps1 -Run      # build, then launch in QEMU if found
#
# No mtools, no WSL, no Linux subsystem required.
# The FAT12 image is constructed entirely in PowerShell.
# =============================================================================

param(
    [switch]$Clean,
    [switch]$Run,
    [string]$NasmPath = ""   # optional: full path to nasm.exe if not on PATH
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
$BuildDir  = Join-Path $PSScriptRoot "build"
$Stage1Src = Join-Path $PSScriptRoot "stage1\boot1.asm"
$Stage2Src = Join-Path $PSScriptRoot "stage2\stage2.asm"
$Stage1Bin = Join-Path $BuildDir     "boot1.bin"
$Stage2Bin = Join-Path $BuildDir     "KRNLDR.SYS"
$ImgPath   = Join-Path $BuildDir     "floppy.img"

# ---------------------------------------------------------------------------
# -Clean
# ---------------------------------------------------------------------------
if ($Clean) {
    if (Test-Path $BuildDir) {
        Remove-Item $BuildDir -Recurse -Force
        Write-Host "Cleaned: $BuildDir"
    } else {
        Write-Host "Nothing to clean."
    }
    exit 0
}

# ---------------------------------------------------------------------------
# Locate NASM
# ---------------------------------------------------------------------------
$Nasm = $null
$candidates = @(
    "nasm",                                          # on PATH
    (Join-Path $PSScriptRoot "nasm.exe"),            # next to this script
    "C:\Program Files\NASM\nasm.exe",
    "C:\Program Files (x86)\NASM\nasm.exe",
    "C:\nasm\nasm.exe",
    "$env:LOCALAPPDATA\NASM\nasm.exe",
    "$env:ProgramFiles\NASM\nasm.exe"
    "$env:LOCALAPPDATA\bin\NASM\nasm.exe"   # common user-local install
)
# -NasmPath parameter overrides auto-detection
if ($NasmPath -ne "") { $candidates = @($NasmPath) + $candidates }
foreach ($c in $candidates) {
    if (Get-Command $c -ErrorAction SilentlyContinue) { $Nasm = $c; break }
    if (Test-Path $c) { $Nasm = $c; break }
}
if (-not $Nasm) {
    Write-Error @"
NASM not found. Options:
  1. Add NASM to your PATH
  2. Place nasm.exe next to build.ps1
  3. Run:  .\build.ps1 -NasmPath "C:\path\to\nasm.exe"
  Download from https://nasm.us
"@
    exit 1
}
Write-Host "Using NASM: $Nasm"

# ---------------------------------------------------------------------------
# Create build directory
# ---------------------------------------------------------------------------
if (-not (Test-Path $BuildDir)) {
    New-Item $BuildDir -ItemType Directory | Out-Null
}

# ---------------------------------------------------------------------------
# Assemble Stage 1
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=== Assembling Stage 1 ==="
& $Nasm -f bin $Stage1Src -o $Stage1Bin
if ($LASTEXITCODE -ne 0) { Write-Error "Stage 1 assembly failed."; exit 1 }
$s1size = (Get-Item $Stage1Bin).Length
if ($s1size -ne 512) {
    Write-Error "boot1.bin is $s1size bytes; must be exactly 512."
    exit 1
}
Write-Host "boot1.bin: $s1size bytes  OK"

# ---------------------------------------------------------------------------
# Assemble Stage 2
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=== Assembling Stage 2 ==="
& $Nasm -f bin $Stage2Src -o $Stage2Bin
if ($LASTEXITCODE -ne 0) { Write-Error "Stage 2 assembly failed."; exit 1 }
$s2size = (Get-Item $Stage2Bin).Length
Write-Host "KRNLDR.SYS: $s2size bytes"

# ---------------------------------------------------------------------------
# Build the FAT12 floppy image in pure PowerShell
#
# Layout of a 1.44 MB FAT12 floppy (all values from the BPB in boot1.asm):
#
#   Sector 0          : Boot sector (Stage 1 MBR)
#   Sectors 1-9       : FAT copy 1  (9 sectors)
#   Sectors 10-18     : FAT copy 2  (9 sectors)
#   Sectors 19-25     : Root directory (224 entries x 32 bytes = 7 sectors)
#   Sectors 26-2879   : Data area (clusters 2..N)
#
# Total: 2880 sectors x 512 bytes = 1,474,560 bytes
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=== Building FAT12 floppy image ==="

# Geometry / BPB constants (must match boot1.asm exactly)
$BytesPerSector      = 512
$SectorsPerCluster   = 1
$ReservedSectors     = 1
$NumFATs             = 2
$RootEntries         = 224
$TotalSectors        = 2880
$SectorsPerFAT       = 9
$MediaByte           = 0xF0

# Derived values
$TotalBytes          = $TotalSectors * $BytesPerSector   # 1,474,560
$RootDirSectors      = [int][Math]::Ceiling($RootEntries * 32 / $BytesPerSector)  # 7
$RootDirStart        = $ReservedSectors + ($NumFATs * $SectorsPerFAT)             # 19
$DataStart           = $RootDirStart + $RootDirSectors                             # 26
$BytesPerFAT         = $SectorsPerFAT * $BytesPerSector                            # 4608

# Allocate the entire image as zeroed bytes
$img = New-Object byte[] $TotalBytes

# ---- Write Stage 1 (MBR) into sector 0 ------------------------------------
$stage1bytes = [System.IO.File]::ReadAllBytes($Stage1Bin)
[Array]::Copy($stage1bytes, 0, $img, 0, 512)

# ---- Build FAT1 and FAT2 --------------------------------------------------
# FAT12 reserves cluster 0 (media byte) and cluster 1 (end-of-chain marker).
# KRNLDR.SYS occupies one or more clusters starting at cluster 2.
# We calculate how many clusters Stage 2 needs and chain them.

$s2clusters = [int][Math]::Ceiling($s2size / ($SectorsPerCluster * $BytesPerSector))
if ($s2clusters -eq 0) { $s2clusters = 1 }

# Helper: write a 12-bit FAT entry at cluster index $n
function Set-FAT12Entry([byte[]]$fat, [int]$n, [int]$value) {
    $byteOffset = [int]($n * 3 / 2)
    if ($n % 2 -eq 0) {
        # Even cluster: value occupies low 12 bits of bytes [byteOffset] and [byteOffset+1]
        $fat[$byteOffset]     = [byte]($value -band 0xFF)
        $fat[$byteOffset + 1] = [byte](($fat[$byteOffset + 1] -band 0xF0) -bor (($value -shr 8) -band 0x0F))
    } else {
        # Odd cluster: value occupies high 12 bits of bytes [byteOffset] and [byteOffset+1]
        $fat[$byteOffset]     = [byte](($fat[$byteOffset] -band 0x0F) -bor (($value -band 0x0F) -shl 4))
        $fat[$byteOffset + 1] = [byte](($value -shr 4) -band 0xFF)
    }
}

$fat = New-Object byte[] $BytesPerFAT

# Cluster 0: media descriptor (0xF0 in low byte, 0xFF in upper nibble pair)
$fat[0] = $MediaByte
$fat[1] = 0xFF
$fat[2] = 0xFF

# Chain clusters 2 .. (2 + s2clusters - 1) for KRNLDR.SYS
for ($i = 0; $i -lt $s2clusters; $i++) {
    $clusterNum = 2 + $i
    if ($i -lt ($s2clusters - 1)) {
        Set-FAT12Entry $fat $clusterNum ($clusterNum + 1)  # points to next
    } else {
        Set-FAT12Entry $fat $clusterNum 0xFFF              # end of chain
    }
}

# Write FAT1
$fat1Offset = $ReservedSectors * $BytesPerSector
[Array]::Copy($fat, 0, $img, $fat1Offset, $BytesPerFAT)

# Write FAT2 (identical copy)
$fat2Offset = ($ReservedSectors + $SectorsPerFAT) * $BytesPerSector
[Array]::Copy($fat, 0, $img, $fat2Offset, $BytesPerFAT)

# ---- Write root directory entry for KRNLDR.SYS ----------------------------
# FAT directory entry (32 bytes):
#   Bytes  0-10: filename in 8.3 format, space-padded, uppercase, no dot
#   Byte    11:  attributes (0x20 = archive)
#   Bytes 12-21: reserved / timestamps (zeroed)
#   Bytes 22-23: last-modified time
#   Bytes 24-25: last-modified date
#   Bytes 26-27: starting cluster (low word)
#   Bytes 28-31: file size in bytes

# FAT date/time: use a fixed date (2024-01-01, 00:00:00) for reproducibility
#   Date: bits 15-9 = year-1980, bits 8-5 = month, bits 4-0 = day
#   2024-01-01 = year 44, month 1, day 1 => (44 << 9) | (1 << 5) | 1 = 0x5821
$fatDate = [uint16]0x5821
$fatTime = [uint16]0x0000

$dirEntry = New-Object byte[] 32
$nameBytes = [System.Text.Encoding]::ASCII.GetBytes("KRNLDR  SYS")
[Array]::Copy($nameBytes, 0, $dirEntry, 0, 11)
$dirEntry[11] = 0x20                                                    # archive
$dirEntry[22] = [byte]($fatTime -band 0xFF)
$dirEntry[23] = [byte](($fatTime -shr 8) -band 0xFF)
$dirEntry[24] = [byte]($fatDate -band 0xFF)
$dirEntry[25] = [byte](($fatDate -shr 8) -band 0xFF)
$dirEntry[26] = 0x02                                                    # starting cluster = 2
$dirEntry[27] = 0x00
$dirEntry[28] = [byte]($s2size -band 0xFF)                              # file size (little-endian)
$dirEntry[29] = [byte](($s2size -shr 8)  -band 0xFF)
$dirEntry[30] = [byte](($s2size -shr 16) -band 0xFF)
$dirEntry[31] = [byte](($s2size -shr 24) -band 0xFF)

$rootDirOffset = $RootDirStart * $BytesPerSector
[Array]::Copy($dirEntry, 0, $img, $rootDirOffset, 32)

# ---- Write Stage 2 data into the data area --------------------------------
$stage2bytes = [System.IO.File]::ReadAllBytes($Stage2Bin)
$dataOffset  = $DataStart * $BytesPerSector
[Array]::Copy($stage2bytes, 0, $img, $dataOffset, $s2size)

# ---- Write the image to disk ----------------------------------------------
[System.IO.File]::WriteAllBytes($ImgPath, $img)

# ---- Verify ----------------------------------------------------------------
$imgSize  = (Get-Item $ImgPath).Length
$sig510   = $img[510]
$sig511   = $img[511]
$sigOK    = ($sig510 -eq 0x55) -and ($sig511 -eq 0xAA)
$sigStr   = if ($sigOK) { "OK (55 AA)" } else { "WRONG ($($sig510.ToString('X2')) $($sig511.ToString('X2')))" }

Write-Host "Image:          $ImgPath"
Write-Host "Size:           $imgSize bytes (expected 1474560)"
Write-Host "Boot signature: $sigStr"
Write-Host "KRNLDR.SYS:     cluster 2, $s2size bytes, $s2clusters cluster(s)"
Write-Host ""
Write-Host "Build complete."
Write-Host ""
Write-Host "To run in QEMU:"
Write-Host "  qemu-system-i386 -drive format=raw,file=build\floppy.img,if=floppy -boot a"

# ---------------------------------------------------------------------------
# -Run: launch QEMU if available
# ---------------------------------------------------------------------------
if ($Run) {
    $qemu = $null
    $qemuCandidates = @(
        "qemu-system-i386",
        "C:\Program Files\qemu\qemu-system-i386.exe",
        "C:\qemu\qemu-system-i386.exe"
    )
    foreach ($c in $qemuCandidates) {
        if (Get-Command $c -ErrorAction SilentlyContinue) { $qemu = $c; break }
        if (Test-Path $c) { $qemu = $c; break }
    }
    if (-not $qemu) {
        Write-Warning "QEMU not found. Download from https://qemu.org/download/#windows"
        Write-Host "Once installed, run:"
        Write-Host "  qemu-system-i386 -drive format=raw,file=build\floppy.img,if=floppy -boot a"
    } else {
        Write-Host "Launching QEMU..."
        & $qemu -drive "format=raw,file=$ImgPath,if=floppy" -boot a
    }
}
