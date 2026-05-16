;=============================================================================
; boot1.asm - Stage 1 Bootloader (MBR)
;
; Loaded by the BIOS at 0x0000:0x7C00. Must fit in exactly 512 bytes.
;
; Responsibilities:
;   1. Set up segment registers and a usable stack
;   2. Print a loading message
;   3. Read the FAT12 root directory from the floppy
;   4. Find KRNLDR.SYS in the directory
;   5. Walk the FAT12 cluster chain and load the file into memory
;   6. Jump to Stage 2
;
; Memory map after Stage 1 runs:
;   0x0000:0x7C00  - Stage 1 code (us, right here)
;   0x0000:0x7E00  - Scratch buffer (root dir / FAT)
;   0x0050:0x0000  - Stage 2 load address (linear 0x0500)
;=============================================================================

bits 16
org  0                          ; BIOS loads us at 0x7C00; we set DS=0x07C0
                                ; so all data offsets are relative to that segment

start:
    jmp main                    ; 3-byte far jump, lands us past the BPB

;-----------------------------------------------------------------------------
; BIOS Parameter Block (BPB) - FAT12, 1.44 MB floppy geometry
;
; The BPB must start at byte 3 of the boot sector. The fields here are what
; the BIOS and our own disk routines use to calculate sector locations.
;-----------------------------------------------------------------------------

bpbOEM              db "MYDEMOS "   ; 8-byte OEM name (space-padded)
bpbBytesPerSector:  dw 512
bpbSectorsPerCluster: db 1
bpbReservedSectors: dw 1            ; boot sector only
bpbNumberOfFATs:    db 2
bpbRootEntries:     dw 224          ; 224 * 32 bytes = 7 sectors
bpbTotalSectors:    dw 2880         ; 80 tracks * 2 heads * 18 sectors
bpbMedia:           db 0xF0         ; 0xF0 = removable disk
bpbSectorsPerFAT:   dw 9
bpbSectorsPerTrack: dw 18
bpbHeadsPerCylinder: dw 2
bpbHiddenSectors:   dd 0
bpbTotalSectorsBig: dd 0
bsDriveNumber:      db 0            ; 0x00 = floppy A:
bsUnused:           db 0
bsExtBootSignature: db 0x29
bsSerialNumber:     dd 0xDEADBEEF
bsVolumeLabel:      db "BOOTLOADER "
bsFileSystem:       db "FAT12   "

;=============================================================================
; Print - write a null-terminated string to the screen via BIOS INT 10h
; Input:  SI = pointer to string (in current DS segment)
;=============================================================================
Print:
    lodsb                       ; AL = *SI++
    or   al, al
    jz   .done
    mov  ah, 0x0E               ; BIOS teletype output
    mov  bh, 0x00               ; page 0
    int  0x10
    jmp  Print
.done:
    ret

;=============================================================================
; ReadSectors - read one or more sectors from the floppy using INT 13h
;
; Input:
;   AX = LBA sector number (0-based)
;   CX = number of sectors to read
;   ES:BX = destination buffer
;
; Trashes: AX, CX, DX (saves and restores as needed across the retry loop)
; Uses the absoluteSector/Head/Track scratch variables in BSS below.
;=============================================================================
ReadSectors:
.main:
    mov  di, 5                  ; 5 retries before giving up
.retry:
    push ax
    push bx
    push cx
    call LBACHS                 ; fill absoluteSector/Head/Track from AX
    mov  ah, 0x02               ; INT 13h: read sectors
    mov  al, 0x01               ; one sector per call (simpler error handling)
    mov  ch, [absoluteTrack]
    mov  cl, [absoluteSector]
    mov  dh, [absoluteHead]
    mov  dl, [bsDriveNumber]
    int  0x13
    jnc  .success               ; CF clear = no error
    xor  ax, ax                 ; reset disk system
    int  0x13
    dec  di
    pop  cx
    pop  bx
    pop  ax
    jnz  .retry
    jmp  DiskError              ; five failures - bail out
.success:
    mov  si, msgDot
    call Print                  ; print a '.' progress dot per sector
    pop  cx
    pop  bx
    pop  ax
    add  bx, [bpbBytesPerSector]; advance write pointer by one sector
    inc  ax                     ; next LBA sector
    loop .main
    ret

;=============================================================================
; ClusterLBA - convert a FAT12 cluster number to an LBA sector address
; Input:  AX = cluster number (2-based)
; Output: AX = LBA sector
;=============================================================================
ClusterLBA:
    sub  ax, 2
    xor  cx, cx
    mov  cl, [bpbSectorsPerCluster]
    mul  cx
    add  ax, [datasector]       ; datasector = first sector of data area
    ret

;=============================================================================
; LBACHS - convert LBA address to CHS for INT 13h
; Input:  AX = LBA address
; Output: absoluteSector, absoluteHead, absoluteTrack filled
;
;   sector = (LBA mod SectorsPerTrack) + 1
;   head   = (LBA div SectorsPerTrack) mod Heads
;   track  = (LBA div SectorsPerTrack) div Heads
;=============================================================================
LBACHS:
    xor  dx, dx
    div  word [bpbSectorsPerTrack]
    inc  dl                     ; sectors are 1-indexed
    mov  [absoluteSector], dl
    xor  dx, dx
    div  word [bpbHeadsPerCylinder]
    mov  [absoluteHead],  dl
    mov  [absoluteTrack], al
    ret

;=============================================================================
; DiskError - unrecoverable read failure; print message and wait for keypress
;=============================================================================
DiskError:
    mov  si, msgDiskError
    call Print
    mov  ah, 0x00
    int  0x16                   ; wait for keypress
    int  0x19                   ; warm reboot

;=============================================================================
; main - bootloader entry point
;=============================================================================
main:

    ;-- Silence interrupts while setting up segments -------------------------
    cli

    ;-- Point all data segments at 0x07C0 so 'org 0' offsets work correctly --
    mov  ax, 0x07C0
    mov  ds, ax
    mov  es, ax
    mov  fs, ax
    mov  gs, ax

    ;-- Stack grows downward from 0x0000:0xFFFF (well below us) -------------
    xor  ax, ax
    mov  ss, ax
    mov  sp, 0xFFFF
    sti

    ;-- Announce ourselves ---------------------------------------------------
    mov  si, msgBoot
    call Print

    ;=========================================================================
    ; LOAD ROOT DIRECTORY
    ;
    ; Root dir starts immediately after the reserved sector(s) and both FATs.
    ; Size: bpbRootEntries * 32 bytes, rounded up to whole sectors.
    ;=========================================================================
LOAD_ROOT:
    ; cx = number of sectors occupied by root directory
    xor  cx, cx
    xor  dx, dx
    mov  ax, 0x0020             ; 32 bytes per directory entry
    mul  word [bpbRootEntries]  ; dx:ax = total bytes in root dir
    div  word [bpbBytesPerSector]
    xchg ax, cx                 ; cx = sector count of root dir

    ; ax = LBA of first root dir sector
    ;    = bpbReservedSectors + (bpbNumberOfFATs * bpbSectorsPerFAT)
    mov  al, [bpbNumberOfFATs]
    mul  word [bpbSectorsPerFAT]
    add  ax, [bpbReservedSectors]

    ; datasector = LBA of first data cluster (= root dir start + root dir size)
    mov  [datasector], ax
    add  [datasector], cx

    ; Read root directory into memory immediately above Stage 1 (0x7C00+0x200)
    mov  bx, 0x0200
    call ReadSectors            ; AX=start LBA, CX=sector count, ES:BX=dest

    ;=========================================================================
    ; FIND KRNLDR.SYS IN ROOT DIRECTORY
    ;=========================================================================
    mov  cx, [bpbRootEntries]   ; loop counter: one entry per iteration
    mov  di, 0x0200             ; first directory entry
.find_loop:
    push cx
    mov  cx, 0x000B             ; 11 characters in a FAT 8.3 filename
    mov  si, ImageName
    push di
    rep  cmpsb                  ; compare 11 bytes
    pop  di
    je   LOAD_FAT               ; found it
    pop  cx
    add  di, 0x0020             ; next 32-byte entry
    loop .find_loop
    ; Not found
    mov  si, msgNotFound
    call Print
    mov  ah, 0x00
    int  0x16
    int  0x19

    ;=========================================================================
    ; LOAD FAT TABLE
    ;
    ; We need the FAT to walk the cluster chain for KRNLDR.SYS.
    ;=========================================================================
LOAD_FAT:
    mov  si, msgCRLF
    call Print

    ; Save starting cluster of KRNLDR.SYS (stored at offset 0x1A in the entry)
    mov  dx, [di + 0x001A]
    mov  [cluster], dx

    ; cx = total sectors in both FATs
    xor  ax, ax
    mov  al, [bpbNumberOfFATs]
    mul  word [bpbSectorsPerFAT]
    mov  cx, ax

    ; ax = LBA of FAT 1
    mov  ax, [bpbReservedSectors]

    ; Read FAT into the same scratch buffer (we're done with root dir)
    mov  bx, 0x0200
    call ReadSectors

    ;=========================================================================
    ; LOAD STAGE 2 (KRNLDR.SYS)
    ;
    ; Walk the FAT12 cluster chain, loading each cluster to 0x0050:0x0000
    ; (linear address 0x0500). After all clusters are read, far-jump there.
    ;=========================================================================
    mov  si, msgCRLF
    call Print

    mov  ax, 0x0050
    mov  es, ax                 ; destination segment for Stage 2
    mov  bx, 0x0000
    push bx

LOAD_IMAGE:
    mov  ax, [cluster]
    pop  bx
    call ClusterLBA             ; convert cluster -> LBA
    xor  cx, cx
    mov  cl, [bpbSectorsPerCluster]
    call ReadSectors
    push bx

    ;-- Compute next cluster in FAT12 chain ----------------------------------
    ; FAT12: each entry is 1.5 bytes. For cluster N:
    ;   byte_offset = N + (N / 2)
    ;   if N is even:  next = word[byte_offset] & 0x0FFF
    ;   if N is odd:   next = word[byte_offset] >> 4
    mov  ax, [cluster]
    mov  cx, ax
    mov  dx, ax
    shr  dx, 1                  ; dx = N/2
    add  cx, dx                 ; cx = N + N/2 = byte offset into FAT
    mov  bx, 0x0200
    add  bx, cx                 ; bx -> FAT entry
    mov  dx, [bx]               ; read 2 bytes (may straddle a byte boundary)
    test ax, 0x0001
    jnz  .odd_cluster
.even_cluster:
    and  dx, 0x0FFF             ; keep low 12 bits
    jmp  .cluster_done
.odd_cluster:
    shr  dx, 4                  ; keep high 12 bits
.cluster_done:
    mov  [cluster], dx
    cmp  dx, 0x0FF0             ; >= 0xFF0 means end-of-chain
    jb   LOAD_IMAGE

    ;-- Hand off to Stage 2 --------------------------------------------------
    mov  si, msgCRLF
    call Print
    push word 0x0050            ; far return: segment 0x0050
    push word 0x0000            ;             offset 0x0000
    retf                        ; jump to Stage 2

;=============================================================================
; Scratch variables and strings
;=============================================================================
absoluteSector  db 0
absoluteHead    db 0
absoluteTrack   db 0
datasector      dw 0
cluster         dw 0

; KRNLDR.SYS in FAT 8.3 format (11 bytes, space-padded, no dot)
ImageName       db "KRNLDR  SYS"

msgBoot         db 0x0D, 0x0A, "Loading...", 0x0D, 0x0A, 0x00
msgCRLF         db 0x0D, 0x0A, 0x00
msgDot          db ".", 0x00
msgDiskError    db 0x0D, 0x0A, "Disk error!", 0x0D, 0x0A, 0x00
msgNotFound     db 0x0D, 0x0A, "KRNLDR.SYS missing!", 0x0D, 0x0A, 0x00

; Pad to exactly 510 bytes, then write the boot signature
times 510-($-$$) db 0
dw 0xAA55
