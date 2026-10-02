;==============================================================
; @ATRBOOT file.ATR -- part of CHLEBA.SYS (system extended RAM),
; included by chleba.asm. Boots an ATR file with the OS in ROM.
;
;   1. the file must lie on a drive with 512 B sectors (SIDE3 APT
;      partition); its blocks are found through the sector maps (mount
;      slot BOOTU);
;   2. the partition start is taken from the APT and VERIFIED by raw SD
;      reads (first map sector and first data block); the SD command
;      argument of every file block goes to the table at $000000 of
;      card RAM: the booted system reads and writes the file in place;
;   3. the handler (hnd.bin) goes to card RAM bank HND_BANK, the VSEROR
;      stub (stub.bin) into the CCTL aperture; ab_go (main RAM) drops SDX,
;      puts the OS back in its own state, hooks VSEROR and boots D1: --
;      no cold start, the OS ROM stays in (programs call SIOV with it).
;==============================================================
ab_main tsx                          ; for the DMA check's abort
        stx ab_sp
        jsr u_getpar
        bne ab_par
        jsr printf
        dta c'Usage: CHLEBA file.ATR',$9b,0
        rts
ab_par  lda #$80                     ; files only
        sta scan
        jsr ffirst
        php
        ldx #4                       ; first map, length
ab_dec  lda dentry+1,x
        sta ab_de,x
        dex
        bpl ab_dec
        lda device
        sta ab_dev
        jsr fclose
        plp
        bpl ab_fnd
        jsr printf
        dta c'CHLEBA: file not found',$9b,0
        rts

ab_fnd  lda ab_dev                   ; DSK1..DSK15 only
        beq ab_ndsk
        cmp #NMOUNT+1
        bcs ab_ndsk
        ldx #BOOTU
        stx unit
        sta m_host-1,x
        sta hunit
        lda ab_de
        sta m_smap_lo-1,x
        lda ab_de+1
        sta m_smap_hi-1,x
        lda #2                       ; (host_io reads m_hss for 'N';
        sta m_hss-1,x                ;  the 'N' length overrides it)
        jsr inval_all
        lda #'N'                     ; host PERCOM: 512 B sectors only
        jsr host_io
        jmi ab_io
        jsr iob_ptr
        ldy #7
        lda (zptr),y
        bne ab_ndsk
        dey
        lda (zptr),y
        cmp #2
        beq ab_hok
ab_ndsk jsr printf
        dta c'CHLEBA: needs a 512 B sector disk',$9b,0
        rts

ab_hok  lda ab_de+2                  ; nblk = (length + 511) >> 9
        clc
        adc #$FF
        lda ab_de+3
        adc #$01
        tax
        lda ab_de+4
        adc #0
        lsr
        sta nblk+1
        txa
        ror
        sta nblk

        lda #0                       ; block 0: map + header
        sta blk
        sta blk+1
        jsr datasec
        jcs ab_map
        lda dsec
        sta dsec0
        lda dsec+1
        sta dsec0+1
        jsr load_data
        jmi ab_io
        jsr ab_hdr
        jcs ab_bad

;--- SD card: addressing, APT, partition start
        jsr inval_data               ; iobuf holds raw blocks from here
        jsr sd_ocr                   ; sdhc
        jcs ab_nowb
        ldx #3
        lda #0
ab_l0   sta lba,x
        dex
        bpl ab_l0
        jsr rd_iob                   ; LBA 0
        jcs ab_nowb
        jsr is_apt
        beq ab_apt
        inc zptr+1                   ; MBR: a $7F partition holds the APT
        ldy #$BE+4                   ; type of entry 0 at $1BE+4
        ldx #4
ab_mbr  lda (zptr),y
        cmp #$7F
        beq ab_m7f
        tya
        clc
        adc #16
        tay
        dex
        bne ab_mbr
        jmp ab_nowb
ab_m7f  tya                          ; start LBA at type+4
        clc
        adc #4
        tay
        ldx #0
ab_m7l  lda (zptr),y
        sta lba,x
        iny
        inx
        cpx #4
        bne ab_m7l
ab_m7r  jsr rd_iob
        jcs ab_nowb
        jsr is_apt
        jne ab_nowb

ab_apt  lda #0                       ; candidates: 512 B DOS partitions
        sta ncand
        lda #31
        sta cd_n
ab_cd   lda zptr                     ; next 16 B entry
        clc
        adc #16
        sta zptr
        bcc ab_cd1
        inc zptr+1
ab_cd1  ldy #0
        lda (zptr),y
        and #$83                     ; reserved bit / 512 BPS
        cmp #$03
        bne ab_cdn
        iny
        lda (zptr),y                 ; type $00
        bne ab_cdn
        lda ncand                    ; cbuf[ncand] = start + offset to sector 1
        asl                          ;   (little-endian)
        asl
        tax
        ldy #14
        lda (zptr),y
        ldy #2
        clc
        adc (zptr),y
        sta cbuf,x
        ldy #15
        lda (zptr),y
        ldy #3
        adc (zptr),y
        sta cbuf+1,x
        iny
        lda (zptr),y
        adc #0
        sta cbuf+2,x
        iny
        lda (zptr),y
        adc #0
        sta cbuf+3,x
        inc ncand
ab_cdn  dec cd_n
        bne ab_cd

        jsr load_data                ; block 0 again (iobuf held raw data)
        jmi ab_io
        lda #0
        sta cd_n
ab_vf   lda cd_n                     ; a candidate must read back the map
        cmp ncand                    ;   sector and block 0 identically
        jcs ab_nowb
        asl
        asl
        tax
        ldy #0
ab_vb   lda cbuf,x
        sta base,y
        inx
        iny
        cpy #4
        bne ab_vb
        lda m_smap_lo+BOOTU-1
        ldx m_smap_hi+BOOTU-1
        jsr lba_of
        lda mapbv
        ldx mapbv+1
        jsr cmp_sec
        bne ab_vnx
        lda dsec0
        ldx dsec0+1
        jsr lba_of
        lda iobv
        ldx iobv+1
        jsr cmp_sec
        beq ab_wbok
ab_vnx  inc cd_n
        bne ab_vf
ab_nowb jsr printf
        dta c'CHLEBA: file not found on the SD card',$9b,0
        rts

;--- SD argument of every file block -> table at $000000
ab_wbok lda #0
        sta p_new+4
        jsr inval_data
        lda #0
        sta blk
        sta blk+1
ab_ld   jsr datasec
        jcs ab_map
        lda dsec                     ; stage[blk & 31] = SD argument
        ldx dsec+1
        jsr lba_of
        jsr lba_arg
        lda blk
        and #31
        asl
        asl
        tax
        ldy #0
ab_lda  lda sa0,y
        sta stage,x
        inx
        iny
        cpy #4
        bne ab_lda
        lda blk                      ; push the stage only when full (32
        and #31                      ;   entries) or at the last block
        cmp #31
        beq ab_psh
        lda blk
        clc
        adc #1
        tax
        lda blk+1
        adc #0
        cpx nblk
        bne ab_npsh
        cmp nblk+1
        bne ab_npsh
ab_psh  lda blk                      ; stage -> (blk & ~31) * 4
        and #$20
        asl
        asl
        sta d_dl
        lda #0
        sta d_dh
        lda blk+1
        sta d_dm
        lda blk
        asl
        rol d_dm
        rol d_dh
        asl
        rol d_dm
        rol d_dh
        lda stagev
        sta zsrc
        lda stagev+1
        sta zsrc+1
        lda #1
        jsr push_n
ab_npsh lda blk                      ; a dot per 128 KB
        bne ab_ldp
        jsr printf
        dta c'.',0
ab_ldp  inc blk
        bne ab_ldq
        inc blk+1
ab_ldq  lda blk
        cmp nblk
        lda blk+1
        sbc nblk+1
        jcc ab_ld

;--- the handler -> bank HND_BANK, the stub -> the aperture
        ldx #3                       ; geometry into the handler image
ab_pp   lda p_new,x
        sta ab_hnd+H_SSZ-HND_ORG,x
        dex
        bpl ab_pp
        lda hndv
        sta zsrc
        lda hndv+1
        sta zsrc+1
        lda #HND_HI
        sta d_dh
        lda #0
        sta d_dm
        sta d_dl
        lda #(ab_hnd_e-ab_hnd+127)/128
        jsr push_n
        lda S3_MISC                  ; stub -> $D500 (card RAM $1FF500)
        and #$FB
        sta S3_MISC
        lda #$40
        sta S3_APER
        ldx #ab_stub_e-ab_stub-1
ab_st   lda ab_stub,x
        sta STUB_IRQ,x
        dex
        bpl ab_st
        ldx #ab_stub_e-ab_stub-1
ab_sc   lda ab_stub,x
        cmp STUB_IRQ,x
        bne ab_scf
        dex
        bpl ab_sc
        lda #0
        sta S3_APER
        jsr printf
        dta $9b,c'CHLEBA: booting',$9b,0
        jmp ab_go
ab_scf  lda #0
        sta S3_APER
        jmp pu_bad

ab_io   jsr printf
        dta c'CHLEBA: disk error',$9b,0
        rts
ab_map  jsr printf
        dta c'CHLEBA: bad sector map',$9b,0
        rts
ab_bad  jsr printf
        dta c'CHLEBA: not a valid ATR',$9b,0
        rts

;--------------------------------------------------------------
; ab_hdr -- ATR header in iobuf -> p_new (ssz, brk, tot).
;   C=1: not an ATR, bad sector size, or longer than the file.
;--------------------------------------------------------------
ab_hdr  jsr iob_ptr
        ldy #0
        lda (zptr),y
        cmp #$96
        jne ah_bad
        iny
        lda (zptr),y
        cmp #$02
        jne ah_bad
        iny                          ; ztmp = paragraphs * 16 = data bytes
        lda (zptr),y
        sta ztmp
        iny
        lda (zptr),y
        sta ztmp+1
        ldy #6
        lda (zptr),y
        sta ztmp+2
        lda #0
        sta ztmp+3
        ldx #4
ah_x16  asl ztmp
        rol ztmp+1
        rol ztmp+2
        rol ztmp+3
        dex
        bne ah_x16
        lda ztmp+3
        jne ah_bad
        lda ztmp                     ; data + 16 <= file length
        clc
        adc #16
        sta zcnt
        lda ztmp+1
        adc #0
        sta zcnt+1
        lda ztmp+2
        adc #0
        sta ztmp+3                   ; (no carry out: data < 2^24)
        lda ab_de+2
        cmp zcnt
        lda ab_de+3
        sbc zcnt+1
        lda ab_de+4
        sbc ztmp+3
        jcc ah_bad
ah_len  lda #0
        sta p_new+1                  ; brk
        ldy #4                       ; sector size -> code, shift
        lda (zptr),y
        tax
        iny
        lda (zptr),y
        cpx #$80
        bne ah_n128
        cmp #0
        jne ah_bad
        ldx #7                       ; 128: tot = bytes >> 7
        bpl ah_set                   ; always (A = 0)
ah_n128 cpx #0
        jne ah_bad
        cmp #2
        beq ah_512
        cmp #1
        jne ah_bad
        ldx ztmp                     ; 256: low byte $80 = normal DD
        cpx #$80
        beq ah_dd
        cpx #0
        jne ah_bad
        inc p_new+1                  ; all sectors 256 B
ah_dd   ldx #8
        bne ah_set                   ; (A = 1)
ah_512  ldx #9
ah_set  sta p_new                    ; ssz
ah_sh   lsr ztmp+2
        ror ztmp+1
        ror ztmp
        dex
        bne ah_sh
        lda ztmp+2
        jne ah_bad
        lda p_new                    ; normal DD: (bytes >> 8) + 2
        cmp #1
        bne ah_tot
        lda p_new+1
        bne ah_tot
        lda ztmp
        clc
        adc #2
        sta ztmp
        bcc ah_tot
        inc ztmp+1
        jeq ah_bad
ah_tot  lda ztmp
        sta p_new+2
        ora ztmp+1
        jeq ah_bad
        lda ztmp+1
        sta p_new+3
        clc
        rts
ah_bad  sec
        rts

; iob_ptr -- zptr = iobuf
iob_ptr lda iobv
        sta zptr
        lda iobv+1
        sta zptr+1
        rts

; is_apt -- Z=1: "APT" at iobuf+1 (zptr = iobuf on return)
is_apt  jsr iob_ptr
        ldy #3
ia_lp   lda (zptr),y
        cmp apt_sig-1,y
        bne ia_x
        dey
        bne ia_lp
ia_x    rts

; lba_of -- lba = base + AX - 1 (32-bit, little-endian)
lba_of  sec
        sbc #1
        bcs lo_1
        dex
lo_1    clc
        adc base
        sta lba
        txa
        adc base+1
        sta lba+1
        lda base+2
        adc #0
        sta lba+2
        lda base+3
        adc #0
        sta lba+3
        rts

; lba_arg -- sa0..sa3 = SD argument of lba, big-endian (x512 on SDSC)
lba_arg lda sdhc
        bne la_hc
        lda lba                      ; byte address = lba << 9
        asl
        sta sa0+2
        lda lba+1
        rol
        sta sa0+1
        lda lba+2
        rol
        sta sa0
        lda #0
        sta sa0+3
        rts
la_hc   ldx #3
        ldy #0
la_lp   lda lba,x
        sta sa0,y
        iny
        dex
        bpl la_lp
        rts

;--------------------------------------------------------------
; push_n -- A x 128 B (zsrc) -> card RAM d_dh:d_dm:d_dl via the CCTL
;   aperture; zsrc and the destination advance. The aperture is on only
;   during a copy: it changes the $D5FD signature SIDE3.SYS reads.
;--------------------------------------------------------------
push_n  sta cd_n
pu_blk  sei                          ; no VBI (SIDE3CLK) while the DMA set is in
        lda #0
        sta NMIEN
        lda S3_MISC                  ; aperture writable
        and #$FB
        sta S3_MISC
        lda #$40
        sta S3_APER
        ldy #127
pu_lp   lda (zsrc),y
        sta $D500,y
        dey
        bpl pu_lp
        lda #APER_HI                 ; source: the aperture
        sta d_sh
        lda #APER_MID
        sta d_sm
        lda #0
        sta d_sl
        lda S3_MODE                  ; DMA register set
        and #$FC
        ora #1
        sta S3_MODE
        ldx #10
pu_set  lda d_sm,x                   ; d_sm.. = $D5F1..$D5FB
        sta $D5F1,x
        dex
        bpl pu_set
        lda d_sh
        ora #$A0                     ; memory mode + start
        sta $D5F0
pu_wt   lda $D5F0
        bmi pu_wt
        ldy #127                     ; read it back the resident's way:
pu_inv  lda (zsrc),y                 ;   aperture = inverted data, then
        eor #$FF                     ;   DMA destination -> aperture
        sta $D500,y
        dey
        bpl pu_inv
        lda d_dm
        sta $D5F1
        lda d_dl
        sta $D5F2
        lda #APER_HI
        sta $D5F3
        lda #APER_MID
        sta $D5F4
        lda #0
        sta $D5F5
        lda d_dh
        ora #$A0
        sta $D5F0
pu_wt2  lda $D5F0
        bmi pu_wt2
        ldy #127
pu_cmp  lda (zsrc),y
        cmp $D500,y
        bne pu_bad
        dey
        bpl pu_cmp
        jsr pu_off
        lda zsrc                     ; next 128 B
        clc
        adc #$80
        sta zsrc
        bcc pu_s
        inc zsrc+1
pu_s    lda d_dl
        eor #$80
        sta d_dl
        bne pu_d
        inc d_dm
pu_d    dec cd_n
        jne pu_blk
        rts

pu_off  lda S3_MODE                  ; primary register set, aperture off
        and #$FC
        sta S3_MODE
        lda #0
        sta S3_APER
        lda #$40
        sta NMIEN
        cli
        rts

pu_bad  jsr pu_off                   ; SIDE3 RAM/DMA not as expected: stop
        ldx ab_sp
        txs
        jsr printf
        dta c'CHLEBA: SIDE3 DMA check failed',$9b,0
        rts

;--------------------------------------------------------------
; SD card over SPI, as SIDE3.SYS does it ($31 select, $39 free-run,
; $30 off). Interrupts stay on: nothing else touches SIDE3 meanwhile.
;--------------------------------------------------------------
; sd_ocr -- CMD58: sdhc = CCS bit. C=1: error.
sd_ocr  sei                          ; no VBI (SIDE3CLK) during SPI
        lda #0
        sta NMIEN
        ldx #3
        lda #0
so_z    sta sa0,x
        dex
        bpl so_z
        lda #$7A
        jsr sd_cmd
        bcs so_x
        cmp #2                       ; R1 0 or 1 (idle)
        jcs sd_fail
        jsr spi_ff                   ; OCR bits 31-24: bit 30 = CCS
        and #$40
        sta sdhc
        jsr spi_ff
        jsr spi_ff
        jsr spi_ff
        jsr sd_end
        clc
so_x    lda #$40
        sta NMIEN
        cli
        rts

; rd_iob -- iobuf = SD block lba. C=1: error.
rd_iob  lda #0
        sta rd_cmp
        lda iobv
        ldx iobv+1
        bne sd_rd                    ; always (iobuf is not in page 0)

; cmp_sec -- compare SD block lba with the 512 B at AX. Z=1: equal.
cmp_sec ldy #$80
        sty rd_cmp
        jsr sd_rd
        bcs cs_ne
        lda rd_bad
        rts
cs_ne   lda #1                       ; error = different
        rts

; sd_rd -- CMD17 lba -> AX (stored; compared when rd_cmp bit 7, then
;   rd_bad <> 0 = a byte differed). C=1: error.
sd_rd   sei                          ; no VBI (SIDE3CLK) during SPI
        ldy #0
        sty NMIEN
        sta zptr
        stx zptr+1
        jsr lba_arg
        lda #$51
        jsr sd_cmd
        jcs sd_fail
        bne sd_fail
        lda #$39                     ; free-run: each read clocks a byte
        sta S3_SD
        ldx #0
        ldy #0
sr_tk   lda S3_SD                    ; data token (shifter idle first)
        and #$02
        bne sr_tk
        lda S3_SPI
        cmp #$FE
        beq sr_go
        dex
        bne sr_tk
        dey
        bne sr_tk
        beq sd_fail
sr_go   sty rd_bad                   ; (Y = 0)
        ldx #2
sr_lp   lda S3_SD
        and #$02
        bne sr_lp
        lda S3_SPI
        bit rd_cmp
        bmi sr_cmp
        sta (zptr),y
        iny
        bne sr_lp
        beq sr_pg
sr_cmp  cmp (zptr),y
        beq sr_eq
        stx rd_bad                   ; (X <> 0)
sr_eq   iny
        bne sr_lp
sr_pg   inc zptr+1
        dex
        bne sr_lp
        jsr ab_rd                    ; CRC
        jsr ab_rd
        jsr ab_wt
        lda #$30
        sta S3_SD
        lda #$40
        sta NMIEN
        cli
        clc
        rts
sd_fail jsr sd_end
        lda #$40
        sta NMIEN
        cli
        sec
        rts

; sd_cmd -- A = command, argument sa0..sa3. C=1: no R1, else A = R1, Z = (R1 = 0)
sd_cmd  ldy #$31
        sty S3_SD
        pha
        jsr spi_ff
        jsr ab_wt
        sty S3_SD                    ; (also clears CRC7)
        ldy #0
        sty S3_CRC
        pla
        jsr ab_wr
        ldx #0
sc_arg  lda sa0,x
        jsr ab_wr
        inx
        cpx #4
        bne sc_arg
        jsr ab_wt
        lda S3_CRC
        jsr ab_wr
        ldx #0
sc_r1   jsr spi_ff
        cmp #$FF
        bne sc_ok
        dex
        bne sc_r1
        sec
        rts
sc_ok   tay
        clc
        rts

; SPI byte I/O: each access to $D5F4 waits until the shifter is idle
;   ($D5F3 bit 1 = busy): an accelerated CPU gets there before the byte
;   is through. ab_wr keeps X and Y; ab_rd: A = the byte.
spi_ff  lda #$FF
        jsr ab_wr
ab_rd   jsr ab_wt
        lda S3_SPI
        rts
ab_wr   pha
        jsr ab_wt
        pla
        sta S3_SPI
        rts
ab_wt   lda S3_SD
        and #$02
        bne ab_wt
        rts

sd_end  ldx #16
se_lp   jsr spi_ff
        dex
        bne se_lp
        jsr ab_wt
        lda S3_SD                    ; deselect
        and #$FE
        sta S3_SD
        rts

apt_sig dta c'APT'
hndv    dta a(ab_hnd)
stagev  dta a(stage)
d_sh    dta 0
d_sm    dta 0                        ; $D5F1 src mid
d_sl    dta 0                        ; $D5F2 src lo
d_dh    dta 0                        ; $D5F3 dst hi
d_dm    dta 0                        ; $D5F4 dst mid
d_dl    dta 0                        ; $D5F5 dst lo
        dta 0                        ; $D5F6 count-1 hi
        dta 127                      ; $D5F7 count-1 lo
        dta 1,1                      ; $D5F8/9 steps
        dta $FF,0                    ; $D5FA AND, $D5FB XOR

ab_hnd  ins 'hnd.bin'        ; D1: handler (window A, $8000)
ab_hnd_e
ab_stub ins 'stub.bin'       ; VSEROR stub (aperture, $D500)
ab_stub_e
ab_boot ins 'bootc.bin'      ; boot step ($0480)
ab_boot_e
