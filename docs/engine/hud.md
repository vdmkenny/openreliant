# Head-up display

`C:\lancer\game\hud.cpp` holds the display drawn over the view: the panels, the gauges, the target
display and the text. Its code lies between `hog_SND.CPP`'s and `hudmovie.cpp`'s, about 40KB of it;
only `hud_init` asserts, so the source map places that stretch alone.

The port draws the first of its readouts
([`engine/game/hud.zig`](../../src/engine/game/hud.zig)), reaching it as the engine does, through
the overlay `srcore.render` runs after a frame's layers and before the scene ends.

## How it is reached

`hud_draw` (`0x004843B0`) draws the display once a frame. `mission_run` puts it in `sr + 0x88` and
Surrender calls it while it renders, so no call reaches it in the listing and Ghidra does not find
it without being told; `make ghidra-run SCRIPT=DefineFunctions.java ARGS="0x004843b0"` does that.
`hud_init` (`0x00483150`) sets the display up once, from the device reset at `0x004AD0A0` rather
than per frame: it copies the element names into the table at `0x0057BC5C`, a hundred bytes each,
allocates the file's work buffer, takes `oldpalette.tga` and `powerball.tga`, and works out the 62
by 62 table of shading the power ball is drawn from: the power distribution display, which the
game binds as POWERBALL WINDOW.

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

**Improvement:** the display is drawn over the finished frame, after the bloom, rather than into
it, so that nothing of it blooms. The game has no bloom to keep it out of; the port's is an
improvement over the scene alone. The device is told where the scene ends
(`device.Device.overlay`), and the GPU one draws what follows into the composed frame with
pipelines of a single sample. The software device adds nothing of its own and ignores the mark.

**Improvement:** the port draws a glyph as a textured rectangle on the GPU rather than blitting it,
so the display costs the processor nothing and scales without blurring. What it draws is the same:
the font's palette looked up for each byte, index 0 left clear, over the scene with the engine's own
overlay-layer depth and alpha blend.

It has no fallback yet: `--original` draws the display the same way, and the software device, which
has no GPU to draw rectangles with, cannot draw it at all. Both want `VFX_character_draw` ported,
after which `--original` takes it too.

## Which views have it

`hud_draw` reads `camera_view_last` (`0x00539A64`) rather than the current view, and branches on it
in five places. Everything from the readouts to the clock is skipped unless it is 0, the view ahead
from the cockpit, so the cockpit's own side and rear views do not have the instruments either. The
views that do not draw them get a line of text at the top instead, except the cutaways from `0x24`
to `0x26`, which get none. The view ahead also draws a block of its own that no other does.

It does not read `hit_shake` (`0x00588724`), so nothing of the display moves when the ship is hit.

## The readouts

`hud_draw` puts three readouts in a row across the top of the screen, each a shape of the display's
set with a number centred under it, `0x10` right of the shape's point and `0x1E` below it. All three
stand half of the way across, at offsets of `0x39`, `0x5F` and `0x98`:

| Offset | Shape | Shows |
| --- | --- | --- |
| `0x39` | `0xCD`, a ship with its engines burning | the afterburner fuel, in hundreds |
| `0x5F` | `0xD0`, a skull and crossbones, drawn 4 left | `skull_count` (`0x00562DF4`), one of a run of tallies at `0x562DEC` to `0x562DF8` that a mission's start zeroes together and that is kept across a run. **Unknown** what it counts; it reads 0 in a fresh mission, and the game binds a DISPLAY KILLS key |
| `0x98` | `0xCF`, a coil, drawn `0x1A` left | the object's countermeasures (`+0x5EC`), 29 when it is created, drawn only while a condition of its own holds. **Unverified:** that they are countermeasures; `object_spend_countermeasure` (`0x00462550`) takes one at a keypress with a sound, the ships' own code takes them too, and the game binds a COUNTERMEASURES key |

The port draws the fuel ([`engine/game/hud.zig`](../../src/engine/game/hud.zig)); the other two wait
on what they count.

## The status lights

Inside the block it draws only for the view ahead, `hud_draw` packs up to seven lights into the
grid, each shown only while its own condition holds. The index it hands `hud_grid_place` is a
running count that advances only for a light it draws, so one that is not shown takes no place and
those after it close up.

In the order it draws them: `0xCC`, two ships with arrows, shown while `matching_speed` holds; then
`0xCB`, `0xC5`, `0xC3`, `0xC4`, `0xC6` and `0xCA`. **Unknown:** what shows the last six, which read
globals and object fields with no names yet.

The port draws the first and packs the rest the same way.

## Art

The hardware renderers take their shapes from `HUDHARD.SPR` and the software renderer from
`HUDSOFT.SPR`; `hud_blit` (`0x0048C6E0`) draws a shape the software way, which `sr + 0x1AC` picks.
`HUDHARD.SPR` holds 388 shapes, 2 palettes and 21 remap tables: radar rings, bar gauges, arcs,
target boxes, ammunition, and the silhouettes the target display shows.

The element names `hud_init` copies come from `0x00515D70`, which the decrypted dump holds as
zeroes, so they are not readable from it.

## Turning it off

No key turns the whole display off: the game binds none, and `hud_draw` has no guard for it.
Individual panels have their own keys, which is what the element state machine drives: GUNNERY
WINDOW, MISSILE WINDOW, COMMS WINDOW, POWERBALL WINDOW, OBJECTIVES WINDOW, WING STATUS WINDOW and
DAMAGE WINDOW, each with a locked form. The nearest thing to turning it off is leaving the view
ahead from the cockpit, which drops the instruments.

## What is not known yet

- What the skull readout counts. Its shape, its place and the tally it reads are known; the tally
  has no name.
- What shows six of the seven status lights. Each reads a global or an object field with no name.
- The names of the display's elements, which `hud_init` copies from `0x00515D70`.
- What the rest of `hud_draw`'s 946 lines draw: the radar, the target display, the shields and the
  armour, the ship's own schematic, the reticle, and the lines of text the views without
  instruments show instead.
- How the display reaches the screen in the game, which is `vfx.dll`'s panes rather than anything
  in the payload.
