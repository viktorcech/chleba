;--------------------------------------------------------------
; ATRBOOT -- shared constants (stub.asm, hnd.asm, chleba.asm/abcmd.asm)
;--------------------------------------------------------------

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
