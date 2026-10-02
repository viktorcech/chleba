;--------------------------------------------------------------
; ATRBOOT IRQ stub: lives in the SIDE3 CCTL aperture ($D500-$D577,
; card RAM $1FF500), visible whatever PORTB and the program do.
;
; VSEROR points here. The OS's SIO sends a command frame with serial
; output interrupts (OS 2.48 and the stock XL OS alike): the first one
; for D1: lands here, inside SIOV/DSKINV. The handler's hscan finds the
; SIOV caller's return address on the stack; the stub drops the SIO frames
; above it, runs the handler (hnd.asm) in SIDE3 window A ($8000) with NMIs
; off and VBXE MEMAC A's CPU window off (a program may map VRAM over
; $8000, as Doom does), and returns to that caller with Y = status (the
; handler set DSTATS). Anything else goes on to the OS's VSEROR.
;--------------------------------------------------------------

        icl 'atrboot.inc'

mc      equ $3C                      ; the program's MEMAC_CONTROL
zwin    equ $3D                      ; windows to restore after xch

        opt h-
        org STUB_IRQ

irq     lda CDEVIC                   ; DDEVIC + DUNIT - 1 of the frame
        cmp #$31
        bne pass
        lda #0
        sta NMIEN                    ; the handler hides $8000-$9FFF
memac1  lda $D5F2                    ; MEMAC_CONTROL (ab_go: $D65E/$D75E or a dummy)
        sta mc
        lda #$01                     ; window A; the handler adds B (zwin)
        sta zwin
        jsr hon
        jsr H_SCAN                   ; X = the SIOV caller's frame
        bcs none
        txs                          ; the SIO frames above are dropped now
        jsr HND_ORG                  ; Y = status
        jsr hoff
        lda #$40
        sta NMIEN
        cli
        tya
        rts
none    jsr hoff                     ; no caller found: the OS's SIO goes on
        lda #$40
        sta NMIEN
pass    jmp $FFFF                    ; the OS's VSEROR (set by ab_go)

; xch -- cnt bytes (za),y -> (zb),y in the program's memory map
xch     jsr hoff
        ldy cnt
        dey
xc_lp   lda (za),y
        sta (zb),y
        dey
        bpl xc_lp

; hon -- handler in: MEMAC A CPU window off, SIDE3 window A on
hon     lda mc
        and #$F7
memac2  sta $D5F2
        lda zwin
        sta S3_WIN
        rts

; hoff -- program's map back: window A off, MEMAC A as it was
hoff    lda #0
        sta S3_WIN
        lda mc
memac3  sta $D5F2
        rts

stub_end
        ert stub_end>STUB_DATA
        ert pass+1<>STUB_OLD
        ert xch<>STUB_XCH
        ert memac1+1<>STUB_MC1
        ert memac2+1<>STUB_MC2
        ert memac3+1<>STUB_MC3
        end
