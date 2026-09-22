# Head-up display

`C:\lancer\game\hud.cpp` holds the display drawn over the view: the panels, the gauges, the target
display and the text. Its code lies between `hog_SND.CPP`'s and `hudmovie.cpp`'s, about 40KB of it;
only `hud_init` asserts, so the source map places that stretch alone.

The port draws the readouts, the clock, the status lights with the devices' charges, the jump
prompt, the eject marker, the scanner and the ship status indicator's schematic and shields
([`engine/game/hud.zig`](../../src/engine/game/hud.zig)), reaching them as the engine does, through
the overlay `srcore.render` runs after a frame's layers and before the scene ends.

## The elements

The display's elements as the game's manual names them, with where the code that draws each has
been found. An element whose code is not found yet is marked so.

| Element | Where | Key | Shows | Code |
| --- | --- | --- | --- | --- |
| Targeting cluster | middle | | the reticle where the guns aim; speed on an arc to the left, the speed the throttle sets and the speed the ship is making; the weapons' charge on an arc to the right; an indicator pointing to the next nav point, and one pointing to the target, red for hostile and green for friendly | [The targeting cluster](#the-targeting-cluster): the arcs, the two markers with their figures, the fills and the reticle. The indicators for the nav point and the target are not found |
| Target ring | round the target | | a ring round a target in sight, red or green, with its range in metres under it; a lead cursor, a box with a line trailing from it, where to shoot | `hud_draw` works out where the target (`+0x720`) stands on the screen and draws shape `0x15F` there. Not ported |
| Directional calipers | the display's edges | | the direction and range of a target out of sight | Not found |
| Missile lock ring | round the target | | a ring that closes in round the target and turns white once a missile has locked, with a tone | Not found |
| Jump icon | above the middle | J | the prompt to press JUMP DRIVE, once the mission has a jump ready | [The jump prompt](#the-jump-prompt-the-eject-marker-and-the-scanner) |
| Target display | foot, right | | the target's image with its shields and armour in a ring, its name, its type, its range and its speed; a larger form for a big target, with its current subtarget and a bar for each | **Unverified:** `hud_ship_status` in its second mode draws the small form. The large form is not found |
| Subtarget | on the target's model | S, SHIFT+S | the parts of the subtarget picked out in red | `hud_subtarget` (`0x0048CC30`), which walks the target's assembly by `link_id` |
| Radar | foot, middle | V | three rings with the ship at their middle and a wedge for its view ahead; each object a dot, red for hostile, green for friendly, blue for one calling on the radio, on a line up or down from the rings by its height. V narrows and widens its range, the middle ring filling the display at the narrowest | `hud_radar` (`0x00488BD0`), [The radar](#the-radar). The rings are ported; the dots are not |
| Ship status | foot, left of middle | always shown | the ship's image in two rings of segments, forward, aft and the two sides: shields outside, armour inside. A shield dims as it wears; an armour segment goes as it is lost. Shifting power fore or aft doubles the shields there | `hud_ship_status` (`0x00489350`). The schematic and the shields are ported; the armour is not yet found |
| Missile display | top, middle | M | the missile's name, the ship's missiles in a ring, how many of the chosen one are left, and the one armed at six o'clock. Comma and full stop turn the ring | Not found |
| Mission objectives | right | B | the mission's goals, the current one first; B pages through them | Not found |
| Gunnery display | foot, left | G | the gun's name, the ship as a wire frame with the gun lit, the rounds left for a gun that fires them, and whether the guns fire together or in turn. G picks the next gun, F fires them all, CTRL and G switches the two ways of firing them all | Not found |
| Damage display | top, right | D | a segmented bar each for the weapons, the engines and the shields, shortening with damage | Not found |
| Power distribution | left | P | the guns, the shields and the engines round a ball, each with its share of the power, a third each at first. P held with the stick moves power toward one; U, I and O give all of it to the guns, the engines or the shields, and `[` shares it out again | `hud_init` works out the ball's shading from `powerball.tga`. The display itself is not found |
| Communications | top, left | C | the units in range, numbered, which the number keys call. Landing, rearming and a nanny ship are asked of the base ship | **Unverified:** `0x0048CF20`, which draws the lines of the table at `0x0057BC5C` eleven apart |
| Wing status | right | X | the wing's fighters in a grid, the player's wing first, each with a bar for its damage | Not found |
| Readouts | top, right of middle | | the seconds of afterburner fuel, a tally under a skull, and the countermeasures left | [The readouts](#the-readouts) |
| Status lights | top, left of middle | | the systems that are on: match speed, blind fire, smart targeting, which makes any ship fired on the target, reverse thrust, the spectral shields and the cloak with a bar for the time left, the ECM | [The status lights](#the-status-lights) |
| Clock | foot, middle, over the radar | | the time played | [`hud.zig`](../../src/engine/game/hud.zig) |

Each panel but the ship status comes and goes as the game needs it, which is the element state
machine at `0x00501D30`; SHIFT with a panel's key holds it on.

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

**Improvement:** the port draws the display as large against the window as it stood against a
1024 by 768 screen, a mode the hardware renderers run in and the size of the retail game's own
screenshots, by whichever side has room for less, so it keeps its shape. What the display measures
in its own pixels, the inset and the margin and an element's offset, is scaled with it; the
fraction of the window is not, so the display still reaches the edges of a window of any shape.
At a scale of 1 the arithmetic is the game's own. Half of the way across then falls within a pixel
or so of the middle rather than exactly on it, the inset having grown. Since the offsets are fixed
in pixels, the screen chosen sets how far in the elements stand: at 640 by 480 the clock, 130
above the foot, stands near two thirds of the way down, and at 1024 by 768 near four fifths.

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

`hud_draw` reads `camera_view_last` (`0x00539A64`) rather than the current view. The instruments
are drawn only while it is 0, the view ahead from the cockpit, in whichever cockpit mode: the chase
view the cockpit key cycles to is view 0 too, and has them all. The cockpit's own side and rear
views, 1 to 3, do not. In its order:

| Drawn | In |
| --- | --- |
| the launch's typed text, and a key's prompt | every view |
| the devices' charges, which run | every view |
| the jump prompt, the radar, the eject marker, the scanner and the status lights | view 0 |
| the view's name, centred half of the way across and 10 down: the view table's string for it | every view but 0, and but the fly-bys, `0x24` to `0x26` |
| a string of `0x0057BF34`'s, `0x3C` above the foot, unless it is `0x90` | view `0xD` |
| the table of lines `0x0048CF20` draws, placed `(-110, -140)` from the middle | every view |
| the target ring, the readouts, the ship status indicator, the targeting cluster's arcs and markers, the radar and the clock | view 0 |
| the reticle (`0xD7`) at the middle, and the blind fire sight (`0xD8`) that closes on a target | view 0, but not in the chase mode |
| in a multiplayer game, a shape of `dmicons.spr` for the player's `+0x754` at the middle | view 0 |
| the panels the element state machine opens, sliding in and out | view 0 while they slide, every view once open |
| a line of text at the foot while `0x00529FB8` is set | every view |

The view's name is one of the strings `language_init` (`0x00490DC0`) reads out of `language.dll`
([`engine/game/language.zig`](../../src/engine/game/language.zig)): Cockpit View, Left View, Target
Camera, External Camera, Missile Camera and the like, or a single space for the chase views and
most cutaways. Its place is measured from the screen's edge rather than with `hud_place`.

The port draws the view's name, and in view 0 all it has ported of the rest. A mission's launch
ends in view 0 ([`camera.md`](camera.md)), and so does the port's start.

While `hud_interference` (`0x00588700`) is above 0, `hud_draw` draws its shapes through `hud_blit`
(`0x0048C6E0`) rather than `VFX_shape_draw`: under the hardware renderers each row of the shape is
shifted sideways by a random amount scaled by `hud_interference`, or for some shapes by `hit_shake`
(`0x00588724`). `hud_interference_start` (`0x00494890`) sets it to 0.3 and plays sound 12 at the
ship no more often than every 15 to 29 ticks; `hud_interference_fade` (`0x004948F0`) lowers it by
0.005 a tick. The two routines that start it, `0x00463EE0` and `0x004641F0`, lie between
`cloak.cpp`'s code and `collision.cpp`'s. **Unverified:** that they are where the ship takes
damage, and which shapes take `hit_shake`. The port draws every shape plain, as the game does
with no interference.

## The readouts

`hud_draw` puts three readouts in a row across the top of the screen, each a shape of the display's
set with a number centred `0x1E` below its point and across from it by as much as puts it under
the shape. All three stand half of the way across, at offsets of `0x39`, `0x5F` and `0x98`:

| Offset | Shape | Number | Shows |
| --- | --- | --- | --- |
| `0x39` | `0xCD`, a ship with its engines burning | `0x10` right | the seconds of afterburner fuel left: `afterburner_fuel`, which is in hundredths, over 100 |
| `0x5F` | `0xD0`, a skull and crossbones, drawn 4 left | `0x0B` right | `skull_count` (`0x00562DF4`), one of a run of tallies at `0x562DEC` to `0x562DF8` that a mission's start zeroes together and that is kept across a run. **Unknown** what it counts; it reads 0 in a fresh mission, and the game binds a DISPLAY KILLS key |
| `0x98` | `0xCF`, a coil, drawn `0x1A` left | 9 left | the object's countermeasures left (`+0x5EC`), 29 when it is created, which `object_spend_countermeasure` (`0x00462550`) takes one at a time. It is drawn unless `ShowHudIcon` flashes icon 3 and the flash is dark |

The port draws all three ([`engine/game/hud.zig`](../../src/engine/game/hud.zig)).

## The targeting cluster

After the ship status indicator, `hud_draw` draws the cluster about the middle of the screen. Its
arcs stand a share of the screen's width from the middle, so they part as the screen widens; the
rest is in pixels:

| Drawn | Where |
| --- | --- |
| the right arc: shape `0x7F`, mirrored within its own bounds (`VFX_shape_draw_mirrored`) | `0.15625` of the width right of the middle, cut down to a whole number, less `0x43`, and `0x4A` above the middle |
| the left arc: shape `0x7F` | `0.15625` of the width left of the middle, and `0x4A` above it |
| the throttle's marker, shape `0xEA`, and the speed it asks, the top speed times the throttle, right-aligned 10 left of it and 8 above | on the circle below, at the throttle's size, to 1 |
| the speed's marker, shape `0xEA`, and the speed, right-aligned likewise | on the circle, at the speed over the top speed, to 1 |
| the speed arc's fill: shape `0xB8` lit below the speed's marker, `0xB9` unlit above it | 10 left of the left arc's point |
| the charge arc's fill: shape `0xF9` lit below the guns' charge, `0xF8` unlit above it | 14 right of the right arc's point |
| the radar | [The radar](#the-radar) |
| the reticle, shape `0xD7`, and blind fire's sight | the middle |

The markers ride a circle centred 100 right of the left arc's point and 80 below it, at 124 times
the sine and 94 times the cosine of an angle of 310 degrees at nothing and 210 at full. The
throttle's marker shows only while the throttle and the speed differ by more than 0.1 when
tripled; `hud_draw` makes the global palette that much dimmer for it, to full, and back to the
display's brightness after it.

A fill is two VFX panes a pixel above and left of where its shapes are drawn, `0x42` wide and down
to `0x89` below the arcs' top, whose edges `hud_draw` moves each frame: the lit shape is drawn
into the one from a pixel above the level to the foot and the unlit one into the one from a pixel
above the top to the level, so the row they share is unlit. The speed's level is its marker's
height; the charge's is `0x8A` less the guns' charge (`GameObject.gun_charge`, `+0x140`) times
`0x8A` over the most it holds (`ShipCombat.gun_energy`). For ship type `0x0B` or `0xFF`, the
Phoenix, with the guns not all firing and the chosen group's first gun of type 11, the level is
the object's `+0x148` times `0x8A` instead.

The reticle is drawn at the middle unless the cockpit mode is the chase view, and a second time:
at the middle when no target is on the screen (`hud_target_x` is -1); on the target, bright
(`0xD8`), while blind fire aims at it, which it does for a target within `0x46` across and `0x32`
down of the middle while the ship carries blind fire, has it on, and has the guns not all firing
or only one group, unless the chosen group's first gun is of type 11; otherwise where blind fire's
sight stands (`hud_sight_x`, `hud_sight_y`), which glides back to the middle a pixel a tick and
rests within 2 of it, bright while the target stands within `0x10` of the middle. The object's
`blind_fire_aim` (`+0x674`) says whether blind fire aims.

The port draws all of it but the indicators and the target ring, which need a target. Not yet
ported: the Phoenix's own level.

## The radar

`hud_radar` (`0x00488BD0`) draws a dot for each object in range: targetable, and not exploding,
disabled, ejected or a cloaked hostile; placed by its bearing and distance from the player at
scales the range (`radar_range`, `0x0057BE00`, 0 to 2) picks, with a line up or down by its height
in palette index `0x26` for a hostile and `0x62` otherwise, and a shape at its end, `0xE4` or
`0xE5`, `0x130` for the target. Then it draws the rings, `hud_radar_rings` (`0x0057BC50`), one of
shapes `0x168` to `0x16B` with the wedge of the view ahead, `0x42` left and `0x20` above a point
placed half of the way across, at the foot of the screen, 1 right and 51 up. `hud_init` starts it
on `0x16B`, and `hud_radar_zoom` (`0x004892F0`) steps the rings a shape every 50 ticks toward a new
range's. The clock stands 79 above the radar's point.

The port draws the rings. Not yet ported: the dots, and the change of range.

## The status lights

Inside the block it draws only for the view ahead, `hud_draw` packs up to nine lights into the
grid, each shown only while its own condition holds. The index it hands `hud_grid_place` is a
running count that advances for each light whose condition holds, so one that is out takes no
place and those after it close up. A flashing light keeps its place while it is dark.

In the order it draws them:

| Shape | Light | Shown while |
| --- | --- | --- |
| `0xCC` | match speed | `matching_speed` |
| `0xCB` | blind fire | the ship carries blind fire (`blind_fire_fitted`, `0x00566F8C`), `blind_fire` (`0x00579990`) is on, and the guns are not all firing (`GunMode.all`, the object's word at `+0x144`) |
| `0xC5` | smart targeting | `smart_targeting` (`0x0056996C`), which SMART TARGET flips, or icon 4 |
| `0xC3` | enemy lock | `enemy_lock` (`0x00579988`) with no missile homing on the ship, or icon 0. It flashes for 50 ticks of every 100, and a warning sound loops while it is shown |
| `0xC4` | missile incoming | the object's `missile_homing` (`+0x64C`), or icon 1. It flashes for 25 ticks of every 50, on the lock warning's count (`0x0057BC44`) |
| `0xC6` | ECM | `ecm_state` (`0x0057BF4C`) is 1, or icon 2, with a bar for its charge `0x23` below |
| `0xC7` | cloak | the ship carries a cloak (`cloak_state`, `0x00566638`, not -1), on or off, with a bar for its charge `0x20` below. Never in a multiplayer game |
| `0xCA` | spectral shields | `spectral_shields_state` (`0x0057BF20`) is 1, with a bar for their charge `0x20` below |
| `0xC8` | reverse thrust | the object's `reverse_thrust` |

An icon is one of `ShowHudIcon`'s (mission command `0x5B`, `cmd_ShowHudIcon`): it sets an icon of a
table of twenty (`hud_icons`, `0x00566558`) off, on or flashing, and `hud_icon_lit` (`0x00482F50`)
says whether one is lit this frame. A flashing icon is lit for the first 50 ticks of every 100; one
that runs past 100 carries what it ran over into the next hundred, lit. `hud_draw` asks only when
the light's own condition does not already hold, so an icon's flash stands still while it does. The
display reads icons 0 to 5: 3 is the countermeasures readout, 5 the eject marker.

`enemy_lock` is set by `mission_frame` each frame when a ship whose order is Fight, against the
player, has byte `0x2F` of its fight state set. **Unverified:** that the byte is a missile lock.
Nothing in the payload writes it at that offset; the light's shape is a ship in a gun sight, and the
manual has countermeasures answer an enemy's missile lock. `missile_homing` is zeroed on every
object by `mission_frame` and set by `missiles_update` (`0x004960F0`) on the object a live missile's
order targets.

A bar is a line of `hud_colour(0xE7, 0x68, 0x00)` drawn with `VFX_line_draw` from one pixel right of
the light's point to the charge times a scale further: `1/62` for the ECM, `1/312` for the cloak and
`1/187` for the spectral shields, so a full bar is about 32 pixels, rounded as `0x004C3330` rounds.

The port draws all nine by these conditions. Not yet ported: the warning sound.

## The devices

Three devices run off a charge in ticks, which `hud_draw` keeps in every view: charging a tick a
tick while off, up to full, and draining while on. One that runs dry is turned off.

| Device | State | Charge | Full | Drains a tick |
| --- | --- | --- | --- | --- |
| ECM | `ecm_state` (`0x0057BF4C`) | `ecm_charge` (`0x005665F8`) | 2000 | 1 |
| Cloak | `cloak_state` (`0x00566638`) | `cloak_charge` (`0x0056663C`) | 10000 | 1, outside a multiplayer game |
| Spectral shields | `spectral_shields_state` (`0x0057BF20`) | `spectral_shields_charge` (`0x00566620`) | 6000 | 6 |

A state is -1 for a ship that does not carry the device, 0 for off and 1 for on. `hud_init` sets
all three to 0 and full, and turns blind fire on. The mission's start (`0x004934F0`) then fits the
player's ship by its type: every ship carries an ECM; the Nagi, the Crusader, the Tempest and the
Shroud carry spectral shields; the Predator, the Coyote, the Patriot, the Reaper, the Shroud and the
Phoenix carry blind fire, which starts on; a ship whose model can cloak (header flag 2) carries a
cloak. Ship types `0xF4` to `0xFF`, whose models are the first twelve's `t_` twins, count as the
same twelve. The same switch picks the cockpit's frame model ([`main.zig`](../../src/engine/game/main.zig)).

`frame_controls` reads the device keys after the camera's and the targeting keys
(`hud_target_keys`, `0x0048B6B0`, where SMART TARGET flips `smart_targeting`):

- TOGGLE BLINDFIRE flips `blind_fire` on a ship that carries it, and Betty says which.
- ECM turns the ECM the other way from the object's flag `0x4000000` through `player_ecm_set`
  (`0x00415370`), which sets the flag and `ecm_state`.
- SPECTRAL SHIELDS, outside a multiplayer game, does the same through
  `player_spectral_shields_set` (`0x00415430`) and flag `0x8000000`. Turning the shields on also
  tunes them, into the object's `+0x670`, to the gun type most dangerous near the ship: it counts
  the guns of each hostile ship in range, weights each type's count by its first damage value, and
  takes the highest, leaving out types 13 and 14. Betty says which.
- CLOAK SHIP is read by `player_controls`; `player_cloak_set` (`0x004153E0`) cloaks or uncloaks the
  ship through `object_set_cloak`, which sets `cloak_state` for the player.

SMART TARGET, ECM and SPECTRAL SHIELDS play `hud_beep` (`0x0048CE70`) 4 turning a device on and 5
turning it off: sample 15 + n of `bank_stdsmp`, in the four cockpit views only.

Ported: the charges, the fitting, SMART TARGET, TOGGLE BLINDFIRE, ECM and SPECTRAL SHIELDS
([`input.zig`](../../src/engine/input.zig)). Not yet: the sounds and Betty, the tuning of the spectral
shields, and the cloak (`cloak.cpp`), so the cloak's light shows its charge full.

## The jump prompt, the eject marker and the scanner

The block for the view ahead draws three more shapes about the middle of the screen, each placed
half of the way across and down:

- `hud_jump_prompt` (`0x00482FA0`), at an offset of `(-16, -90)`: while `warp_ready`
  (`0x0052A3F4`) says a warp is ready, the warp icon `0xC9` flashes; otherwise while `jump_ready`
  (`0x0052A3F0`) says a jump is, the jump icon `0xCE`. The mission sets one to 1; the prompt's
  first frame starts its flash and sets it to 2, drawing nothing; then it flashes for 50 ticks of
  every 100. JUMP DRIVE (`player_jump`, `0x00412B20`) clears it and posts `player_ready_to_jump`
  or `player_ready_to_warp`.
- `hud_eject_marker` (`0x004830B0`), at `(-16, -100)` and `0x26` lower: once the player has ejected
  (`player_ejected`, `0x00579986`, which `order_eject_player_init` sets) or while icon 5 is lit, shape
  `0xC2`, the pilot rising out of the ship, flashes for 50 ticks of every 100.
- `hud_scanner` (`0x00489250`), at `(-16, -100)`: while the `Scanner` mission command
  (`cmd_Scanner`) has `scanner_object` (`0x0057E060`) name an object, shapes `0xD1` to `0xD5`, a hand
  and the rings it sends out, in turn, moving on once `game_ticks` is past a tick 25 on from the
  last move. `mission_frame` beeps meanwhile at an interval of 10 to 200 ticks that it works out
  from the object's distance and bearing.

The port draws all three; the sandbox runs no mission, so none of them shows there.

## Art

`hud_init` loads the display's shapes into `hud_shapes` (`0x005656A8`): `hudhard.spr` under the
hardware renderers and `hudsoft.spr` under the software one, which `sr + 0x1AC` picks, and
`dmicons.spr` or `soft_dmicons.spr` into `0x0057BC3C`. `HUDHARD.SPR` holds 388 shapes, 2 palettes and
21 remap tables: radar rings, bar gauges, arcs, target boxes, ammunition, and the silhouettes the
target display shows. `hud_init` hands `VFX_shape_multilookaside` 29 tables of 256 bytes from the
start of block 0, where the remap tables begin, though the set holds 21. In a multiplayer game
`hud_draw` draws a shape of `dmicons.spr` at the middle of the screen for the player's `+0x754`,
flashing for the first 100 ticks after `+0x760` and gone once `frame_start` passes `+0x75C`.
**Unknown:** what the three fields are.

A shape's entry in its set names a palette or none (`VFX_shape_draw` in `winvfx16.dll`); one with
none is drawn with VFX's global palette. Under the hardware renderers `hud_draw` makes that of
block `0x77` of the display's set, its first palette, every frame (`palette_to_vfx`,
`0x00428410`), at `hud_brightness` (`0x00569718`), which `hud_init` sets to 1 and nothing changes.
No entry of a shipped set names a palette ([`spr.md`](../formats/spr.md)), so every shape of the
display is drawn with block `0x77`'s palette, those after the set's second palette, block 247,
included, and the ships' schematics, whose sets carry none, too. Nothing in the display makes
another block the global palette. The port does the same.

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
- What sets byte `0x2F` of a fight state, which lights the enemy lock warning.
- The names of the display's elements, which `hud_init` copies from `0x00515D70`.
- What the rest of `hud_draw` draws: the target display, the armour, the targeting cluster's
  indicators for the nav point and the target, and what `0x00489C70`, which the view ahead calls
  before the eject marker, draws.
- What the object's `+0x148` is, which the Phoenix's charge arc shows for a gun of type 11, and
  why blind fire leaves guns of that type alone.
- What sets `0x0057BF34`, whose string view `0xD` shows, and `0x00529FB8`, which shows a line at
  the foot in every view.
- What the flags at `0x00563160` mark, which flash parts of the ship status schematic.
- Which of the display's shapes `hud_blit` shakes by `hit_shake` rather than `hud_interference`.
- What `hud_palette_ramp` (`0x0048D590`) colours, and whether the display's text takes its palette
  from it rather than from the font.
- What the player's `+0x754`, `+0x75C` and `+0x760` are, which pick and time the `dmicons.spr`
  shape of a multiplayer game.
- How the display reaches the screen in the game, which is `vfx.dll`'s panes rather than anything
  in the payload.
