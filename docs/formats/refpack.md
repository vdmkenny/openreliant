# RefPack compression

Most members of `resource.hog` are compressed with **RefPack**, Electronic Arts' LZ77 variant, also
called QFS and named FB10 after the two bytes its header starts with.

A stream is a sequence of commands. Each copies a short run of literal bytes straight from the
input, then usually repeats a run of bytes that already appeared in the output. Four command
encodings cover progressively longer matches and distances, and a fifth ends the stream.

## Header

| Size | Field |
|---|---|
| 1 | Flags |
| 1 | `0xFB` |
| 3 or 4 | Compressed size, only when the flags say so |
| 3 or 4 | Decompressed size |

Sizes are big-endian. The flag bits that matter:

| Bit | Meaning |
|---|---|
| `0x01` | A compressed size precedes the decompressed size |
| `0x80` | Sizes are 4 bytes rather than 3 |

Every stream in this game uses `10 FB`: neither bit set, so the header is five bytes and carries
only the decompressed size.

## Commands

The first byte selects the encoding. In the table, *literals* is how many bytes are copied from the
input before the match, *length* is how many bytes the match repeats, and *distance* is how far
back in the output it starts.

| First byte | Bytes | Literals | Length | Distance |
|---|---|---|---|---|
| `0x00`-`0x7F` | 2 | `b0 & 3` | `((b0 >> 2) & 7) + 3` | `((b0 & 0x60) << 3) + b1 + 1` |
| `0x80`-`0xBF` | 3 | `(b1 >> 6) & 3` | `(b0 & 0x3F) + 4` | `((b1 & 0x3F) << 8) + b2 + 1` |
| `0xC0`-`0xDF` | 4 | `b0 & 3` | `((b0 & 0x0C) << 6) + b3 + 5` | `((b0 & 0x10) << 12) + (b1 << 8) + b2 + 1` |
| `0xE0`-`0xFB` | 1 | `((b0 & 0x1F) << 2) + 4` | none | none |
| `0xFC`-`0xFF` | 1 | `b0 & 3` | none | none, and the stream ends |

So the reachable ranges are matches of 3 to 10 within 1 KiB, 4 to 67 within 16 KiB, and 5 to 1028
within 128 KiB; literal runs are 4 to 112 bytes and always a multiple of four, except for the up to
three literals a short match or the final command can carry.

A match may overlap the bytes it is producing. A distance of one with a length of five repeats the
previous byte five times, so the copy has to proceed one byte at a time rather than as a block
move.

## Decompressing

```bash
sltool hog extract <archive> <dir>     # decompresses members as it extracts
```

The decompressor is `src/formats/refpack.zig`. It validates as it goes: a command that runs past
the end of the input, a match reaching before the start of the output, or a total that disagrees
with the header's decompressed size are all rejected rather than producing truncated output.

All 950 compressed members of `resource.hog` decompress to exactly the size their headers declare,
producing 144.9 MiB from 54.7 MiB.
