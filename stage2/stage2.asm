;=============================================================================
; stage2.asm - Second Stage Bootloader (KRNLDR.SYS)
;
; Loaded by Stage 1 to linear address 0x0500 (segment 0x0050, offset 0x0000).
; We are still in 16-bit real mode with access to all BIOS services.
;
; Responsibilities (in a real OS loader this would grow to include):
;   - Detect available memory (INT 15h / E820)
;   - Set up a GDT and switch to 32-bit protected mode
;   - Load and jump to the kernel
;
; For this tutorial, Stage 2 demonstrates:
;   - Picking up after Stage 1's segment handoff
;   - Clearing the screen
;   - Printing strings with BIOS teletype
;   - Reading individual keystrokes (INT 16h)
;   - Echoing typed characters to the screen
;   - Simple command dispatch (a minimal interactive prompt)
;=============================================================================

org  0x0000
bits 16

; Stage 1 far-returned to us as 0x0050:0x0000.
; CS is now 0x0050. Set DS = CS so our data labels resolve correctly.
entry:
    cli
    push cs
    pop  ds                     ; DS = CS = 0x0050
    push cs
    pop  es                     ; ES = CS (needed for string ops)
    xor  ax, ax
    mov  ss, ax
    mov  sp, 0xFFFF             ; re-establish stack (same as Stage 1)
    sti

    call ClearScreen
    mov  si, msgBanner
    call Print
    mov  si, msgHelp
    call Print

    ;=========================================================================
    ; Main input loop
    ;
    ; Reads one keypress at a time, builds a command line in cmdBuf, and
    ; dispatches when the user presses Enter.
    ;=========================================================================
MainLoop:
    mov  si, msgPrompt
    call Print

    ; Clear the command buffer before each new line
    mov  di, cmdBuf
    mov  cx, CMD_BUF_LEN
    xor  al, al
    rep  stosb
    mov  di, cmdBuf             ; DI = write pointer into cmdBuf

InputLoop:
    ; Wait for a keypress. INT 16h / AH=0 returns:
    ;   AL = ASCII character (0 for extended keys)
    ;   AH = scan code
    mov  ah, 0x00
    int  0x16

    cmp  al, 0x0D               ; Enter key (CR)?
    je   ProcessCommand

    cmp  al, 0x08               ; Backspace?
    je   DoBackspace

    ; Ignore characters if the buffer is full (leave room for null terminator)
    mov  bx, cmdBuf
    add  bx, CMD_BUF_LEN - 1
    cmp  di, bx
    jae  InputLoop              ; buffer full, keep waiting

    ; Echo the character and store it
    call PrintChar              ; AL still holds the character
    stosb                       ; *DI++ = AL
    jmp  InputLoop

DoBackspace:
    ; Only erase if we haven't backed all the way to the start
    cmp  di, cmdBuf
    jbe  InputLoop
    dec  di                     ; step back one in the buffer
    mov  byte [di], 0           ; clear the slot
    ; Move cursor back, write a space to erase the glyph, move back again
    mov  al, 0x08
    call PrintChar
    mov  al, ' '
    call PrintChar
    mov  al, 0x08
    call PrintChar
    jmp  InputLoop

    ;=========================================================================
    ; ProcessCommand - null-terminate the buffer, then dispatch
    ;=========================================================================
ProcessCommand:
    mov  byte [di], 0           ; null-terminate whatever is in cmdBuf
    mov  al, 0x0D
    call PrintChar              ; carriage return
    mov  al, 0x0A
    call PrintChar              ; line feed

    ; Ignore empty Enter presses
    cmp  di, cmdBuf
    je   MainLoop

    ; -- "help" --
    mov  si, cmdHelp
    call StrCmpCI
    je   DoHelp

    ; -- "cls" --
    mov  si, cmdCls
    call StrCmpCI
    je   DoCls

    ; -- "reboot" --
    mov  si, cmdReboot
    call StrCmpCI
    je   DoReboot

    ; -- "about" --
    mov  si, cmdAbout
    call StrCmpCI
    je   DoAbout

    ; Unknown command
    mov  si, msgUnknown
    call Print
    mov  si, cmdBuf
    call Print
    mov  si, msgUnknown2
    call Print
    jmp  MainLoop

    ;-- Command handlers ------------------------------------------------------
DoHelp:
    mov  si, msgHelp
    call Print
    jmp  MainLoop

DoCls:
    call ClearScreen
    jmp  MainLoop

DoReboot:
    mov  si, msgRebooting
    call Print
    mov  ah, 0x00
    int  0x16                   ; wait for keypress
    int  0x19                   ; warm reboot

DoAbout:
    mov  si, msgAbout
    call Print
    jmp  MainLoop

;=============================================================================
; Print - write a null-terminated string via BIOS INT 10h teletype
; Input:  DS:SI -> string
; Trashes: AX, SI
;=============================================================================
Print:
    lodsb
    or   al, al
    jz   .done
    call PrintChar
    jmp  Print
.done:
    ret

;=============================================================================
; PrintChar - write a single character via BIOS INT 10h
; Input:  AL = character
; Trashes: AH, BX
;=============================================================================
PrintChar:
    mov  ah, 0x0E
    mov  bh, 0x00               ; page 0
    mov  bl, 0x07               ; light grey on black (ignored in text mode)
    int  0x10
    ret

;=============================================================================
; ClearScreen - blank the display and move cursor to (0,0)
; Uses INT 10h / AH=06h (scroll window up, filling with spaces)
;=============================================================================
ClearScreen:
    mov  ah, 0x06               ; scroll up
    mov  al, 0x00               ; 0 lines = clear entire window
    mov  bh, 0x07               ; fill attribute: light grey on black
    xor  cx, cx                 ; top-left  (row 0, col 0)
    mov  dx, 0x184F             ; bottom-right (row 24, col 79)
    int  0x10
    ; Move cursor to top-left
    mov  ah, 0x02
    mov  bh, 0x00
    xor  dx, dx
    int  0x10
    ret

;=============================================================================
; StrCmpCI - case-insensitive comparison of cmdBuf against a known keyword
;
; Input:  DS:SI -> reference string (lowercase, null-terminated)
; Output: ZF set if equal (use JE/JNE after call)
; Trashes: AX, BX, SI
;=============================================================================
StrCmpCI:
    push di
    mov  di, cmdBuf
.loop:
    mov  al, [si]
    mov  bl, [di]
    ; Lowercase both characters: if 'A'-'Z', add 0x20
    cmp  al, 'A'
    jb   .no_lower_si
    cmp  al, 'Z'
    ja   .no_lower_si
    add  al, 0x20
.no_lower_si:
    cmp  bl, 'A'
    jb   .no_lower_di
    cmp  bl, 'Z'
    ja   .no_lower_di
    add  bl, 0x20
.no_lower_di:
    cmp  al, bl
    jne  .not_equal
    or   al, al                 ; both zero means end-of-string reached together
    jz   .equal
    inc  si
    inc  di
    jmp  .loop
.equal:
    pop  di
    xor  ax, ax                 ; ZF = 1
    ret
.not_equal:
    pop  di
    or   ax, 1                  ; ZF = 0
    ret

;=============================================================================
; Data
;=============================================================================

CMD_BUF_LEN equ 64

cmdBuf      times CMD_BUF_LEN db 0

; Command keyword table (lowercase for StrCmpCI)
cmdHelp     db "help",   0
cmdCls      db "cls",    0
cmdReboot   db "reboot", 0
cmdAbout    db "about",  0

msgBanner   db "================================================", 0x0D, 0x0A
            db "  Stage 2 Bootloader - Real Mode Shell          ", 0x0D, 0x0A
            db "================================================", 0x0D, 0x0A
            db 0x0D, 0x0A, 0

msgHelp     db "Commands:", 0x0D, 0x0A
            db "  help    - Show this message", 0x0D, 0x0A
            db "  cls     - Clear the screen", 0x0D, 0x0A
            db "  about   - About this project", 0x0D, 0x0A
            db "  reboot  - Warm reboot", 0x0D, 0x0A
            db 0x0D, 0x0A, 0

msgPrompt   db "> ", 0

msgUnknown  db "Unknown command: '", 0
msgUnknown2 db "'", 0x0D, 0x0A
            db "Type 'help' for a list of commands.", 0x0D, 0x0A, 0

msgAbout    db 0x0D, 0x0A
            db "Two-Stage FAT12 Bootloader", 0x0D, 0x0A
            db "A minimal x86 real-mode bootloader written in NASM.", 0x0D, 0x0A
            db "Stage 1: MBR (512 bytes) - FAT12 loader", 0x0D, 0x0A
            db "Stage 2: This code - real-mode shell", 0x0D, 0x0A
            db 0x0D, 0x0A
            db "Next steps would be: detect memory (INT 15h E820),", 0x0D, 0x0A
            db "set up a GDT, and switch to 32-bit protected mode.", 0x0D, 0x0A
            db 0x0D, 0x0A, 0

msgRebooting db 0x0D, 0x0A, "Press any key to reboot...", 0x0D, 0x0A, 0
