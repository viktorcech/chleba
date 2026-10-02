# CHLEBA

ATR driver for SpartaDOS X 4.51 on the Atari XL/XE.

CHLEBA.SYS lets you use ATR disk images stored on any SpartaDOS-formatted
drive (for example a SIDE3 APT partition) as disk drives D1:–D15:.
You can also boot an ATR file directly.

## Features

- **Mounting ATR images as Dn: (1–15)**: same approach as the IDE Plus 2.0 BIOS.
  Mount and unmount use the IDE Plus protocol, so drac030's `ATRM.COM` /
  `ATRU.COM` work unchanged.
- **Fragmented ATR files work**: the driver walks the file's SpartaDOS
  sector maps.
- 128 and 256 B sectors (SD, ED, DD) and hard-disk-sized images.
  Images can be mounted read-only.
- **`CHLEBA file.ATR`** boots an ATR from a SIDE3 APT partition with the OS
  in ROM. The booted system reads and writes the file in place.

## Installation

Add this line to `CONFIG.SYS`, after `DEVICE SIDE3`:

```
DEVICE CHLEBA
```

You can also run `CHLEBA.SYS` from the command line.

## Usage

```
ATRM ...          mount an ATR as Dn:   (drac030's tools)
ATRU ...          unmount
CHLEBA file.ATR   boot an ATR file
```

## Building

Build with [MADS](https://github.com/tebe6502/Mad-Assembler). First build
`hnd.asm`, `stub.asm` and `bootc.asm` to `.bin`, then build `chleba.asm`,
which includes `abcmd.asm` and the `.bin` files:

```
mads hnd.asm   -o:hnd.bin
mads stub.asm  -o:stub.bin
mads bootc.asm -o:bootc.bin
mads chleba.asm -o:CHLEBA.SYS
```

## Files

| File | Description |
|---|---|
| `chleba.asm` | the driver: installer, SIO hook, ATR mounting |
| `abcmd.asm` | the `CHLEBA file.ATR` command (ATR boot) |
| `hnd.asm` | D1: handler for the booted ATR (runs from SIDE3 card RAM) |
| `stub.asm` | VSEROR stub in the SIDE3 aperture |
| `bootc.asm` | boot step |
| `atrboot.inc` | shared constants |
| `CHLEBA.SYS` | built driver |
