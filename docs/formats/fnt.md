# `.fnt` fonts

The interface's text is drawn with WinVFX bitmap fonts, loaded from `resource.hog`.

```bash
sltool fnt info <font>                # header, and the width of every character
sltool fnt render <font> <out.png>    # every glyph in one atlas, sixteen codes to a row
make fonts                            # every font into game/fonts
```

## Layout

| Offset | Size | Field |
|---|---|---|
| `0x00` | 4 | Version, `2.` or `1.` followed by two NULs |
| `0x04` | 4 | Entries in the offset table |
| `0x08` | 4 | Height: rows in every glyph |
| `0x0C` | 4 | **Unknown.** Nothing in WinVFX or the payload reads it |
| `0x10` | 4 x entries | Offset of each character's glyph from the start of the file; 0 for none |

The table is indexed by character code. A glyph is a `u32` width, then `width x height` bytes of
pixels, row by row. Glyphs follow the table in code order, and a glyph of width 0 is four bytes.

Some fonts end with 768 more bytes: 256 RGB triples of 6-bit levels. In some it is a grey ramp, in
others unrelated colours. **Unknown:** what reads it; neither WinVFX nor the payload's font setup
does.

## Pixels

A pixel is a coverage level, `0` for none up to `16` for fully inked, so glyphs are anti-aliased.
WinVFX's `VFX_character_draw` either writes the levels as they are or looks each up in a remap
table the caller supplies, with `0xFF` meaning transparent; the remap table is what gives text its
colour. `sltool fnt render` shows the levels as grey, with 0 transparent.

## Characters

Codes 0 to 31 are empty. Codes 32 to 127 are ASCII, and in the larger fonts 128 to 255 hold
accented letters and symbols. Some tables run past 255, but those entries are empty, and the
payload's font setup, `FUN_00480D70`, caches the width of codes below 255 only.

## Prior art

[DMJC's StarLanceDecomp](https://github.com/DMJC/StarLanceDecomp) read the header, the glyph
records and the two drawing modes from `WINVFX8.DLL`. It gives the offset table a fixed 256 entries;
the table's length is the count at `0x04`, which in several fonts exceeds 256. The trailing palette
and the coverage levels are additions.
