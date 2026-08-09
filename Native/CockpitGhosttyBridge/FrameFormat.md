# CKGF v1 frame format

CKGF is the internal, versioned byte format between `CockpitGhosttyVT` and
`CockpitGhosttyRenderer`. Every integer is unsigned and encoded in network byte
order unless a field explicitly says otherwise. A complete frame is at most
16 MiB. There is no CRC field: the enclosing UDS frame supplies message
boundaries, and archived build artifacts are protected by the manifest SHA-256.

## Header and sections

The fixed 36-byte header is:

| Offset | Width | Field | Contract |
| ---: | ---: | --- | --- |
| 0 | 4 | magic | ASCII `CKGF` |
| 4 | 2 | version | `1` |
| 6 | 1 | kind | `1` snapshot, `2` delta, `3` scrollback |
| 7 | 1 | flags | bit 0 is full snapshot; all other bits are zero |
| 8 | 8 | base sequence | zero for snapshot; prior output sequence otherwise |
| 16 | 8 | output sequence | nonzero and strictly newer for a delta |
| 24 | 4 | rows | nonzero viewport row count |
| 28 | 4 | columns | nonzero viewport column count |
| 32 | 4 | section count | at most seven |

Each section begins with an 8-byte prefix: one-byte section type, three zero
reserved bytes, and a four-byte payload length. Types cannot repeat. A snapshot
contains sections 1 through 6. A delta contains sections 2 through 6. A
scrollback frame contains only section 7. No trailing bytes are permitted.

## Section payloads

### 1: palette

`u32 count`, followed by `count` entries. Each six-byte entry is `u16 palette
index`, `u8 red`, `u8 green`, `u8 blue`, `u8 reserved=0`. Count is at most 256
and palette indices are in `0...255`, unique, and strictly ascending.
Snapshots contain all 256 entries in ascending index order. A Ghostty
full/global render-state change cannot be represented by a delta: the delta
call fails without advancing the output sequence, and the caller obtains a new
snapshot.

### 2: cursor

Exactly 12 bytes: `u32 row`, `u32 column`, `u8 shape`, `u8 visible`, `u8
blinking`, `u8 reserved=0`. Row and column are inside the frame dimensions.
Shape is 1 block, 2 bar, or 3 underline. Boolean fields are 0 or 1.
When Ghostty reports the cursor outside the current viewport, the wire value is
the legal placeholder row 0/column 0 with `visible=0`. A cursor reported on the
tail cell of a wide grapheme is moved to that grapheme's head column.

### 3: rows

`u32 count`, followed by `count` 16-byte entries: `u32 row`, `u8 flags`, three
zero reserved bytes, `u32 first cell index`, `u32 cell count`. Flag bit 0 marks
the row present and bit 1 marks soft wrapping; all other bits are zero. Row is
inside the viewport. Entries are unique and strictly ascending by row. A
snapshot lists every viewport row; a delta lists only dirty rows. Cell ranges
are contiguous, begin at zero, cover the complete cells section exactly once,
and every referenced cell has the same row as its row entry.

### 4: cells

`u32 count`, followed by `count` 20-byte entries: `u32 row`, `u32 column`, `u8
width`, `u8 reserved=0`, `u16 reserved=0`, `u32 grapheme index`, `u32 style
index`. Row and column are in bounds. Width is 0 spacer, 1 narrow, or 2 wide.
Index zero means no grapheme or default style.
Entries are strictly ascending by `(row, column)` and grapheme/style indices
must reference an entry present in the same frame.

### 5: graphemes

`u32 count`, followed by variable entries: `u32 nonzero index`, `u32 UTF-8 byte
length`, then exactly that many bytes. Length is nonzero and the bytes must be
valid UTF-8. Indices are assigned in entry order starting at 1.

### 6: styles

`u32 count`, followed by `count` 16-byte entries: `u32 nonzero index`, `u8
foreground kind`, `u8 background kind`, `u8 flags`, `u8 underline`, `u32
foreground value`, `u32 background value`. Color kind 0 is default and requires
value zero; kind 1 is palette and permits `0...255`; kind 2 is RGB and permits
`0x000000...0xFFFFFF`. Style flag bits 0 through 7 are bold, italic, faint,
blink, inverse, invisible, strikethrough, and overline. Underline is 0 none, 1
single, 2 double, 3 curly, 4 dotted, or 5 dashed.

### 7: scrollback

The prefix is `u64 requested start`, `u32 returned count`, `u32 reserved=0`.
Each returned line is `u64 absolute line index`, `u8 wrapped` (0 or 1), three
zero reserved bytes, `u32 UTF-8 byte length`, and exactly that many valid UTF-8
bytes. Pagination preserves ascending line order.
Absolute line indices are bridge-owned, monotonically increasing identities;
retained lines are not renumbered when older Ghostty history is evicted. The
wrapped byte is copied from the corresponding physical Ghostty history row.

Renderer application is transactional. A parse, allocation, texture, command,
or draw failure leaves the previously committed viewport, palette, cursor, and
sequence unchanged so the same frame can be retried.

## Golden frames

The tooling test decodes these hand-derived hexadecimal fixtures and compares
them byte for byte with live bridge output.

Snapshot, 1845 bytes:

```text
434b474600010101000000000000000000000000000000010000000200000006
0000000601000000000006040000010000001d1f21000001cc6666000002b5bd
68000003f0c67400000481a2be000005b294bb0000068abeb7000007c5c8c600
0008666666000009d54e5300000ab9ca4a00000be7c54700000c7aa6da00000d
c397d800000e70c0b100000feaeaea00001000000000001100005f0000120000
870000130000af0000140000d70000150000ff000016005f00000017005f5f00
0018005f87000019005faf00001a005fd700001b005fff00001c00870000001d
00875f00001e00878700001f0087af0000200087d70000210087ff00002200af
0000002300af5f00002400af8700002500afaf00002600afd700002700afff00
002800d70000002900d75f00002a00d78700002b00d7af00002c00d7d700002d
00d7ff00002e00ff0000002f00ff5f00003000ff8700003100ffaf00003200ff
d700003300ffff0000345f00000000355f005f0000365f00870000375f00af00
00385f00d70000395f00ff00003a5f5f0000003b5f5f5f00003c5f5f8700003d
5f5faf00003e5f5fd700003f5f5fff0000405f87000000415f875f0000425f87
870000435f87af0000445f87d70000455f87ff0000465faf000000475faf5f00
00485faf870000495fafaf00004a5fafd700004b5fafff00004c5fd70000004d
5fd75f00004e5fd78700004f5fd7af0000505fd7d70000515fd7ff0000525fff
000000535fff5f0000545fff870000555fffaf0000565fffd70000575fffff00
005887000000005987005f00005a87008700005b8700af00005c8700d700005d
8700ff00005e875f0000005f875f5f000060875f87000061875faf000062875f
d7000063875fff00006487870000006587875f0000668787870000678787af00
00688787d70000698787ff00006a87af0000006b87af5f00006c87af8700006d
87afaf00006e87afd700006f87afff00007087d70000007187d75f00007287d7
8700007387d7af00007487d7d700007587d7ff00007687ff0000007787ff5f00
007887ff8700007987ffaf00007a87ffd700007b87ffff00007caf000000007d
af005f00007eaf008700007faf00af000080af00d7000081af00ff000082af5f
00000083af5f5f000084af5f87000085af5faf000086af5fd7000087af5fff00
0088af8700000089af875f00008aaf878700008baf87af00008caf87d700008d
af87ff00008eafaf0000008fafaf5f000090afaf87000091afafaf000092afaf
d7000093afafff000094afd700000095afd75f000096afd787000097afd7af00
0098afd7d7000099afd7ff00009aafff0000009bafff5f00009cafff8700009d
afffaf00009eafffd700009fafffff0000a0d700000000a1d7005f0000a2d700
870000a3d700af0000a4d700d70000a5d700ff0000a6d75f000000a7d75f5f00
00a8d75f870000a9d75faf0000aad75fd70000abd75fff0000acd787000000ad
d7875f0000aed787870000afd787af0000b0d787d70000b1d787ff0000b2d7af
000000b3d7af5f0000b4d7af870000b5d7afaf0000b6d7afd70000b7d7afff00
00b8d7d7000000b9d7d75f0000bad7d7870000bbd7d7af0000bcd7d7d70000bd
d7d7ff0000bed7ff000000bfd7ff5f0000c0d7ff870000c1d7ffaf0000c2d7ff
d70000c3d7ffff0000c4ff00000000c5ff005f0000c6ff00870000c7ff00af00
00c8ff00d70000c9ff00ff0000caff5f000000cbff5f5f0000ccff5f870000cd
ff5faf0000ceff5fd70000cfff5fff0000d0ff87000000d1ff875f0000d2ff87
870000d3ff87af0000d4ff87d70000d5ff87ff0000d6ffaf000000d7ffaf5f00
00d8ffaf870000d9ffafaf0000daffafd70000dbffafff0000dcffd7000000dd
ffd75f0000deffd7870000dfffd7af0000e0ffd7d70000e1ffd7ff0000e2ffff
000000e3ffff5f0000e4ffff870000e5ffffaf0000e6ffffd70000e7ffffff00
00e80808080000e91212120000ea1c1c1c0000eb2626260000ec3030300000ed
3a3a3a0000ee4444440000ef4e4e4e0000f05858580000f16262620000f26c6c
6c0000f37676760000f48080800000f58a8a8a0000f69494940000f79e9e9e00
00f8a8a8a80000f9b2b2b20000fabcbcbc0000fbc6c6c60000fcd0d0d00000fd
dadada0000fee4e4e40000ffeeeeee00020000000000000c0000000000000005
0101000003000000000000240000000200000000010000000000000000000005
0000000101000000000000050000000004000000000000680000000500000000
0000000001000000000000010000000100000000000000010100000000000002
0000000100000000000000020100000000000003000000010000000000000003
0100000000000004000000010000000000000004010000000000000500000001
0500000000000031000000050000000100000001680000000200000001650000
0003000000016c00000004000000016c00000005000000016f06000000000000
140000000100000001010000000000000100000000
```

Delta, 281 bytes:

```text
434b474600010200000000000000000100000000000000020000000200000006
00000005020000000000000c0000000000000001010100000300000000000014
0000000100000000010000000000000000000005040000000000006800000005
0000000000000000010000000000000100000000000000000000000101000000
0000000200000001000000000000000201000000000000030000000100000000
0000000301000000000000040000000100000000000000040100000000000005
0000000105000000000000310000000500000001000000014800000002000000
016500000003000000016c00000004000000016c00000005000000016f060000
00000000140000000100000001010000000000000100000000
```

Scrollback page, 79 bytes:

```text
434b474600010300000000000000000000000000000000010000000200000004
0000000107000000000000230000000000000000000000010000000000000000
0000000000000000000000036f6e65
```
