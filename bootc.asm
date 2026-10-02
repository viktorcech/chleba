;--------------------------------------------------------------
; ATRBOOT boot step, copied to $0480 by ab_go (SDX is gone by then, the
; OS ROM is in and VSEROR points at the stub): reopen E:, load the boot
; sectors of D1: through DSKINV (served by the stub/handler) and run them
; the way the OS boot does (BOOTAD+6, DOSINI, DOSVEC).
;--------------------------------------------------------------

        icl 'atrboot.inc'

ICCOM   equ $0342
ICBAL   equ $0344
ICBLL   equ $0348
ICAX1   equ $034A
DFLAGS  equ $0240
DBSECT  equ $0241
BOOTAD  equ $0242

        opt h-
        org BOOT_ORG

        ldx #0                       ; E: at the full RAMTOP
        lda #12
        sta ICCOM
        jsr CIOV
        ldx #0
        lda #3
        sta ICCOM
        lda #<ename
        sta ICBAL
        lda #>ename
        sta ICBAL+1
        lda #12
        sta ICAX1
        lda #0
        sta ICAX1+1
        jsr CIOV

        lda #0                       ; sector 1 -> $0400: boot header
        sta DAUX2
        sta DBUFA
        lda #1
        sta DAUX1
        lda #4
        sta DBUFA+1
        jsr rdsec
        jmi bt_err
        ldx #5                       ; DFLAGS, DBSECT, BOOTAD, DOSINI
bt_hd   lda $0400,x
        cpx #4
        bcs bt_ini
        sta DFLAGS,x
        bcc bt_hn
bt_ini  sta $0C-4,x
bt_hn   dex
        bpl bt_hd
        lda BOOTAD                   ; sectors 1..DBSECT -> BOOTAD
        sta DBUFA
        lda BOOTAD+1
        sta DBUFA+1
        lda DBSECT
        jeq bt_err
        sta bt_n
bt_lp   jsr rdsec
        jmi bt_err
        ldx H_SSZ_COPY               ; boot sectors: 128 B (512 B on QD)
        lda DBUFA
        clc
        adc bt_stl,x
        sta DBUFA
        lda DBUFA+1
        adc bt_sth,x
        sta DBUFA+1
        inc DAUX1
        dec bt_n
        bne bt_lp
        lda BOOTAD                   ; JSR BOOTAD+6; C=1: boot failed
        clc
        adc #6
        sta bt_vec
        lda BOOTAD+1
        adc #0
        sta bt_vec+1
        jsr bt_go
        bcs bt_err
        lda #1
        sta $09                      ; BOOT?: disk booted
        jsr bt_dini
        lda #0
        sta $0244                    ; COLDST
        jmp ($000A)                  ; DOSVEC

bt_go   jmp (bt_vec)
bt_dini jmp ($000C)

rdsec   lda #1
        sta DUNIT
        lda #'R'
        sta DCOMND
        jsr DSKINV
        tya
        rts

bt_err  ldx #0
        lda #9                       ; put record
        sta ICCOM
        lda #<emsg
        sta ICBAL
        lda #>emsg
        sta ICBAL+1
        lda #emsg_e-emsg
        sta ICBLL
        stx ICBLL+1
        jsr CIOV
        jmp *

ename   dta c'E:',$9B
emsg    dta c'CHLEBA: boot error',$9B
emsg_e
bt_stl  dta $80,$80,$00
bt_sth  dta $00,$00,$02
bt_n    dta 0
bt_vec  dta a(0)
        ert <bt_vec=$FF
H_SSZ_COPY dta 0                     ; set by ab_go: sector size code
        ert H_SSZ_COPY<>BOOT_SSZ

;--------------------------------------------------------------
; rvec -- called by ab_go (IRQs, NMIs off, PORTB $FF): the RAM vectors
;   $0200-$0225 and $024F-$026A back to the OS ROM's tables, as the OS reset
;   does it (INTINV does not; SDX drivers leave VIMIRQ & co. pointing at
;   their code). The tables are found through the reset code itself,
;   LDY|LDX #n / LDA tab,Y|X / STA $02dd,Y|X, searched in the ROM with the
;   self-test window ($5000-$57FF = ROM $D000-$D7FF) on: no OS addresses.
;--------------------------------------------------------------
rv_sp   equ $80                      ; scan pointer
rv_tp   equ $82                      ; the table found
rv_dp   equ $84                      ; its destination in page 2

        ert *<>BOOT_RVEC
rvec    lda #$7F                     ; OS ROM + self-test window
        sta PORTB
        lda #0
        sta rv_sp
        lda #$50
        sta rv_sp+1
rv_lp   ldy #7
        lda (rv_sp),y                ; STA $02dd,Y|X
        cmp #$02
        bne rv_nx
        ldy #1
        lda (rv_sp),y                ; LDY|LDX #n
        ldx #0                       ; X = 0: $0200 ($26 B), 1: $024F ($1C B)
        cmp #$25
        beq rv_c
        inx
        cmp #$1B
        bne rv_nx
rv_c    ldy #6
        lda (rv_sp),y
        cmp rv_dst,x
        bne rv_nx
        ldy #0
        lda (rv_sp),y
        and #$FD                     ; LDY # / LDX #
        cmp #$A0
        bne rv_nx
        ldy #2
        lda (rv_sp),y
        and #$FB                     ; LDA abs,Y / abs,X
        cmp #$B9
        bne rv_nx
        ldy #5
        lda (rv_sp),y
        and #$FB                     ; STA abs,Y / abs,X
        cmp #$99
        bne rv_nx
        ldy #3
        lda (rv_sp),y
        sta rv_tp
        iny
        lda (rv_sp),y
        sta rv_tp+1
        lda rv_dst,x
        sta rv_dp
        lda #$02
        sta rv_dp+1
        ldy rv_cnt,x
rv_cp   lda (rv_tp),y
        sta (rv_dp),y
        dey
        bpl rv_cp
rv_nx   inc rv_sp
        bne rv_lp
        inc rv_sp+1                  ; next page: $5000-$57FF, $C000-$CFFF,
        lda rv_sp+1                  ;   $D800-$FFFF; Z: past $FFFF
        beq rv_x
        cmp #$58
        bne rv_p1
        lda #$C0
        sta rv_sp+1
rv_p1   cmp #$D0
        bne rv_lp
        lda #$D8                     ; (Z = 0: the bne is always taken)
        sta rv_sp+1
        bne rv_lp
rv_x    lda #$FF                     ; self-test window off
        sta PORTB
        rts
rv_dst  dta $00,$4F
rv_cnt  dta $25,$1B
bootc_end
        ert bootc_end>BOOT_ORG+$200        ; ab_go copies two pages
        end
