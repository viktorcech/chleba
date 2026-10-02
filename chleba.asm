;--------------------------------------------------------------
; CHLEBA.SYS -- SpartaDOS X driver: ATR image files as disk drives.
;
; An ATR file lying on any SpartaDOS-formatted drive (e.g. a SIDE3 APT
; partition) is served as drive Dn: (n = 1..15), the way the IDE Plus 2.0
; BIOS does it. Mount/unmount uses the IDE Plus protocol, so
; ATRM.COM / ATRU.COM work unchanged:
;   SIO $20 unit 1 'A' write: mount  (128 B packet, aux1 = drive)
;   SIO $20 unit 1 'A' read : unmount, returns flags + file path
; Every other $20 request passes on (SIDE3.SYS keeps its APT API).
;
; The driver sits in the SDX sio_vector chain ahead of the HDD driver and
; reads the host sectors by calling the drivers behind it directly, so the
; ATR file may be fragmented: its SpartaDOS sector maps are walked.
;
; CONFIG.SYS: DEVICE CHLEBA  (after DEVICE SIDE3)
;
; Command CHLEBA file.ATR (symbol @CHLEBA): boots an ATR lying on a SIDE3
; APT partition, with any OS in ROM (abcmd.asm; the boot step bootc.asm,
; the VSEROR stub stub.asm and the D1: handler hnd.asm, built to .bin first).
;--------------------------------------------------------------

        icl 'atrboot.inc'

V_setme   equ $07F1
V_popme   equ $07F4
sio_vector equ $0718
memreix   equ $0787
jfsymbol  equ $07EB

dcmnd     equ $0302
dtimlo    equ $0306
dunuse    equ $0307
daux3     equ $030C
daux4     equ $030D
dbfx2     equ $030F

; zero page: $30-$3F belong to the SIO driver ($36/$37 must survive)
zsrc      equ $30                    ; copy source
zdst      equ $32                    ; copy destination
zcnt      equ $34                    ; copy count (16-bit)
zptr      equ $38                    ; general pointer
ztmp      equ $3A                    ; 4 B scratch ($3A-$3D)
ziob      equ $3E                    ; iob_put_x pointer

NMOUNT    equ 15
NSLOT     equ NMOUNT+1               ; slot 16: the booted file (no drive)
BOOTU     equ NSLOT
PATHLEN   equ 64

ST_OK     equ 1
ST_NAK    equ 139                    ; bad command / sector out of range
ST_WP     equ 144                    ; write protected
ST_DENIED equ 176                    ; wrong buffer size
ST_ARCH   equ 184                    ; 24-bit buffer

extended  smb 'EXTENDED'
install   smb 'INSTALL'
printf    smb 'PRINTF'
comtab2   smb 'COMTAB2'
u_getpar  smb 'U_GETPAR'
ffirst    smb 'FFIRST'
fclose    smb 'FCLOSE'

device    equ $0761
scan      equ $0779
dentry    equ $0789                  ; +1 first sector map, +3 length (3 B)

;==============================================================
; installer (non-resident, $0400-$06FF scratch)
;==============================================================
        blk sparta $0400

inst    ldx #6                       ; loaded twice? an sio_vector entry
inst_ck lda sio_vector+1,x           ;   preceded by our signature says so
        beq inst_nx
        sta $81
        lda sio_vector,x
        sec
        sbc #6
        sta $80
        bcs inst_c1
        dec $81
inst_c1 ldy #5
inst_cl lda ($80),y
        cmp signame,y
        bne inst_nx
        dey
        bpl inst_cl
        jsr printf
        dta c'CHLEBA: already installed',$9b,0
        rts
inst_nx dex
        dex
        bpl inst_ck

inst_new
        lda iobend+1                 ; iobuf must stay below $4000: the bank
        cmp #$40                     ;   window would hide it during copies
        bcc inst_ram
        jsr printf
        dta c'CHLEBA: MEMLO too high',$9b,0
        rts

inst_ram
        ldx #6                       ; last free sio_vector slot
inst_srch
        lda sio_vector+1,x
        beq inst_found
        dex
        dex
        bpl inst_srch
        jsr printf
        dta c'CHLEBA: SIO table full',$9b,0
        rts

inst_found
        stx our_slot
        lda extended                 ; ext RAM index of the resident code
        sta ext_m
        lda entryv
        sta sio_vector,x
        lda entryv+1
        sta sio_vector+1,x
        jsr printf
        dta c'CHLEBA 1.1: ATR images as Dn:, CHLEBA file.ATR',$9b,0
        dec install
        rts

signame dta c'CHLEBA'

;==============================================================
; resident, main RAM: SIO entry, bank-switching copy loops, buffers
;==============================================================
        blk reloc main

        dta c'CHLEBA'                ; signature: the installer looks for it
entry   lda #$00                     ; operand = ext RAM index
ext_m   equ *-1
        jsr V_setme
        jsr do_sio                   ; C=1: not ours, else A = status
        php
        jsr V_popme                  ; keeps A
        plp
        tay                          ; Y = status (SIOV compatibility)
        rts

;--------------------------------------------------------------
; copy -- zcnt bytes [zsrc] -> [zdst] with the caller's I/O memory
;   (memreix as saved at entry) switched in. One side is always iobuf,
;   which is main RAM below $4000 and so stays visible.
;--------------------------------------------------------------
copy    lda sv_mrx
        jsr V_setme
        ldy #0
        ldx zcnt+1
        beq copy_part
copy_pg
    .rept 8                          ; 256 is a multiple of 8
        lda (zsrc),y
        sta (zdst),y
        iny
    .endr
        bne copy_pg
        inc zsrc+1
        inc zdst+1
        dex
        bne copy_pg
copy_part
        lda zcnt                     ; sector pieces are multiples of 16 (the
        beq copy_done                ;   16 B header): unrolled; else (status,
        and #7                       ;   PERCOM) byte by byte
        bne copy_by
copy_8
    .rept 8
        lda (zsrc),y
        sta (zdst),y
        iny
    .endr
        cpy zcnt
        bne copy_8
        beq copy_done
copy_by ldx zcnt
copy_lp lda (zsrc),y
        sta (zdst),y
        iny
        dex
        bne copy_lp
copy_done
        jmp V_popme

;--------------------------------------------------------------
; @ATRBOOT entry, and its last step (ab_go): leave SDX without a cold
;   start -- OS ROM in, the OS's own interrupt vectors and handlers back,
;   VSEROR to the stub in the SIDE3 aperture -- then boot D1: (bootc.asm
;   at $0480). The handler (window A) serves every SIOV/DSKINV call for
;   D1:, ROM in or not.
;--------------------------------------------------------------
ab_ent  lda ext_m
        jsr V_setme
        jsr ab_main                  ; returns only on an error
        jmp V_popme

ab_go   sei
        cld
        lda #0
        sta NMIEN
        ldx #0                       ; boot step -> $0480 (ext RAM still in)
ab_gb   lda ab_boot,x
        sta BOOT_ORG,x
        lda ab_boot+$100,x
        sta BOOT_ORG+$100,x
        inx
        bne ab_gb
        lda p_new                    ; its copy of the sector size code
        sta BOOT_SSZ
        lda #$F2                     ; stub's MEMAC_CONTROL: a dummy ($D5F2)
        ldx #$D5                     ;   unless a VBXE is found below
        jsr ab_mc
        lda #$10                     ; VBXE (CORE_VERSION = $10) at $D640
        cmp $D640                    ;   or $D740: XDL, blitter, MEMAC off
        bne ab_vb7
        lda #$5E
        ldx #$D6
        jsr ab_mc
        lda #0
        sta $D640
        sta $D653
        sta $D65D
        sta $D65E
        sta $D65F
ab_vb7  lda #$10
        cmp $D740
        bne ab_vbn
        lda #$5E
        ldx #$D7
        jsr ab_mc
        lda #0
        sta $D740
        sta $D753
        sta $D75D
        sta $D75E
        sta $D75F
ab_vbn  lda S3_MODE                  ; SDX cartridge emulation off
        and #$FC
        tay
        ora #$02
        sta S3_MODE
        lda $D5F7
        and #$7F
        sta $D5F7
        sty S3_MODE                  ; primary register set
        lda #HND_BANK                ; window A bank = the handler
        sta S3_BANKA
        lda #0
        sta S3_MISC                  ; RAM windows writable, aperture too
        sta S3_WIN                   ; all windows off: SDX gone, TRIG3 = 0
        lda #$40
        sta S3_APER                  ; the stub at $D500
        lda #$FF                     ; OS ROM, no BASIC, no banks
        sta PORTB
        ldx #$FF
        txs
        jsr INTINV                   ; GINTLK, NMIEN (OS 2.48: no vectors)
        jsr BOOT_RVEC                ; the RAM vectors from the OS ROM
        ldx #$25                     ; HATABS: P: C: E: S: K: only
ab_gh   lda ab_hat,x
        sta $031A,x
        dex
        bpl ab_gh
        jsr $E46E                    ; CIOINV: IOCBs closed
        lda #0
        sta $06                      ; TRAMSZ: no cartridge
        sta $09                      ; BOOT?
        lda TRIG3
        sta $03FA                    ; GINTLK
        lda #$C0
        sta $02E4                    ; RAMSIZ
        sta $6A                      ; RAMTOP
        lda $0312                    ; OS 2.48: D1: standard speed, no '?' probe
        ora #$0F                     ;   (what it records itself for such a drive)
        sta $0312
        lda VSEROR                   ; hook: VSEROR -> stub, old one kept there
        sta STUB_OLD
        lda VSEROR+1
        sta STUB_OLD+1
        lda #<STUB_IRQ
        sta VSEROR
        lda #>STUB_IRQ
        sta VSEROR+1
        lda #$40
        sta NMIEN
        cli
        jmp $0480

; ab_mc -- AX = MEMAC_CONTROL address into the stub (in the aperture)
ab_mc   ldy #$40
        sty S3_APER
        ldy #0
        sty S3_MISC
        sta STUB_MC1
        sta STUB_MC2
        sta STUB_MC3
        stx STUB_MC1+1
        stx STUB_MC2+1
        stx STUB_MC3+1
        rts

ab_hat  dta c'P',a($E430),c'C',a($E440),c'E',a($E400),c'S',a($E410),c'K',a($E420)
        :23 dta 0

entryv  dta a(entry)
iobv    dta a(iobuf)
iobend  dta a(iobuf+$1FF)
our_slot dta 0
sv_mrx  dta 0                        ; caller's memreix

iobuf   equ *                        ; 512 B host sector buffer
        blk empty $200 main

;==============================================================
; resident, system extended RAM: the driver proper
;==============================================================
        blk reloc extended

;--------------------------------------------------------------
; do_sio -- C=1: not ours. C=0: done, A = status.
;--------------------------------------------------------------
do_sio  lda ddevic
        and #$7F
        cmp #$20
        beq dev20
        and #$70
        cmp #$30
        bne pass
        ldx dunit                    ; SWAP: logical -> actual unit
        beq pass
        cpx #NMOUNT+1
        bcs pass
        lda comtab2+2-1,x
        tax
        lda m_flags-1,x
        bmi disk
pass    sec
        rts

dev20   lda dunit
        cmp #1
        bne pass
        lda dcmnd
        cmp #'A'
        bne pass
        jsr save_dcb
        jmp mount_cmd

;--------------------------------------------------------------
; save_dcb / finish -- the caller's (X)DCB is ours to clobber while the
;   host driver is called; finish restores it and posts the status.
;--------------------------------------------------------------
save_dcb
        ldy #15
sv_lp   lda ddevic,y
        sta sv_dcb,y
        dey
        bpl sv_lp
        lda memreix
        sta sv_mrx
        rts

finish  sta status
        ldy #15
fin_lp  lda sv_dcb,y
        sta ddevic,y
        dey
        bpl fin_lp
        lda sv_mrx
        sta memreix
        lda status
        sta dstats
        clc
        rts

;--------------------------------------------------------------
; disk -- a request for a mounted unit X (1..15)
;--------------------------------------------------------------
disk    stx unit
        jsr save_dcb
        lda ddevic
        bpl disk_dcb
        lda daux3                    ; XDCB: 16-bit sectors, 16-bit buffers
        ora daux4
        bne err_nak
        lda dbfx1
        beq disk_dcb
        lda #ST_ARCH
        jmp finish

disk_dcb
        lda dcmnd
        cmp #'R'
        jeq cmd_read
        cmp #'W'
        jeq cmd_write
        cmp #'P'
        jeq cmd_write
        cmp #'S'
        jeq cmd_status
        cmp #'N'
        jeq cmd_percom
        cmp #'O'
        beq ok
err_nak lda #ST_NAK
        jmp finish
ok      lda #ST_OK
        jmp finish
err_den lda #ST_DENIED
        jmp finish

;--------------------------------------------------------------
; 'S' -- 4 status bytes
;--------------------------------------------------------------
cmd_status
        ldx unit
        lda m_flags-1,x
        and #$06                     ; ss code: 0 = 128 B
        cmp #$01                     ; C = DD
        lda #$10                     ; motor on
        bcc st_sd
        ora #$20                     ; double density
st_sd   ldy #$FF
        pha
        lda m_flags-1,x
        lsr                          ; C = read-only
        pla
        bcc st_rw
        ora #$08
        ldy #$BF
st_rw   sta tbuf
        sty tbuf+1
        lda #$E0
        sta tbuf+2
        lda #0
        sta tbuf+3
        lda #4
        jmp reply_tbuf

;--------------------------------------------------------------
; 'N' -- PERCOM block: a hard disk of tot sectors (1 track), except the
;   720-sector SD/DD and 1040-sector ED floppy geometries.
;--------------------------------------------------------------
cmd_percom
        ldx unit
        lda #1
        sta tbuf                     ; tracks
        lda #0
        sta tbuf+1                   ; step rate
        sta tbuf+4                   ; heads - 1
        lda m_tot_hi-1,x
        sta tbuf+2                   ; sectors per track, MSB first
        lda m_tot_lo-1,x
        sta tbuf+3
        lda m_flags-1,x
        and #$06
        lsr
        tay
        lda ss_hi,y
        sta tbuf+6                   ; bytes per sector, MSB first
        lda #0
        sta tbuf+7
        cpy #0
        bne pc_dd
        lda #$80
        sta tbuf+7
pc_dd   lda #0
        cpy #0
        beq pc_fm
        lda #$04                     ; MFM
pc_fm   sta tbuf+5
        lda m_tot_hi-1,x             ; floppy geometries
        cmp #>720
        bne pc_ed
        lda m_tot_lo-1,x
        cmp #<720
        bne pc_done
        lda #18                      ; 720: 40 x 18
        bne pc_flp
pc_ed   cmp #>1040
        bne pc_done
        lda m_tot_lo-1,x
        cmp #<1040
        bne pc_done
        tya
        bne pc_done                  ; 1040 x 128 only
        lda #$04                     ; ED: 40 x 26, MFM
        sta tbuf+5
        lda #26
pc_flp  sta tbuf+3
        lda #0
        sta tbuf+2
        lda #40
        sta tbuf
pc_done lda #$FF
        sta tbuf+8
        lda #0
        sta tbuf+9
        sta tbuf+10
        sta tbuf+11
        lda #12

; reply_tbuf -- A = byte count (must equal dbyt): tbuf -> caller
reply_tbuf
        cmp sv_dcb+8
        jne err_den
        ldx sv_dcb+9
        jne err_den
        sta zcnt
        stx zcnt+1
        tax                          ; tbuf[0..n-1] -> iobuf
        dex
rt_lp   lda tbuf,x
        jsr iob_put_x
        dex
        bpl rt_lp
        jsr inval_data
        lda iobv
        sta zsrc
        lda iobv+1
        sta zsrc+1
        lda sv_dcb+4
        sta zdst
        lda sv_dcb+5
        sta zdst+1
        jsr copy
        jmp ok

; iob_put_x -- iobuf[X] = A
iob_put_x
        pha
        lda iobv
        sta ziob
        lda iobv+1
        sta ziob+1
        txa
        tay
        pla
        sta (ziob),y
        rts

;--------------------------------------------------------------
; 'R' / 'W' / 'P'
;--------------------------------------------------------------
cmd_write
        ldx unit
        lda m_flags-1,x
        lsr
        bcc cmd_rw
        lda #ST_WP
        jmp finish
cmd_read
cmd_rw  jsr xlat                     ; off, len; C=1: sector out of range
        jcs err_nak
        lda len                      ; the caller must ask for the real size
        cmp sv_dcb+8
        jne err_den
        lda len+1
        cmp sv_dcb+9
        jne err_den
        lda sv_dcb+4                 ; caller buffer cursor
        sta cptr
        lda sv_dcb+5
        sta cptr+1

rw_loop jsr blockof                  ; blk = off / hs, wofs = off % hs
        lda hsz                      ; chunk = min(len, hs - wofs)
        sec
        sbc wofs
        sta chunk
        lda hsz+1
        sbc wofs+1
        sta chunk+1
        lda len+1
        cmp chunk+1
        bcc rw_len
        bne rw_chk
        lda len
        cmp chunk
        bcs rw_chk
rw_len  lda len
        sta chunk
        lda len+1
        sta chunk+1
rw_chk  jsr datasec                  ; dsec = host sector of blk
        jcs rw_err
        jsr load_data                ; iobuf = host sector dsec
        jmi rw_errst

        lda iobv                     ; iobuf + wofs
        clc
        adc wofs
        sta ztmp
        lda iobv+1
        adc wofs+1
        sta ztmp+1
        lda chunk
        sta zcnt
        lda chunk+1
        sta zcnt+1
        lda sv_dcb+2
        cmp #'R'
        bne rw_put
        lda ztmp                     ; read: iobuf -> caller
        sta zsrc
        lda ztmp+1
        sta zsrc+1
        lda cptr
        sta zdst
        lda cptr+1
        sta zdst+1
        jsr copy
rw_next lda cptr                     ; advance: off += chunk, cptr += chunk
        clc
        adc chunk
        sta cptr
        lda cptr+1
        adc chunk+1
        sta cptr+1
        lda off
        clc
        adc chunk
        sta off
        lda off+1
        adc chunk+1
        sta off+1
        bcc rw_noc
        inc off+2
rw_noc  lda len
        sec
        sbc chunk
        sta len
        lda len+1
        sbc chunk+1
        sta len+1
        ora len
        jne rw_loop
        jmp ok

rw_put  lda cptr                     ; write: caller -> iobuf -> host
        sta zsrc
        lda cptr+1
        sta zsrc+1
        lda ztmp
        sta zdst
        lda ztmp+1
        sta zdst+1
        jsr copy
        lda #'W'
        jsr host_io
        bpl rw_next
        bmi rw_errst
rw_err  lda #ST_NAK
rw_errst
        jsr inval_data
        jmp finish

;--------------------------------------------------------------
; xlat -- sector daux1/2 of unit -> off (24-bit file offset), len.
;   C=1 when the sector is 0 or past the image.
;--------------------------------------------------------------
xlat    ldx unit
        lda sv_dcb+10
        ora sv_dcb+11
        jeq xl_bad
        lda m_tot_lo-1,x             ; sec <= tot
        cmp sv_dcb+10
        lda m_tot_hi-1,x
        sbc sv_dcb+11
        jcc xl_bad
        lda sv_dcb+10                ; ztmp = sec - 1
        sec
        sbc #1
        sta ztmp
        lda sv_dcb+11
        sbc #0
        sta ztmp+1
        lda #0
        sta ztmp+2
        lda m_flags-1,x
        and #$06
        beq xl_128
        cmp #$04
        beq xl_512
        lda m_flags-1,x              ; 256: broken image = all sectors 256 B
        and #$08
        bne xl_256
        lda sv_dcb+11                ; sectors 1-3 are 128 B
        bne xl_dd
        lda sv_dcb+10
        cmp #4
        bcc xl_128
xl_dd   ldy ztmp+1                   ; (sec-4)*256 + 384, from ztmp = sec-1
        lda ztmp
        sec
        sbc #3
        sta ztmp+1
        tya
        sbc #0
        sta ztmp+2
        lda #$80
        sta ztmp
        inc ztmp+1                   ; + $180
        bne xl_dd1
        inc ztmp+2
xl_dd1  lda #<256
        ldy #>256
        jmp xl_set
xl_256  lda ztmp+1                   ; (sec-1)*256
        sta ztmp+2
        lda ztmp
        sta ztmp+1
        lda #0
        sta ztmp
        lda #<256
        ldy #>256
        jmp xl_set
xl_512  lda ztmp+1                   ; (sec-1)*512
        sta ztmp+2
        lda ztmp
        sta ztmp+1
        lda #0
        sta ztmp
        asl ztmp+1
        rol ztmp+2
        lda #<512
        ldy #>512
        jmp xl_set
xl_128  lda ztmp+1                   ; (sec-1)*128 = (sec-1) << 7
        lsr
        sta ztmp+2
        lda ztmp
        ror
        sta ztmp+1
        lda #0
        ror
        sta ztmp
        lda #<128
        ldy #>128
xl_set  sta len
        sty len+1
        lda ztmp                     ; + 16 (ATR header)
        clc
        adc #16
        sta off
        lda ztmp+1
        adc #0
        sta off+1
        lda ztmp+2
        adc #0
        sta off+2
        clc
        rts
xl_bad  sec
        rts

;--------------------------------------------------------------
; blockof -- blk = off >> hsh (16-bit), wofs = off & (hs-1)
;--------------------------------------------------------------
blockof ldx unit
        ldy m_hss-1,x                ; 0 = 128, 1 = 256, 2 = 512
        lda ss_lo,y
        sta hsz
        lda ss_hi,y
        sta hsz+1
        tya
        beq bo_128
        cmp #1
        beq bo_256
        lda off+2                    ; 512
        lsr
        sta blk+1
        lda off+1
        ror
        sta blk
        lda off+1
        and #1
        sta wofs+1
        lda off
        sta wofs
        rts
bo_256  lda off+1
        sta blk
        lda off+2
        sta blk+1
        lda #0
        sta wofs+1
        lda off
        sta wofs
        rts
bo_128  lda off
        asl
        lda off+1
        rol
        sta blk
        lda off+2
        rol
        sta blk+1
        lda off
        and #$7F
        sta wofs
        lda #0
        sta wofs+1
        rts

;--------------------------------------------------------------
; datasec -- dsec = data sector of host block blk (walks the sector
;   maps, remembering the last map reached). C=1: hole / past the file.
;--------------------------------------------------------------
datasec ldx unit
        lda m_hss-1,x                ; entries per map sector
        tay
        lda epm_t,y
        sta ztmp+2
        cmp ds_epm                   ; same divisor as last time and blk the
        bne ds_full                  ;   same or the next one (sequential I/O):
        lda blk                      ;   kq, e follow without the division
        sec
        sbc ds_lb
        tay
        lda blk+1
        sbc ds_lb+1
        bne ds_full
        tya
        beq ds_same
        cmp #1
        bne ds_full
        ldy ds_ent                   ; e + 1, into the next map sector at epm
        iny
        cpy ztmp+2
        bne ds_e
        ldy #0
        inc ds_kq
        bne ds_e
        inc ds_kq+1
ds_e    sty ds_ent
        lda blk
        sta ds_lb
        lda blk+1
        sta ds_lb+1
ds_same lda ds_ent
        sta ent
        lda ds_kq
        sta kq
        lda ds_kq+1
        sta kq+1
        jmp ds_have
ds_full lda blk                      ; kq = blk / epm, e = blk % epm
        sta ztmp
        lda blk+1
        sta ztmp+1
        lda #0
        ldy #16
ds_div  asl ztmp
        rol ztmp+1
        rol
        bcs ds_sub                   ; (A < 512: a carry out means >= epm)
        cmp ztmp+2
        bcc ds_nos
ds_sub  sbc ztmp+2
        inc ztmp
ds_nos  dey
        bne ds_div
        sta ent                      ; e
        sta ds_ent
        lda ztmp
        sta kq
        sta ds_kq
        lda ztmp+1
        sta kq+1
        sta ds_kq+1
        lda ztmp+2
        sta ds_epm
        lda blk
        sta ds_lb
        lda blk+1
        sta ds_lb+1
ds_have

        lda mc_unit                  ; resume from the cached map?
        cmp unit
        bne ds_first
        lda kq                       ; kq >= mc_k
        cmp mc_k
        lda kq+1
        sbc mc_k+1
        bcs ds_walk
ds_first
        lda unit
        sta mc_unit
        lda #0
        sta mc_k
        sta mc_k+1
        lda m_smap_lo-1,x
        sta mc_s
        lda m_smap_hi-1,x
        sta mc_s+1

ds_walk jsr load_map                 ; mapbuf = map sector mc_s
        bmi ds_fail
        lda mc_k
        cmp kq
        bne ds_next
        lda mc_k+1
        cmp kq+1
        beq ds_here
ds_next lda mapbuf                   ; follow the "next" link
        ora mapbuf+1
        beq ds_fail
        lda mapbuf
        sta mc_s
        lda mapbuf+1
        sta mc_s+1
        inc mc_k
        bne ds_walk
        inc mc_k+1
        bne ds_walk

ds_here lda ent                      ; dsec = mapbuf[4 + 2e]
        asl
        sta ztmp
        lda #0
        rol
        sta ztmp+1
        lda mapbv
        clc
        adc ztmp
        sta zptr
        lda mapbv+1
        adc ztmp+1
        sta zptr+1
        ldy #4
        lda (zptr),y
        sta dsec
        iny
        lda (zptr),y
        sta dsec+1
        ora dsec
        beq ds_fail
        clc
        rts
ds_fail lda #$FF
        sta mc_unit
        sec
        rts

;--------------------------------------------------------------
; load_map -- mapbuf = host sector mc_s of the unit's host drive.
;   N=1: error (A = status).
;--------------------------------------------------------------
load_map
        ldx unit
        lda m_host-1,x
        cmp mb_host
        bne lm_rd
        lda mc_s
        cmp mb_sec
        bne lm_rd
        lda mc_s+1
        cmp mb_sec+1
        bne lm_rd
        lda #ST_OK
        rts
lm_rd   lda m_host-1,x
        sta hunit
        lda mc_s
        sta hsec
        lda mc_s+1
        sta hsec+1
        jsr inval_data               ; iobuf is about to hold a map
        lda #'R'
        jsr host_io
        bmi lm_err
        lda iobv                     ; iobuf -> mapbuf (both visible here)
        sta zsrc
        lda iobv+1
        sta zsrc+1
        lda mapbv
        sta zdst
        lda mapbv+1
        sta zdst+1
        ldy #0
        ldx #2
lm_cp   lda (zsrc),y
        sta (zdst),y
        iny
        bne lm_cp
        inc zsrc+1
        inc zdst+1
        dex
        bne lm_cp
        ldx unit
        lda m_host-1,x
        sta mb_host
        lda mc_s
        sta mb_sec
        lda mc_s+1
        sta mb_sec+1
        lda #ST_OK
        rts
lm_err  ldx #$FF
        stx mb_host
        tax                          ; N = error
        rts

;--------------------------------------------------------------
; load_data -- iobuf = host sector dsec. N=1: error (A = status).
;--------------------------------------------------------------
load_data
        ldx unit
        lda m_host-1,x
        sta hunit
        cmp dc_host
        bne ld_rd
        lda dsec
        sta hsec
        cmp dc_sec
        bne ld_rd2
        lda dsec+1
        sta hsec+1
        cmp dc_sec+1
        bne ld_rd2
        lda #ST_OK
        rts
ld_rd   lda dsec
        sta hsec
ld_rd2  lda dsec+1
        sta hsec+1
        jsr inval_data
        lda #'R'
        jsr host_io
        bmi ld_err
        lda hunit
        sta dc_host
        lda hsec
        sta dc_sec
        lda hsec+1
        sta dc_sec+1
        lda #ST_OK
ld_err  rts

inval_data
        lda #$FF
        sta dc_host
        rts

;--------------------------------------------------------------
; host_io -- A = 'R'/'W'/'N': one host sector hsec of hunit <-> iobuf
;   ('N': 12 B PERCOM into iobuf). Calls the drivers behind ours in the
;   sio_vector chain directly (no re-entry into LSIO). N=1: error.
;--------------------------------------------------------------
host_io sta dcmnd
        lda #$31
        sta ddevic
        lda hunit
        sta dunit
        lda iobv
        sta dbufa
        lda iobv+1
        sta dbufa+1
        lda #7
        sta dtimlo
        lda #0
        sta dunuse
        sta memreix                  ; iobuf is main RAM
        lda hsec
        sta daux1
        lda hsec+1
        sta daux2
        ldx unit
        lda m_hss-1,x
        tay
        lda ss_hi,y
        sta dbyt+1
        lda ss_lo,y
        sta dbyt
        lda #$40
        ldy dcmnd
        cpy #'W'
        bne hio_dir
        lda #$80
hio_dir cpy #'N'
        bne hio_go
        ldy #12
        sty dbyt
        ldy #0
        sty dbyt+1
hio_go  sta dstats

        ldx our_slot                 ; next drivers in the chain
hio_nx  inx
        inx
        cpx #8
        bcs hio_none
        lda sio_vector+1,x
        beq hio_nx
        sta hio_jmp+2
        lda sio_vector,x
        sta hio_jmp+1
        stx hio_x
        jsr hio_jmp
        ldx hio_x
        bcs hio_nx
        tay                          ; N from the status
        rts
hio_none
        lda #138                     ; device timeout
        rts
hio_jmp jmp $FFFF
hio_x   dta 0

;--------------------------------------------------------------
; mount_cmd -- SIO $20 'A': write = mount, read = unmount/info
;--------------------------------------------------------------
mount_cmd
        lda sv_dcb+10                ; aux1 = target drive 1..15
        beq mc_bad
        cmp #NMOUNT+1
        bcs mc_bad
        sta unit
        lda sv_dcb+3
        and #$C0
        cmp #$80
        jeq do_mount
        cmp #$40
        jeq do_umount
mc_bad  jmp err_nak

;--- unmount: reply flags + path, forget the unit
do_umount
        jsr inval_all
        ldx #0                       ; iobuf[0..127] = 0
        lda #0
um_clr  jsr iob_put_x
        inx
        bpl um_clr
        ldx unit
        lda m_flags-1,x
        bpl um_reply                 ; not mounted: path = "" (byte 1 = 0)
        and #1
        ldx #0
        jsr iob_put_x                ; [0] = read-only flag
        jsr path_ptr                 ; zptr -> m_path entry
        ldy #0                       ; iobuf[1..] = path up to EOL
um_cp   lda (zptr),y
        iny
        sty ztmp
        ldx ztmp
        jsr iob_put_x                ; (keeps A; Y = X on return)
        cmp #$9B
        beq um_off
        cpy #PATHLEN
        bcc um_cp
um_off  ldx unit
        lda #0
        sta m_flags-1,x
um_reply
        lda #128
        sta zcnt
        lda #0
        sta zcnt+1
        lda iobv
        sta zsrc
        lda iobv+1
        sta zsrc+1
        lda sv_dcb+4
        sta zdst
        lda sv_dcb+5
        sta zdst+1
        jsr copy
        jmp ok

;--- mount: parse the ATRM packet
do_mount
        ldx unit                     ; the old image on this unit is gone
        lda #0
        sta m_flags-1,x
        jsr inval_all
        lda #128                     ; caller packet -> iobuf
        sta zcnt
        lda #0
        sta zcnt+1
        lda sv_dcb+4
        sta zsrc
        lda sv_dcb+5
        sta zsrc+1
        lda iobv
        sta zdst
        sta zptr
        lda iobv+1
        sta zdst+1
        sta zptr+1
        jsr copy

        ldy #0                       ; [0] host device: DSK unit 1..15
        lda (zptr),y
        tax
        and #$F0
        jne err_nak
        txa
        jeq err_nak
        sta n_host
        iny                          ; [1] DEsta: bit 0 = mount read-only
        lda (zptr),y
        and #1
        sta n_flags
        iny                          ; [2,3] first sector map
        lda (zptr),y
        sta n_smap
        iny
        lda (zptr),y
        sta n_smap+1
        ora n_smap
        jeq err_nak
        ldy #6                       ; [6,7,10] size in paragraphs
        lda (zptr),y
        sta ztmp
        iny
        lda (zptr),y
        sta ztmp+1
        ldy #10
        lda (zptr),y
        sta ztmp+2
        lda #0
        sta ztmp+3
        ldx #4                       ; bytes = paragraphs * 16
dm_x16  asl ztmp
        rol ztmp+1
        rol ztmp+2
        rol ztmp+3
        dex
        bne dm_x16
        lda ztmp+3                   ; < 16 MB
        jne err_nak
        ldy #8                       ; [8,9] sector size
        lda (zptr),y
        tax
        iny
        lda (zptr),y
        cpx #$80
        bne dm_n128
        cmp #0
        jne err_nak
        ldx #7                       ; 128: tot = bytes >> 7
        jmp dm_tot
dm_n128 cpx #0
        jne err_nak
        cmp #1
        beq dm_256
        cmp #2
        jne err_nak
        lda n_flags                  ; 512: tot = bytes >> 9
        ora #$04
        sta n_flags
        ldx #9
        jmp dm_tot
dm_256  lda n_flags
        ora #$02
        sta n_flags
        lda ztmp                     ; DD: (bytes - 384) >> 8 + 3 when the
        cmp #$80                     ;   first three sectors are short
        bne dm_broken
        lda ztmp+1
        sec
        sbc #1
        sta ztmp+1
        lda ztmp+2
        sbc #0
        sta ztmp+2
        lda ztmp+1
        clc
        adc #3
        sta n_tot
        lda ztmp+2
        adc #0
        sta n_tot+1
        jcs err_nak
        jmp dm_host
dm_broken
        lda n_flags                  ; all sectors 256 B
        ora #$08
        sta n_flags
        ldx #8
dm_tot  lsr ztmp+2                   ; tot = bytes >> X (17 bits max -> check)
        ror ztmp+1
        ror ztmp
        dex
        bne dm_tot
        lda ztmp+2
        jne err_nak
        lda ztmp
        sta n_tot
        lda ztmp+1
        sta n_tot+1
dm_host lda n_tot
        ora n_tot+1
        jeq err_nak

        ldy #19                      ; [19] ATR flags: bit 0 = write protected
        lda (zptr),y
        and #1
        ora n_flags
        sta n_flags

        ldy #20                      ; [20..] "D:>PATH>FILE.ATR",EOL
        ldx #0
dm_path lda (zptr),y
        sta n_path,x
        cmp #$9B
        beq dm_pend
        iny
        inx
        cpx #PATHLEN-1
        bcc dm_path
        lda #$9B
        sta n_path,x

dm_pend lda n_host                   ; host sector size from its PERCOM
        sta hunit
        ldx unit
        lda #2                       ; (host_io reads m_hss for 'N' size;
        sta m_hss-1,x                ;  the 'N' length overrides it)
        lda #'N'
        jsr host_io
        jmi finish
        ldy #6
        lda (zptr),y                 ; zptr still -> iobuf
        tax
        iny
        lda (zptr),y
        cmp #$80
        bne dm_h1
        cpx #0
        jne err_nak
        lda #0
        beq dm_hset
dm_h1   cmp #0                       ; 256 / 512: code = MSB (1 / 2)
        jne err_nak
        txa
        cmp #1
        beq dm_hset
        cmp #2
        jne err_nak
dm_hset ldx unit
        sta m_hss-1,x

        lda n_host                   ; commit the unit
        sta m_host-1,x
        lda n_smap
        sta m_smap_lo-1,x
        lda n_smap+1
        sta m_smap_hi-1,x
        lda n_tot
        sta m_tot_lo-1,x
        lda n_tot+1
        sta m_tot_hi-1,x
        jsr path_ptr
        ldy #0
dm_pcp  lda n_path,y
        sta (zptr),y
        iny
        cpy #PATHLEN
        bcc dm_pcp
        lda n_flags
        ora #$80
        ldx unit
        sta m_flags-1,x
        jsr inval_all
        jmp ok

; path_ptr -- zptr = m_path + (unit-1)*64
path_ptr
        lda unit
        sec
        sbc #1
        lsr
        lsr                          ; A = (unit-1)/4, C = bit 1
        sta zptr+1
        lda unit
        sec
        sbc #1
        and #3
        lsr
        ror
        ror                          ; (unit-1 & 3) << 6
        sta zptr
        lda pathv
        clc
        adc zptr
        sta zptr
        lda pathv+1
        adc zptr+1
        sta zptr+1
        rts

inval_all
        lda #$FF
        sta ds_epm
        sta mc_unit
        sta mb_host
        sta dc_host
        rts

        icl 'abcmd.asm'

; tables
ss_lo   dta $80,$00,$00              ; sector size by code 0/1/2
ss_hi   dta $00,$01,$02
epm_t   dta 62,126,254               ; map entries per host sector
mapbv   dta a(mapbuf)
pathv   dta a(m_path)

; variables (initialised: the "not cached" markers must start $FF)
mc_unit dta $FF
ds_epm  dta $FF                      ; datasec's last divisor ($FF: none)
ds_lb   dta a(0)                     ;   ... its blk, kq and e
ds_kq   dta a(0)
ds_ent  dta 0
mb_host dta $FF
dc_host dta $FF
m_flags :NSLOT dta 0

; BSS
bss_beg equ *
unit    equ bss_beg
status  equ unit+1
sv_dcb  equ status+1                 ; 16
off     equ sv_dcb+16                ; 3
len     equ off+3                    ; 2
cptr    equ len+2                    ; 2
blk     equ cptr+2                   ; 2
wofs    equ blk+2                    ; 2
chunk   equ wofs+2                   ; 2
hsz     equ chunk+2                  ; 2
kq      equ hsz+2                    ; 2
ent     equ kq+2                     ; 1
dsec    equ ent+1                    ; 2
mc_k    equ dsec+2                   ; 2
mc_s    equ mc_k+2                   ; 2
mb_sec  equ mc_s+2                   ; 2
dc_sec  equ mb_sec+2                 ; 2
hunit   equ dc_sec+2                 ; 1
hsec    equ hunit+1                  ; 2
tbuf    equ hsec+2                   ; 12
n_host  equ tbuf+12                  ; 1
n_flags equ n_host+1                 ; 1
n_smap  equ n_flags+1                ; 2
n_tot   equ n_smap+2                 ; 2
n_path  equ n_tot+2                  ; 64
m_host  equ n_path+PATHLEN           ; NSLOT each
m_hss   equ m_host+NSLOT
m_smap_lo equ m_hss+NSLOT
m_smap_hi equ m_smap_lo+NSLOT
m_tot_lo equ m_smap_hi+NSLOT
m_tot_hi equ m_tot_lo+NSLOT
mapbuf  equ m_tot_hi+NSLOT           ; 512
m_path  equ mapbuf+512               ; 15 x 64
; ATRBOOT
ab_de   equ m_path+NMOUNT*PATHLEN    ; 5: first map, length
ab_dev  equ ab_de+5
nblk    equ ab_dev+1                 ; 2
dsec0   equ nblk+2                   ; 2
sdhc    equ dsec0+2
lba     equ sdhc+1                   ; 4, little-endian
base    equ lba+4                    ; 4, little-endian
sa0     equ base+4                   ; 4: SD argument, big-endian
rd_cmp  equ sa0+4
rd_bad  equ rd_cmp+1
ncand   equ rd_bad+1
cd_n    equ ncand+1
p_new   equ cd_n+1                   ; 5 = R_SSZ..R_FLAGS
ab_sp   equ p_new+5                  ; stack pointer at @CHLEBA entry
cbuf    equ ab_sp+1                  ; 31 x 4
stage   equ cbuf+124                 ; 128
bss_end equ stage+128

        blk empty bss_end-bss_beg extended

        blk update address
        blk update symbols
        blk update new entry 'CHLEBA'
        blk update new ab_ent '@CHLEBA'

        end
