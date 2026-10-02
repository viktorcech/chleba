# CHLEBA

SpartaDOS X command (.COM) for the Atari XL/XE with a SIDE3 cartridge.

`CHLEBA.COM` boots an ATR disk image stored on a SIDE3 APT partition
(SpartaDOS, 512 B sectors), with any OS in ROM. The booted program sees
the image as D1: and reads and writes it in place, at SD card speed.

## Features

- **Fragmented ATR files work**: the file's blocks are found through its
  SpartaDOS sector maps and checked against raw SD card reads.
- 128, 256 and 512 B sectors (SD, ED, DD) and large images.
- SDX is left without a cold start: the OS ROM stays in, the OS vectors
  are restored and D1: is booted.
- The D1: handler runs from SIDE3 card RAM. A small stub in the SIDE3
  aperture hooks VSEROR, so the handler works whatever PORTB and the
  program do, including with VBXE MEMAC A mapped over $8000.
- Works on accelerated CPUs and uses MVN on a 65816.
- A plain program: nothing stays resident in SDX.

## Usage

```
CHLEBA file.ATR
```

## Building

Build with [MADS](https://github.com/tebe6502/Mad-Assembler):

```
mads chleba.asm -o:CHLEBA.COM
```

## Files

| File | Description |
|---|---|
| `chleba.asm` | source (the command, D1: handler, VSEROR stub, boot step) |
| `CHLEBA.COM` | built command |
