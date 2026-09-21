# `.SPR` sprites

The game's 2D imagery, drawn by WinVFX. There are 269 sprite sets in `resource.hog`, holding 3,724
shapes between them.

These are the interface, not the world: the HUD, menus, cursors, briefing and loadout screens, the
news reader, kill tallies, and a per-ship schematic. They are **not** model textures, which is
covered under [What sprites are not](#what-sprites-are-not).

```bash
sltool spr info <sprite>                # what the set contains
sltool spr ls <sprite>                  # every block, with kind and size
sltool spr extract <sprite> <out-dir>   # every shape as an indexed PNG
make sprites                            # all 3,724 into game/sprites
```

## Layout

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | `1.40`, stored as four raw bytes rather than a number |
| 4 | 4 | Block count |
| 8 | 8 x count | Directory: a `u32` offset and a `u32` that is **zero in all 3,947 entries of all 269 files** |

Entries are in ascending offset order, so a block runs from its own offset to the next one, or to
the end of the file.

## Blocks

Nothing records what a block is, and three kinds occur. They have to be told apart by structure:

| Kind | Count | Recognised by |
|---|---|---|
| Shape | 3,724 | Parses as a shape header whose rows fit inside the block |
| Palette | 109 | 768 bytes whose every byte is a 6-bit level, so never above `0x3F` |
| Remap table | 105 | 256 bytes, the remainder |
| Placeholder | 9 | Neither, and carries no rows |

Size alone will not separate them: four shipped shapes are exactly 768 or 256 bytes long. The
palette test is what resolves it, and none of those four comes close to passing it, since all four
contain `0xFF`.

The placeholders hold bounds near `maxInt(i32)` and no pixel data. They occur in `LAUNCH.SPR`,
`ifhard.spr` and `ifsoft.spr`.

A remap table maps each palette index to another. The HUD sets open with a run of them, the first
being the identity, `00 01 02 ... FF`.

### Shape

| Offset | Type | Field |
|---|---|---|
| `0x00` | u32 | Two 16-bit values. Constant across a file in the ship schematics and unrelated to the bounds elsewhere. **Unknown.** |
| `0x04` | u32 | **Unknown.** Equal to `(-x1, -y1)` in 36% of shapes, so not an origin in general. |
| `0x08` | i32 x4 | `x1`, `y1`, `x2`, `y2`, inclusive |
| `0x18` | | The rows |

Bounds are signed and can be negative, which is how a sprite is centred on its anchor rather than
its corner. Width is `x2 - x1 + 1`.

### Rows

One run-length encoded row per scanline, top to bottom. Each opcode starts with a control byte
whose low bit picks the kind and whose upper seven bits are a count:

| Control byte | Meaning |
|---|---|
| `0x00` | End of row. The rest of the row stays transparent. |
| Even, count > 0 | Repeat the next byte `count` times |
| Odd, count > 0 | Copy the next `count` bytes |
| `0x01` | Skip the next byte's worth of pixels, leaving them transparent |

Pixels are palette indices and **index 0 is transparent**.

## Palettes

A palette is 256 RGB triples at 6 bits per channel, the VGA convention. Expanding to 8 bits by
repeating the top bits into the bottom keeps full scale full: `(v << 2) | (v >> 4)`.

A file may carry several, and a shape uses the nearest one at or before it, so a set can hold
groups that each have their own. `CAPSHIPS.SPR` is 19 such groups: one palette and two ships each,
so a pair of ships shares a national colour scheme.

**246 of the 269 sets carry no palette at all**, including every ship schematic. Those shapes are
drawn with whatever palette the game has loaded, and `sltool spr extract` falls back to greyscale
for them.

**Unknown:** which palette that is. It is not the first 768 bytes of `palette.ccb`: those are 6-bit
values, but they colour the schematics as noise while leaving the silhouettes clean.

## What sprites are not

The `.SHP` models name 248 distinct textures, and none of them is a sprite set:

- **No model texture name matches any `.spr`.** Not one of the 248, under any prefix.
- 224 of the 269 sets are named `<ship>SCEM.SPR`. They are small, mostly 103x198 or 55x71, one per
  ship, and are the schematic shown in the interface.
- The remaining 45 are named for their screens: `BRIEF`, `FRONTEND`, `HUDHARD`, `LOADOUT`,
  `CURSORS`, `NEWSREP`, `KILLS`, `LAUNCH`, `CAPSHIPS`.

Where the model textures resolve:

| | Models |
|---|---|
| Every texture present in `resource.hog` | 187 |
| Some present | 32 |
| None present | 221 |

All twelve playable fighters resolve, each to a single texture carried under the `g` and `r`
prefixes the loadout screen uses (`gYank_1.TGA`, `rYank_1.tga`). The 221 that do not are the
capital ships, turrets, stations and debris, and they are not merely untextured: 84% of their faces
use the textured-and-lit shading mode, so the engine does ask for a texture.

**Unknown:** where those come from. No archive, `resource.hog`, `CD1.HOG`, `CD2.HOG`, `msspeech.hog`
or `pilots.hog`, holds them under their material names, with or without a prefix. The `.fat` files
are sound banks, not textures: a `2.00` header, a table of offsets, and RIFF/WAVE files.

## Prior art

The RLE encoding and the shape header were decoded by
[DMJC's StarLanceDecomp](https://github.com/DMJC/StarLanceDecomp) from
`VFX_shape_blit_unclipped` in `WINVFX8.DLL`, which also identified the palette blocks and the
nearest-preceding-palette rule. Everything above was re-derived against the 269 shipped files; the
remap tables, the placeholders, the palette content test that separates blocks whose sizes collide,
and the texture findings are additions.
