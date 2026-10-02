;==============================================================
; CHLEBA.COM -- Chleba 1.3, taky srandovny loader ATR disketiek (w1k 2026)
;
;   CHLEBA file.ATR   (SpartaDOS X on SIDE3)
;
; Boots an ATR file lying on a SIDE3 APT (SpartaDOS, 512 B sector)
; partition, with any OS in ROM, at SD speed:
;   1. the file's blocks are found through its SpartaDOS sector maps (read
;      through the SDX drivers), the partition start from the APT, VERIFIED
;      by raw SD reads; the SD argument of every block goes to a table at
;      card RAM $000000;
;   2. the D1: handler goes to card RAM bank HND_BANK (run in SIDE3 window
;      A, $8000), the VSEROR stub to the CCTL aperture ($D500), the boot
;      step to $0480; ab_go drops SDX (no cold start, the OS ROM stays in),
;      puts the OS's vectors back, hooks VSEROR and boots D1:.
; A plain program (nothing stays resident): it loads at PROG ($8000), out of
; the banked $4000-$7FFF window; the three run-elsewhere images (.local
; blocks, "org run,load") follow the code, the variables follow them.
;==============================================================


; SIDE3 card RAM layout (21-bit DMA addresses)
                                     ; $000000: 4 B per 512 B file block =
                                     ;   its SD command argument, big-endian
SCR_BANK  equ $FA                    ; $1F4000 = 8 KB bank $FA: scratch block
                                     ;   (512 B, a one-block cache), window B
HND_BANK  equ $F8                    ; 8 KB bank $F8 = $1F0000: the handler,
HND_HI    equ $1F                    ;   run in window A ($8000)
APER_HI   equ $1F                    ; CCTL aperture $D500-$D57F = $1FF500
APER_MID  equ $F5

; the stub in the aperture, the handler in window A
STUB_IRQ  equ $D500                  ; VSEROR target
STUB_OLD  equ $D535                  ; operand of JMP: the OS's VSEROR
STUB_XCH  equ $D537                  ; copy cnt bytes (za),y -> (zb),y, program's map
STUB_MC1  equ $D50D                  ; 3 operands: VBXE MEMAC_CONTROL address
STUB_MC2  equ $D549
STUB_MC3  equ $D559
STUB_DATA equ $D578                  ; 8 B data window = card RAM $1FF578
DATA_LO   equ $78
DATA_N    equ 8
HND_ORG   equ $8000                  ; JMP entry
H_SSZ     equ HND_ORG+3              ; 0 = 128 B, 1 = 256 B (DD), 2 = 512 B
H_BRK     equ HND_ORG+4              ; 1 = 256 B sectors 1-3 too ("broken" DD)
H_TOT     equ HND_ORG+5              ; 2 B: sector count
H_SCAN    equ HND_ORG+7              ; JMP hscan: the stub's stack scan
H_816     equ HND_ORG+10             ; $FF: the CPU is a 65816 (copies with MVN)
BOOT_ORG  equ $0480                  ; bootc.asm
BOOT_SSZ  equ $0584                  ; its copy of the sector size code
BOOT_RVEC equ $0585                  ; its rvec: RAM vectors from the OS ROM

; zero page shared by stub and handler (SIO's own, abandoned for D1:)
zbuf      equ $32                    ; caller buffer
cnt       equ $35                    ; bytes for xch
za        equ $38                    ; xch source
zb        equ $3A                    ; xch destination
unw       equ $3D                    ; S for the return to the SIOV caller
zr        equ $3E                    ; stub's stack-scan pointer

; hardware
PORTB     equ $D301
NMIEN     equ $D40E
TRIG3     equ $D013
S3_MODE   equ $D5FC                  ; bits 1-0: register set (0 primary, 1 DMA, 2 emulation)
S3_APER   equ $D5FD                  ; write bit 6 = CCTL RAM aperture
S3_SD     equ $D5F3                  ; primary set: SD control
S3_SPI    equ $D5F4                  ; SPI data
S3_CRC    equ $D5F5                  ; CRC7
S3_BANKA  equ $D5F6                  ; RAM bank, window A ($8000)
S3_BANKB  equ $D5F7                  ; RAM bank, window B ($A000)
S3_WIN    equ $D5FA                  ; window enables
S3_MISC   equ $D5FB                  ; bit 0 RAM A read-only, bit 2 aperture write-protect

; OS
CDEVIC    equ $023A                  ; command frame device byte (SIO)
DDEVIC    equ $0300
DUNIT     equ $0301
DCOMND    equ $0302
DSTATS    equ $0303
DBUFA     equ $0304
DBYT      equ $0308
DAUX1     equ $030A
DAUX2     equ $030B
DBFX1     equ $030E
DSKINV    equ $E453
CIOV      equ $E456
SIOV      equ $E459
INTINV    equ $E46B
VSEROR    equ $020C

PROG      equ $8000

V_setme   equ $07F1
V_popme   equ $07F4
sio_vector equ $0718
memreix   equ $0787
jfsymbol  equ $07EB
MEMTOP    equ $02E5
MEMLO     equ $02E7

dcmnd     equ $0302
dtimlo    equ $0306
dunuse    equ $0307

; zero page: $30-$3F belong to the SIO driver ($36/$37 must survive)
zsrc      equ $30                    ; copy source
zdst      equ $32                    ; copy destination
zcnt      equ $34                    ; copy count (16-bit)
zptr      equ $38                    ; general pointer
ztmp      equ $3A                    ; 4 B scratch ($3A-$3D)

NMOUNT    equ 15                     ; SDX drives DSK1..DSK15
NSLOT     equ 1                      ; one slot: the booted file
BOOTU     equ 1

ST_OK     equ 1

device    equ $0761
scan      equ $0779
dentry    equ $0789                  ; +1 first sector map, +3 length (3 B)

        opt h+
        org PROG

;--------------------------------------------------------------
; start -- the SDX library entries by name (jfsymbol: a plain program has
;   no symbol fix-ups), the memory checks, then the command proper
;--------------------------------------------------------------
start   lda #<n_prf
        ldx #>n_prf
        jsr jfsymbol
        bne st_p
        rts                          ; (no PRINTF: nothing to say it with)
st_p    sta printf+1
        stx printf+2
        jsr printf
        dta $9b,c'Chleba 1.3 - Taky srandovny loader ATR disketiek',$9b
        dta c'===============',$9b
        dta c'w1k 2026',$9b,$9b,0
        lda #<n_gpr
        ldx #>n_gpr
        jsr jfsymbol
        beq st_sym
        sta u_getpar+1
        stx u_getpar+2
        lda #<n_ffi
        ldx #>n_ffi
        jsr jfsymbol
        beq st_sym
        sta ffirst+1
        stx ffirst+2
        lda #<n_fcl
        ldx #>n_fcl
        jsr jfsymbol
        beq st_sym
        sta fclose+1
        stx fclose+2
        lda MEMLO+1                  ; the program lies at PROG..bss_end:
        cmp #>PROG                   ;   MEMLO below, MEMTOP above
        bcs st_mem
        lda MEMTOP
        cmp #<bss_end
        lda MEMTOP+1
        sbc #>bss_end
        bcc st_mem
        jmp ab_main
st_sym  jsr printf
        dta c'CHLEBA: SDX library not found',$9b,0
        rts
st_mem  jsr printf
        dta c'CHLEBA: no room at $8000',$9b,0
        rts

printf  jmp $FFFF                    ; the library entries, patched by start
u_getpar jmp $FFFF
ffirst  jmp $FFFF
fclose  jmp $FFFF
n_prf   dta c'PRINTF  '
n_gpr   dta c'U_GETPAR'
n_ffi   dta c'FFIRST  '
n_fcl   dta c'FCLOSE  '

;--------------------------------------------------------------
; ab_go -- the last step: leave SDX without a cold start -- OS ROM in, the
;   OS's own vectors and handlers back, VSEROR to the stub in the SIDE3
;   aperture -- then boot D1: (bootc at $0480). The handler (window A)
;   serves every SIOV/DSKINV call for D1:, ROM in or not.
;--------------------------------------------------------------
ab_go   sei
        cld
        lda #0
        sta NMIEN
        ldx #0                       ; boot step -> $0480
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


;==============================================================
; the command: CHLEBA file.ATR
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
        php                          ; the CPU into the handler image: $FF on a
        sei                          ;   65816 (its copy uses MVN). No IRQ
        ldx #0                       ;   while D is set.
        lda #$99
        clc
        sed
        adc #$01
        cld
        bne ab_c8                    ; NMOS 6502: Z from the binary sum
        lda #0
        dta $C2,$02                  ; rep #$02: clears Z on a 65816, a NOP on a 65C02
        beq ab_c8
        dex
ab_c8   plp
        stx ab_hnd+H_816-HND_ORG
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


;==============================================================
; the file's blocks through its SpartaDOS sector maps
;==============================================================
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

        ldx #$FE                     ; every driver in the chain, from slot 0
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

inval_all
        lda #$FF
        sta ds_epm
        sta mc_unit
        sta mb_host
        sta dc_host
        rts

; tables
ss_lo   dta $80,$00,$00              ; sector size by code 0/1/2
ss_hi   dta $00,$01,$02
epm_t   dta 62,126,254               ; map entries per host sector
mapbv   dta a(mapbuf)
iobv    dta a(iobuf)

; variables (initialised: the "not cached" markers must start $FF)
mc_unit dta $FF
ds_epm  dta $FF                      ; datasec's last divisor ($FF: none)
ds_lb   dta a(0)                     ;   ... its blk, kq and e
ds_kq   dta a(0)
ds_ent  dta 0
mb_host dta $FF
dc_host dta $FF

;==============================================================
; the images: assembled for where they run, stored here
;==============================================================
ab_hnd                               ; D1: handler (SIDE3 window A, $8000)
        .local hnd
        org HND_ORG,ab_hnd
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

o0      equ $30                      ; 24-bit file offset
o1      equ $31
o2      equ $34
zwin    equ $3D                      ; window enables the stub's hon restores
mc      equ $3C                      ; the program's MEMAC_CONTROL (stub)
WINB    equ $A000

        jmp hnd
p_ssz   dta 0                        ; set by CHLEBA
p_brk   dta 0
p_tot   dta a(0)
        jmp hscan                    ; the stub: find the SIOV caller's frame
p_816   dta 0                        ; set by CHLEBA: $FF on a 65816
        ert p_ssz<>H_SSZ
        ert p_tot<>H_TOT
        ert p_816-3<>H_SCAN
        ert p_816<>H_816

hnd     cld
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
cp16    lda p_816
        bne cp_mv
        ldy #0
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

; cp_mv -- the same copy on a 65816: one MVN. The handler runs from the
;   cartridge window, so on an accelerator every code byte it fetches is a
;   bus cycle: MVN fetches 3 a byte moved, the 6502 loop 5. Native mode only
;   for the move (IRQs and NMIs are off here), 8-bit emulation again after.
cp_mv   lda cnt
        sta cp_n
        stx cp_n+1
        opt c+
        clc
        xce
        rep #$30
        .LONGA ON
        .LONGI ON
        lda cp_n
        dec @                        ; MVN moves C+1 bytes
        ldx za
        ldy zb
        mvn 0,0
        sep #$30
        .LONGA OFF
        .LONGI OFF
        sec
        xce
        opt c-
        rts
cp_n    dta a(0)

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
        lda #$51                     ; CMD17 READ_SINGLE_BLOCK
        jsr sd_cmd
        bcs bl_f
        bne bl_f
        lda #$39                     ; free-run: each read clocks a byte
        sta S3_SD
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
        tsx
        stx sc_s
        lda sc_d                     ; first the depth pass 1 found last time
        beq sc_go                    ;   (one SIOV frame lives at a time: a
        clc                          ;   JSR $E459/$E453 frame there is it)
        adc sc_s
        bcs sc_go
        tax
        jsr sc_chk
        bcs sc_hit
sc_go   ldx sc_s                     ; the whole stack, from the stub's frames:
        inx                          ;   skip our own return address (the
        inx                          ;   loop's inx reads the stub's first byte)
sc_lp   inx
        beq sc_end
        jsr sc_chk
        bcc sc_lp
        lda sc_m                     ; pass 1: remember the depth
        bne sc_hit
        txa
        sec
        sbc sc_s
        sta sc_d
sc_hit  dex                          ; S: the next RTS pulls this frame
        clc
        rts
sc_end  lda sc_m
        bne sc_no
        inc sc_m
        bne sc_go
sc_no   sec
        rts

; sc_chk -- C=1 when the return address at $0100,X (P) follows a JSR at
;   P-2 that pass sc_m accepts. Keeps X.
sc_chk  lda $0100,x                  ; za = P - 2
        sec
        sbc #2
        sta za
        lda $0101,x
        sbc #0
        sta za+1
        sta sc_h                     ; (pass 2 tests the caller's page)
        and #$F8
        cmp #$D0                     ; I/O: never read
        beq sc_n
        eor #$80                     ; $80-$9F (under window A) -> $00-$1F
        cmp #$20
        bcs sc_rd
        jsr STUB_XCH                 ; window A hides it: the program's bytes
        lda #<STUB_DATA              ;   through xch into the data window,
        sta za                       ;   read there (keeps X)
        lda #>STUB_DATA
        sta za+1
sc_rd   ldy #0                       ; the JSR, read where it lies
        lda (za),y
        cmp #$20                     ; JSR abs: most candidates end here
        bne sc_n
        lda sc_m
        bne sc_p2
        ldy #2                       ; pass 1: its target $E459 / $E453
        lda (za),y
        cmp #>SIOV
        bne sc_n
        dey
        lda (za),y
        cmp #<SIOV
        beq sc_y
        cmp #<DSKINV
        beq sc_y
sc_n    clc
        rts
sc_p2   lda sc_h                     ; pass 2: called from below the ROM
        cmp #$C0
        bcs sc_n
sc_y    sec
        rts
sc_m    dta 0                        ; the pass
sc_h    dta 0                        ; the candidate's page
sc_s    dta 0                        ; S inside hscan
sc_d    dta 0                        ; pass 1's last depth above sc_s (0: none)

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
img_end
        .endl
ab_hnd_e equ ab_hnd+hnd.img_end-HND_ORG

ab_stub equ ab_hnd_e                 ; VSEROR stub (CCTL aperture, $D500), stored
                                     ;   after the handler (a label here would
                                     ;   take the handler's run address)
        .local stub
        org STUB_IRQ,ab_stub
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

mc      equ $3C                      ; the program's MEMAC_CONTROL
zwin    equ $3D                      ; windows to restore after xch

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
img_end
        .endl
ab_stub_e equ ab_stub+stub.img_end-STUB_IRQ

ab_boot equ ab_stub_e                ; boot step ($0480), stored after the stub
        .local bootc
        org BOOT_ORG,ab_boot
;--------------------------------------------------------------
; ATRBOOT boot step, copied to $0480 by ab_go (SDX is gone by then, the
; OS ROM is in and VSEROR points at the stub): reopen E:, load the boot
; sectors of D1: through DSKINV (served by the stub/handler) and run them
; the way the OS boot does (BOOTAD+6, DOSINI, DOSVEC).
;--------------------------------------------------------------

ICCOM   equ $0342
ICBAL   equ $0344
ICBLL   equ $0348
ICAX1   equ $034A
DFLAGS  equ $0240
DBSECT  equ $0241
BOOTAD  equ $0242

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
img_end
        .endl
ab_boot_e equ ab_boot+bootc.img_end-BOOT_ORG

;==============================================================
; variables, buffers (not in the file: they follow the images)
;==============================================================
bss_beg equ ab_boot_e
unit    equ bss_beg
blk     equ unit+1                   ; 2
kq      equ blk+2                    ; 2
ent     equ kq+2                     ; 1
dsec    equ ent+1                    ; 2
mc_k    equ dsec+2                   ; 2
mc_s    equ mc_k+2                   ; 2
mb_sec  equ mc_s+2                   ; 2
dc_sec  equ mb_sec+2                 ; 2
hunit   equ dc_sec+2                 ; 1
hsec    equ hunit+1                  ; 2
m_host  equ hsec+2                   ; NSLOT each
m_hss   equ m_host+NSLOT
m_smap_lo equ m_hss+NSLOT
m_smap_hi equ m_smap_lo+NSLOT
ab_de   equ m_smap_hi+NSLOT          ; 5: first map, length
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
ab_sp   equ p_new+5                  ; stack pointer at entry
cbuf    equ ab_sp+1                  ; 31 x 4
stage   equ cbuf+124                 ; 128
mapbuf  equ stage+128                ; 512
iobuf   equ mapbuf+512               ; 512 B host sector buffer
bss_end equ iobuf+512

        run start
