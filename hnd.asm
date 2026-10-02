;--------------------------------------------------------------
; ATRBOOT handler: D1: served straight from the ATR file on the SD card.
; Runs in SIDE3 window A ($8000-$9FFF, card RAM bank HND_BANK), called by
; the stub (stub.asm) from inside the OS's SIO, NMIs off, VBXE MEMAC A off.
;
; SIDE3 window B ($A000-$BFFF) is the handler's view of the card RAM: the
; table at $000000 (the SD command argument of every 512 B block of the
; file, 4 B big-endian) and the scratch block in bank SCR_BANK, which also
; caches the last block read. SPI bytes go straight into window B; the
; sector's part is copied to/from the caller with plain loads and stores
; -- unless the caller's buffer lies in $8000-$BFFF (hidden by the two
; windows) or in the program's MEMAC A window: then 8 B at a time through
; the aperture's data window and the stub's xch. SD commands are retried.
; Returns Y = status (DSTATS, STATUS set) after undoing SIO's POKEY state.
;--------------------------------------------------------------

        icl 'atrboot.inc'

o0      equ $30                      ; 24-bit file offset
o1      equ $31
o2      equ $34
zwin    equ $3D                      ; window enables the stub's hon restores
mc      equ $3C                      ; the program's MEMAC_CONTROL (stub)
WINB    equ $A000

        opt h-
        org HND_ORG

        jmp hnd
p_ssz   dta 0                        ; set by CHLEBA
p_brk   dta 0
p_tot   dta a(0)
        jmp hscan                    ; the stub: find the SIOV caller's frame
        ert p_ssz<>H_SSZ
        ert p_tot<>H_TOT
        ert hnd-3<>H_SCAN

hnd     cld
    .ifdef DEBUG
        jsr d_init
        lda #$25                     ; E
        jsr dbg
    .endif
        lda #$03                     ; windows A (us) and B (card RAM)
        sta zwin
        sta S3_WIN
        lda DBUFA
        sta zbuf
        lda DBUFA+1
        sta zbuf+1
        lda DCOMND
        cmp #'R'
        beq c_rw
        cmp #'W'
        beq c_rw
        cmp #'P'
        beq c_rw
        cmp #'S'
        jeq c_stat
        cmp #'N'
        jeq c_pcm
        cmp #'O'
        beq ok
nak     ldy #139
        bne done
err     ldy #144
        bne done
ok      ldy #1
done    sty DSTATS
        sty $30                      ; STATUS
        lda $10                      ; undo SIO: serial IRQs off, sound off,
        and #$C7                     ;   timeout timer stopped, not critical
        sta $10
        sta $D20E
        lda #0
        sta $D201
        sta $D203
        sta $D205
        sta $D207
        sta $42
        sta $0218
        sta $0219
    .ifdef DEBUG
        sty d_st
        lda #$2B                     ; K
        jsr dbg
        ldy d_st
    .endif
        rts

;--- 'R' / 'W' / 'P': block by block
c_rw    jsr xlat
        bcs nak
pc_lp   jsr blk_ld                   ; window B scratch = SD block holding o
        bcs err
        lda #0                       ; n = 512 - (o & 511)
        sec
        sbc o0
        sta n_l
        lda o1                       ; 2 - (o1 & 1) - borrow: -x-1 + 2 + C
        and #1                       ;   (C from the sbc, kept by lda/and/eor)
        eor #$FF
        adc #2
        sta n_h
        lda rl_l                     ; n = min(n, rl)
        cmp n_l
        lda rl_h
        sbc n_h
        bcs pc_n
        lda rl_l
        sta n_l
        lda rl_h
        sta n_h
pc_n    lda rl_l                     ; rl -= n
        sec
        sbc n_l
        sta rl_l
        lda rl_h
        sbc n_h
        sta rl_h
        jsr fast                     ; C=0: the caller's buffer is visible
        bcs pc_slow
        jsr scr_p                    ; za = scratch + (o & 511)
        lda DCOMND
        cmp #'R'
        bne pc_fw
        lda zbuf                     ; read: scratch -> caller
        sta zb
        lda zbuf+1
        sta zb+1
pc_fc   lda n_l                      ; the whole piece in one copy
        sta cnt
        ldx n_h
        jsr cp16
        lda n_l                      ; zbuf += n, o += n
        ldx n_h
        jsr adv
pc_end  lda DCOMND
        cmp #'R'
        bne pc_wb
pc_nx   lda rl_l
        ora rl_h
        jne pc_lp
        jmp ok
pc_wb   jsr sd_wsnd                  ; write: the block back to the SD card
        jcs err
        bcc pc_nx
pc_fw   lda za                       ; write: caller -> scratch
        sta zb
        lda za+1
        sta zb+1
        lda zbuf
        sta za
        lda zbuf+1
        sta za+1
        jmp pc_fc

; pc_slow -- the caller's buffer is under the windows: DATA_N bytes at a time
;   through the stub's data window
pc_slow lda n_h                      ; k = min(n, DATA_N)
        bne mv_8
        lda n_l
        cmp #DATA_N
        bcc mv_k
mv_8    lda #DATA_N
mv_k    sta cnt
        lda n_l                      ; n -= k
        sec
        sbc cnt
        sta n_l
        bcs mv_1
        dec n_h
mv_1    jsr scr_p                    ; za = scratch + (o & 511)
        lda DCOMND
        cmp #'R'
        bne mv_w
        ldy cnt                      ; read: scratch -> data window -> caller
        dey
mv_rc   lda (za),y
        sta STUB_DATA,y
        dey
        bpl mv_rc
        lda #<STUB_DATA
        sta za
        lda #>STUB_DATA
        sta za+1
        lda zbuf
        sta zb
        lda zbuf+1
        sta zb+1
        jsr STUB_XCH
        jmp mv_nx
mv_w    lda za                       ; write: caller -> data window -> scratch
        sta t_l
        lda za+1
        sta t_m
        lda zbuf
        sta za
        lda zbuf+1
        sta za+1
        lda #<STUB_DATA
        sta zb
        lda #>STUB_DATA
        sta zb+1
        jsr STUB_XCH
        lda t_l
        sta zb
        lda t_m
        sta zb+1
        ldy cnt
        dey
mv_wc   lda STUB_DATA,y
        sta (zb),y
        dey
        bpl mv_wc
mv_nx   lda cnt                      ; zbuf += k, o += k
        ldx #0
        jsr adv
        lda n_l
        ora n_h
        jne pc_slow
        jmp pc_end

; scr_p -- za = scratch + (o & 511) in window B
scr_p   lda o0
        sta za
        lda o1
        and #1
        ora #>WINB
        sta za+1
        rts

; adv -- zbuf += XA, o += XA
adv     tay                          ; (the low byte waits in Y, not RAM)
        clc
        adc zbuf
        sta zbuf
        txa
        adc zbuf+1
        sta zbuf+1
        tya
        clc
        adc o0
        sta o0
        txa
        adc o1
        sta o1
        bcc adv_x
        inc o2
adv_x   rts

; cp16 -- X:cnt bytes (za) -> (zb)
cp16    ldy #0
        txa
        beq cp_r
cp_p
    .rept 8                          ; 256 is a multiple of 8
        lda (za),y
        sta (zb),y
        iny
    .endr
        bne cp_p
        inc za+1
        inc zb+1
        dex
        bne cp_p
cp_r    lda cnt                      ; a multiple of 8 (always: sector pieces
        beq cp_x                     ;   start 16 B into a block): unrolled
        and #7
        bne cp_r1
cp_8
    .rept 8
        lda (za),y
        sta (zb),y
        iny
    .endr
        cpy cnt
        bne cp_8
        rts
cp_r1   ldx cnt
cp_l    lda (za),y
        sta (zb),y
        iny
        dex
        bne cp_l
cp_x    rts

; fast -- C=0 when the caller's buffer zbuf..zbuf+n-1 is outside the two
;   windows ($8000-$BFFF) and outside the program's MEMAC A CPU window
fast    lda mc                       ; usual: no MEMAC A window and the buffer
        and #$08                     ;   below $7E00 (zbuf + n - 1 < $8000,
        bne fs_all                   ;   n <= 512): visible, C = 0
        lda zbuf+1
        cmp #$7E
        bcc fs_x
fs_all  lda zbuf                     ; t_m = high byte of zbuf + n - 1
        clc                          ;   (n >= 1)
        adc n_l
        tax
        lda zbuf+1
        adc n_h
        sta t_m
        txa
        bne fs_2
        dec t_m                      ; zbuf + n ends a page: the last byte is before it
fs_2    lda #$80                     ; windows: [$80, $C0)
        ldx #$C0
        jsr fs_hit
        bcs fs_x
        lda mc                       ; MEMAC A CPU window on?
        and #$08
        beq fs_ok
        lda mc
        and #3
        tax
        lda mc
        and #$F0
        sta t_h
        clc
        adc fs_sz,x
        bcc fs_3
        lda #$FF                     ; (window reaches the top of memory)
fs_3    tax
        lda t_h
        jsr fs_hit
        bcs fs_x
fs_ok   clc
fs_x    rts
; fs_hit -- C=1 when pages [zbuf+1 .. t_m] meet [A, X)
fs_hit  sta t_h
        stx t_n
        lda t_m                      ; end < lo: no
        cmp t_h
        bcc fh_no
        lda zbuf+1                   ; start >= hi: no
        cmp t_n
        bcs fh_no
        sec
        rts
fh_no   clc
        rts
fs_sz   dta $10,$20,$40,$80          ; MEMAC A window size in pages

;--- 'S': 4 status bytes; 'N': PERCOM, one track of tot sectors
c_stat  lda p_ssz
        cmp #1                       ; C = double density
        lda #$10                     ; motor on
        bcc st_sd
        lda #$30
st_sd   sta rbuf+12
        ldx #12
        lda #4
        jsr reply
        jmp ok
c_pcm   lda p_tot+1
        sta rbuf+2                   ; sectors per track, MSB first
        lda p_tot
        sta rbuf+3
        ldx p_ssz
        lda bps_hi,x
        sta rbuf+6
        lda bps_lo,x
        sta rbuf+7
        lda dens,x
        sta rbuf+5
        ldx #0
        lda #8
        jsr reply
        lda #8                       ; the other 4 of the 12
        ldx #0
        jsr adv
        ldx #8
        lda #4
        jsr reply
        jmp ok

; reply -- rbuf[X..X+A-1] (A <= DATA_N) -> data window -> caller
reply   sta cnt
        ldy #0
rp_lp   lda rbuf,x
        sta STUB_DATA,y
        inx
        iny
        cpy cnt
        bne rp_lp
        lda #<STUB_DATA
        sta za
        lda #>STUB_DATA
        sta za+1
        lda zbuf
        sta zb
        lda zbuf+1
        sta zb+1
        jmp STUB_XCH

;--------------------------------------------------------------
; xlat -- sector DAUX -> o (file offset), rl (sector size). C=1: sector 0
;   or past the image. offset = 16 + (sec-1) << (7|8|9), or for the
;   256 B sectors of a normal DD image 16 + $80 + (sec-3) << 8.
;--------------------------------------------------------------
xl_bad  sec                          ; (in reach of xlat's branches)
        rts
xlat    lda DAUX1
        ora DAUX2
        beq xl_bad
        lda p_tot                    ; sec <= tot
        cmp DAUX1
        lda p_tot+1
        sbc DAUX2
        bcc xl_bad
        lda DAUX1                    ; v = sec - 1 (C = 1 here)
        sbc #1
        sta o0
        lda DAUX2
        sbc #0                       ; (C = 1: sec >= 1)
        sta o1
        ldx p_ssz
        bne xl_n128
xl_128  lda o1                       ; o = 16 + v << 7: v >> 1 in the upper
        lsr                          ;   bytes, v's bit 0 to bit 7 of o0
        sta o2                       ;   (+16 never carries: o0 bits 6-0 are 0)
        lda o0
        ror
        sta o1
        lda #0
        ror
        ora #16
        sta o0
        lda #$80
        sta rl_l
        lda #0
        sta rl_h
        clc
        rts
xl_n128 dex
        bne xl_512
        lda p_brk                    ; 256 B: sectors 1-3 are 128 B unless
        bne xl_256                   ;   the image is "broken" DD
        lda DAUX2
        bne xl_dd
        lda DAUX1
        cmp #4
        bcc xl_128
xl_dd   lda o0                       ; o = 16 + $80 + (v - 2) << 8
        sbc #2                       ; (C = 1: from the sbc #0 above, kept by
        tax                          ;   ldx/bne/dex/lda; or the cmp #4 not taken)
        lda o1
        sbc #0
        sta o2
        stx o1
        lda #16+$80
        bne xl_r256                  ; (always)
xl_256  lda o1                       ; o = 16 + v << 8
        sta o2
        lda o0
        sta o1
        lda #16
xl_r256 sta o0
        lda #0
        sta rl_l
        lda #1
        sta rl_h
        clc
        rts
xl_512  lda o0                       ; o = 16 + v << 9
        asl
        tax
        lda o1
        rol
        sta o2
        stx o1
        lda #16
        sta o0
        lda #0
        sta rl_l
        lda #2
        sta rl_h
        clc
        rts

;--------------------------------------------------------------
; blk_ld -- window B scratch = the SD block holding offset o (unless
;   cached); sa0 = its SD argument. Leaves window B on the scratch bank.
;   C=1: error (after 3 tries).
;--------------------------------------------------------------
blk_ld  lda o1                       ; the entry: (o >> 7) & ~3 (4 B per 512 B
        asl                          ;   block, 17 bits): low byte ...
        and #$FC
        sta za
        lda o2                       ; ... bits 15-8, C = bit 16
        rol
        tax
        and #$1F                     ; window B offset: bits 12-0
        ora #>WINB
        sta za+1
        txa                          ; bank = bits 16-13: (C:A) rotated left
        rol                          ;   4 = right 5 in 9 bits, the low 4
        rol                          ;   bits kept (and/ora/sta/tax/txa keep C)
        rol
        rol
        and #$0F
        sta S3_BANKB
        ldy #3
        ldx #0                       ; X = 0: matches the cached block
bl_a    lda (za),y
        cmp sa0,y
        beq bl_b
        inx
bl_b    sta sa0,y
        dey
        bpl bl_a
        lda #SCR_BANK
        sta S3_BANKB
        txa
        ora c_bad
        bne bl_rd
        clc                          ; cached
        rts
bl_rd   lda #1
        sta c_bad
        lda #3
        sta tries
bl_try
    .ifdef DEBUG
        lda #$23                     ; C
        jsr dbg
    .endif
        lda #$51                     ; CMD17 READ_SINGLE_BLOCK
        jsr sd_cmd
        bcs bl_f
        bne bl_f
        lda #$39                     ; free-run: each read clocks a byte
        sta S3_SD
    .ifdef DEBUG
        lda #$34                     ; T
        jsr dbg
    .endif
        ldx #0
        ldy #0
bl_tk   lda S3_SD                    ; data token (shifter idle first)
        and #$02
        bne bl_tk
        lda S3_SPI
        cmp #$FE
        beq bl_go
        dex
        bne bl_tk
        dey
        bne bl_tk
        beq bl_f
bl_go
    .ifdef DEBUG
        lda #$24                     ; D
        jsr dbg
    .endif
        lda S3_MODE                  ; 512 B: SIDE3's SD-read DMA -> the scratch
        ora #$01                     ;   bank, a byte a bus cycle (the token read
        sta S3_MODE                  ;   above clocked in data byte 0 already)
        lda #SCR_BANK>>3             ; destination = bank SCR_BANK (plain
        sta $D5F3                    ;   stores: sta abs,x reads its I/O
        lda #SCR_BANK<<5&$FF         ;   target first)
        sta $D5F4
        lda #0
        sta $D5F5
        lda #>511                    ; count - 1
        sta $D5F6
        lda #<511
        sta $D5F7
        lda #1                       ; destination step
        sta $D5F9
        lda #$80                     ; SD read (%00), start
        sta $D5F0
bl_dw   lda $D5F0
        bmi bl_dw
        lda S3_MODE                  ; primary set back (bits 1-0 = 0)
        and #$FC
        sta S3_MODE
        jsr spi_rd                   ; CRC
        jsr spi_rd
        jsr spi_wt
        lda #$30
        sta S3_SD
        lda #0
        sta c_bad                    ; scratch = block sa0
        clc
        rts
bl_f    jsr sd_end
        dec tries
        bne bl_try
        sec
        rts

;--------------------------------------------------------------
; sd_wsnd -- window B scratch -> the SD block of sa0 (CMD24). C=1: error.
;--------------------------------------------------------------
sd_wsnd lda #3
        sta tries
sw_try  lda #$58                     ; CMD24 WRITE_BLOCK
        jsr sd_cmd
        bcs sw_f
        bne sw_f                     ; R1 <> 0
        lda #$FE                     ; start token
        jsr spi_wr
        ldy #0
sw_t1   lda S3_SD
        and #$02
        bne sw_t1
        lda WINB,y
        sta S3_SPI
        iny
        bne sw_t1
sw_t2   lda S3_SD
        and #$02
        bne sw_t2
        lda WINB+$100,y
        sta S3_SPI
        iny
        bne sw_t2
        jsr spi_ff                   ; CRC (ignored)
        jsr spi_ff
        jsr sd_resp                  ; data response xxx0 0101 = accepted
        bcs sw_f
        and #$1F
        cmp #$05
        bne sw_f
        ldx #0                       ; busy ($00) for up to ~1 s
        ldy #0
sw_bz   jsr spi_ff
        bne sw_ok
        dex
        bne sw_bz
        dey
        bne sw_bz
sw_f    jsr sd_end
        dec tries
        bne sw_try
        lda #1                       ; scratch no longer trusted
        sta c_bad
        sec
        rts
sw_ok   clc

; sd_end -- 16 idle bytes, deselect (keeps C)
sd_end  ldx #16
se_lp   jsr spi_ff
        dex
        bne se_lp
        jsr spi_wt
        lda #$30
        sta S3_SD
        rts

; sd_cmd -- A = command, argument sa0..sa3. C=1: no R1, else A = R1, Z = (R1 = 0)
sd_cmd  ldy #$31                     ; select, fast clock, power
        sty S3_SD
        pha
        jsr spi_ff
        jsr spi_wt
        sty S3_SD                    ; (also clears CRC7)
        ldy #0
        sty S3_CRC
        pla
        jsr spi_wr
        ldx #0
sc_arg  lda sa0,x
        jsr spi_wr
        inx
        cpx #4
        bne sc_arg
        jsr spi_wt
        lda S3_CRC
        jsr spi_wr
        jsr sd_resp
        bcs sc_x
        tay
sc_x    rts

; sd_resp -- first byte <> $FF within 256 tries. C=1: timeout.
sd_resp ldx #0
sr_lp   jsr spi_ff
        cmp #$FF
        bne sr_ok
        dex
        bne sr_lp
        sec
        rts
sr_ok   clc
        rts

;--------------------------------------------------------------
; hscan -- the frame the stub returns through: X = S for its TXS, C=0;
;   C=1: no SIOV caller on the stack (the OS gets the IRQ). Two passes up
;   the stack, each a return address P with a JSR at P-2:
;   1. JSR $E459 / JSR $E453 (SIOV, DSKINV);
;   2. else the first JSR outside the OS ROM: programs that reach SIOV
;      through a JMP of their own (FLOP's loader: JSR $07E6 ... JMP $E459).
;   The 3 bytes come through xch (window A off: the program's own map);
;   $D000-$D7FF is never read (I/O side effects).
;--------------------------------------------------------------
hscan   lda #<STUB_DATA              ; xch: 3 bytes (za) -> the data window
        sta zb
        lda #>STUB_DATA
        sta zb+1
        lda #3
        sta cnt
        lda #0                       ; pass 1
        sta sc_m
sc_go   tsx                          ; X = the stub's S: skip our own return
        inx                          ;   address (the loop's inx then reads
        inx                          ;   the first byte the stub had stacked)
sc_lp   inx
        beq sc_end
        lda $0100,x                  ; za = P - 2: the JSR
        sec
        sbc #2
        sta za
        lda $0101,x
        sbc #0
        sta za+1
        sta sc_h                     ; (pass 2 tests the caller's page)
        and #$F8
        cmp #$D0                     ; I/O: never read
        beq sc_lp
        eor #$80                     ; $80-$9F (under window A) -> $00-$1F
        cmp #$20
        bcc sc_xw
sc_d    ldy #0                       ; the JSR, read where it lies
        lda (za),y
        cmp #$20                     ; JSR abs: most candidates end here
        bne sc_lp
        lda sc_m
        bne sc_p2
        ldy #2                       ; pass 1: its target $E459 / $E453
        lda (za),y
        cmp #>SIOV
        bne sc_lp
        dey
        lda (za),y
        cmp #<SIOV
        beq sc_hit
        cmp #<DSKINV
        bne sc_lp
        beq sc_hit
sc_p2   lda sc_h                     ; pass 2: called from below the ROM
        cmp #$C0
        bcs sc_lp
sc_hit  dex                          ; S: the next RTS pulls this frame
        clc
        rts
sc_xw   jsr STUB_XCH                 ; window A hides it: the program's bytes
        lda #<STUB_DATA              ;   through xch into the data window,
        sta za                       ;   read there (keeps X)
        lda #>STUB_DATA
        sta za+1
        bne sc_d
sc_end  lda sc_m
        bne sc_no
        inc sc_m
        bne sc_go
sc_no   sec
        rts
sc_m    dta 0
sc_h    dta 0

; SPI byte I/O: each access to $D5F4 waits until the shifter is idle
;   ($D5F3 bit 1 = busy) -- an accelerated CPU reaches the next access
;   before the byte is through. spi_wr keeps X and Y; spi_rd A = the byte.
spi_ff  lda #$FF
        jsr spi_wr
spi_rd  jsr spi_wt
        lda S3_SPI
        rts
spi_wr  pha
        jsr spi_wt
        pla
        sta S3_SPI
        rts
spi_wt  lda S3_SD
        and #$02
        bne spi_wt
        rts

;--------------------------------------------------------------
; DEBUG: calls, sector, last status and phase on the 13th text row of the
;   program's display list (Doom's loader: its empty last row), when that
;   list starts with 3 blank lines and an LMS mode-2 row below $8000.
;--------------------------------------------------------------
    .ifdef DEBUG
d_init  inc d_cnt
        bne di_1
        inc d_cnt+1
di_1    lda $0230
        sta zr
        lda $0231
        sta zr+1
        lda #0
        sta d_on
        ldy #3
        lda (zr),y
        cmp #$42
        bne di_x
        iny
        lda (zr),y
        clc
        adc #<480
        sta d_p
        iny
        lda (zr),y
        adc #>480
        sta d_p+1
        cmp #$80
        bcs di_x
        inc d_on
di_x    rts
dbg     sta d_ph
        lda d_on
        beq dg_x
        lda d_p
        sta zr
        lda d_p+1
        sta zr+1
        ldy #0
        lda d_cnt+1
        jsr d_hex
        lda d_cnt
        jsr d_hex
        jsr d_sp
        lda DAUX2
        jsr d_hex
        lda DAUX1
        jsr d_hex
        jsr d_sp
        lda d_st
        jsr d_hex
        jsr d_sp
        lda d_ph
        sta (zr),y
dg_x    rts
d_sp    lda #0
        sta (zr),y
        iny
        rts
d_hex   pha
        lsr
        lsr
        lsr
        lsr
        jsr d_dig
        pla
        and #$0F
d_dig   cmp #10
        bcc dd_1
        adc #6                       ; C = 1: +7
dd_1    adc #$10                     ; screen code of '0' / 'A'-10
        sta (zr),y
        iny
        rts
d_cnt   dta a(0)
d_p     dta a(0)
d_on    dta 0
d_ph    dta 0
d_st    dta 0
    .endif

; tables (by p_ssz)
bps_hi  dta $00,$01,$02
bps_lo  dta $80,$00,$00
dens    dta $00,$04,$04

; variables (window A RAM is writable)
c_bad   dta 1                        ; 1 = scratch holds no valid block
sa0     dta 0,0,0,0                  ; SD argument of the scratch block
tries   dta 0
rl_l    dta 0
rl_h    dta 0
n_l     dta 0
n_h     dta 0
t_l     dta 0
t_m     dta 0
t_h     dta 0
t_n     dta 0
rbuf    dta 1,0,0,0,0,0,0,0,$FF,0,0,0  ; PERCOM
        dta 0,$FF,$E0,0              ; status

hnd_end
        ert hnd_end>$A000
        end
