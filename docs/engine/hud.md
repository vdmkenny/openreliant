# Head-up display

`C:\lancer\game\hud.cpp` holds the display drawn over the view: the panels, the gauges, the target
display and the text. Its code lies between `hog_SND.CPP`'s and `hudmovie.cpp`'s, about 40KB of it;
only `hud_init` asserts, so the source map places that stretch alone.

The port has where an element stands and how wide a line of its text is
([`engine/game/hud.zig`](../../src/engine/game/hud.zig)); it draws nothing yet.

## How it is reached

`hud_draw` (`0x004843B0`) draws the display once a frame. `mission_run` puts it in `sr + 0x88` and
Surrender calls it while it renders, so no call reaches it in the listing and Ghidra does not find
it without being told; `make ghidra-run SCRIPT=DefineFunctions.java ARGS="0x004843b0"` does that.
`hud_init` (`0x00483150`) sets the display up once, from the device reset at `0x004AD0A0` rather
than per frame: it copies the element names into the table at `0x0057BC5C`, a hundred bytes each,
allocates the file's work buffer, takes `oldpalette.tga` and `powerball.tga`, and works out the 62
by 62 table of shading the shield ball is drawn from.

`mission_frame` itself calls only three of the file's routines: the element state machine
(`0x0048B510` and `0x0048B590`), which runs each element through states 1, 2 and 3 on a timer of 60
over 20-byte records based at `0x00501D30`; the subtarget (`0x0048CC30`), which walks the target's
assembly by `link_id`; and a utility (`0x0048CEB0`).

## Where an element stands

`hud_place` (`0x00482E90`) gives an element its place from a fraction of the screen, so the display
keeps its layout at any resolution:

    x = round((screen_width  - 0x21) * across) + 0x10 + offset_x
    y = round((screen_height - 0x21) * down)   + 0x10 + offset_y

with the screen's size at `sr + 0x1666` and `sr + 0x166A`. Half of the way across comes to the
middle of the screen, the inset and the margin cancelling. `hud_grid_place` (`0x00482F00`) places
the item of an index in a grid from half-way across, `0x30` apart across and `0x26` down, two to a
row, its first item `156` to the left.

The places move with the screen, but the shapes and the glyphs do not: the game draws them at their
own size whatever the resolution, and the window it makes is 640 by 480 (`0x004A85BC`).

**Improvement:** the port draws the display as large against the window as it stood against that
640 by 480 screen, by whichever side has room for less, so it keeps its shape. What the display
measures in its own pixels, the inset and the margin and an element's offset, is scaled with it;
the fraction of the window is not, so the display still reaches the edges of a window of any shape.
At a scale of 1 the arithmetic is the game's own. Half of the way across then falls within a pixel
or so of the middle rather than exactly on it, the inset having grown.

## Text

`hud_text` (`0x00480E40`) draws a line through `VFX_string_draw`, left where its alignment is 0,
centred where it is 1 and right where it is 2; an empty string draws nothing. It leaves the line's
bounding box where the caller asks. `font_text_width` (`0x00480E10`) sums a string's widths out of
the cache `font_open` (`0x00480D70`) fills: a record of the font and a width for every code below
255, each taken from `VFX_character_width`.

`sprites.cpp` looks the drawing routines up out of `vfx.dll` by name into function pointers:
`VFX_string_draw` at `0x00594858`, `VFX_character_width` and `VFX_shape_draw_mirrored`.
`VFX_string_draw` draws each code with `VFX_character_draw` and moves along by what it returns, and
`VFX_character_draw` blits the glyph into a pane, clipped. The display is therefore drawn by the
processor into a buffer whichever renderer is running: `hud_draw` branches on `sr + 0x1AC` in six
places, but both sides reach the same `hud_text`.

A glyph's bytes are indices into the font's own palette. The shipped fonts run from those using its
first seventeen entries as levels of coverage, `FONT.FNT` and `ITACSML.FNT` among them, to
`BLUFONT.FNT` and `MED_RED.FNT` reaching past two hundred for glyphs of their own colours.

**Improvement:** the port draws a glyph as a textured rectangle on the GPU rather than blitting it,
so the display costs the processor nothing and scales without blurring. What it draws is the same:
the font's palette looked up for each byte, index 0 left clear, over the scene with the engine's own
overlay-layer depth and alpha blend.

## Art

The hardware renderers take their shapes from `HUDHARD.SPR` and the software renderer from
`HUDSOFT.SPR`; `hud_blit` (`0x0048C6E0`) draws a shape the software way, which `sr + 0x1AC` picks.
`HUDHARD.SPR` holds 388 shapes, 2 palettes and 21 remap tables: radar rings, bar gauges, arcs,
target boxes, ammunition, and the silhouettes the target display shows.

The element names `hud_init` copies come from `0x00515D70`, which the decrypted dump holds as
zeroes, so they are not readable from it.
