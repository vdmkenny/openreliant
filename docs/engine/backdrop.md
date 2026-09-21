# Backdrop

What lies behind a mission, as the hardware renderers draw it. Everything is centred on the camera
and drawn on the background layer, except the lens flares, which go on the overlay layer
([Rendering](rendering.md#frame)).

| Element | From | Drawn |
|---|---|---|
| Sky dome | `starref12.tga` | Untextured, opaque |
| Nebula | `neb01` to `neb07` | Textured, unlit, added |
| Stars | `space.tga` | Points and streaks, added |
| Dust | Random | Points and streaks, added |
| Sun | `sunlayer1` to `sunlayer3` | Sprites, added |
| Lens flares | `sunflare1` to `sunflare4` | Sprites, added |

`backdrop_create` (`0x004A4E70`) and `nebula_create` (`0x00498B30`) build them at start-up;
`backdrop_frame` (`0x004A5CD0`) and `nebula_frame` (`0x00498E10`) add them to the scene each frame.
The dome is the one opaque object, so it is drawn first and the rest add over it.
[`src/lancer/game/backdrop.zig`](../../src/lancer/game/backdrop.zig) and
[`nebula.zig`](../../src/lancer/game/nebula.zig) state the geometry and tables below.

## Sky dome

A band of 15 by 8 vertices around the camera (`nebula_dome`, `0x00498810`). For column `c` and row
`r`, with `u = c / 14` and `v = r / 7`:

- position: `(sin 2πu, 5 * (v - 0.5), cos 2πu)`, scaled to a length of 5000, so the band stops about
  22 degrees short of either pole;
- colour: the pixel of `starref12.tga` at `(255u, 255v)`, rounded down, top row first, over 256.

No light reaches it. `backdrop_place` turns it with the sun marker. The software renderer builds a
different dome.

## Nebula

A patch of 11 by 11 vertices on a sphere of radius 5000 (`sky_patch_create`, `0x00498EA0`), 90
degrees across each way, or 72 for nebula 5, with the texture across it once. Across the columns a
vertex turns evenly from -45 to 45 degrees about `X`, down the rows about `Y`; `u = c / 10`,
`v = r / 10`. Its orientation is the nebula marker's, or a yaw of -90 degrees without one.

A script picks the nebula with `SetEnvironmentFXNebula` (0 to 6), which takes effect at the next jump
or on `UpdateEnvironmentFXState` (`nebula_select`, `0x00498D00`). Each nebula also colours the fill
lights:

| Nebula | Texture | Fill light |
|---|---|---|
| 0 | `neb01` | 0.24, 0.5, 1 |
| 1 | `neb02` | 0, 1, 0.8 |
| 2 | `neb03` | 0.33, 0.46, 1 |
| 3 | `neb04` | 0.74, 1, 0.32 |
| 4 | `neb05` | 0, 0.75, 1 |
| 5 | `neb06` | 0.92, 0.66, 0.33 |
| 6 | `neb07` | 0, 1, 1 |

Nebula 0 is shown until a script picks another.

## Stars

`space.tga` is a 360-pixel square map of half the sky, half a degree to a pixel, with a grey star on
black at each pixel that is not black. It is cut into 100 fields of 36 by 36 pixels. Field row `i`,
column `j` is centred on the axis at polar angle `θ = 9 + 18i` degrees from `+Y` and azimuth
`φ = 9 + 18j` degrees from `+X` toward `+Z`:

```
axis = (cos φ sin θ, cos θ, sin φ sin θ)
```

A star at pixel `(x, y)` of its field lies at `(sin a, sin b, 1)` in the field's frame, `a` and `b`
being `x - 18` and `y - 18` half degrees. The field's frame is turned about `Y`, then `X`, to face
the axis (`mat3_look_at`, `0x004C1940`).
The fields cover the half of the sky where `z` is positive; a field behind the camera is drawn
mirrored through it, so they cover the other half too.

Each frame (`stars_project`, `0x004C5380`):

- a field is drawn only while its axis, or its opposite, is within a cosine of 0.6 of the view axis;
- a star is drawn only while its direction is within a cosine of 0.6 of the view axis this frame and
  last, and of 0.7 in one of them;
- a star moving more than a pixel since last frame is a line back to where it was, the tail at half
  brightness, cut to 0.1 view units (position over depth, before the viewport's scale); otherwise a
  point;
- its brightness is `1 / (100m + 1)`, `m` its motion in view units, `|dx| + |dy|`.

After a camera cut, `backdrop_reset_streaks` (`0x004A5C80`) stops the next frame drawing streaks.

## Dust

200 motes at random in a cube of side 8191, grey at half brightness. They are fixed in the world,
repeating every 8192 units: each frame a mote is placed within 4096 of the camera on each axis. Its
brightness is `16 * (0.25 - d² / 8191²) / (100m + 1)`, clamped to 0 to 1, with `d` its distance, so
motes fade out by 4096 away. They streak like stars.

## Sun and lens flares

The sun's direction comes from the sun marker's orientation, or is `(1, -0.5, 0.2)`, normalized,
without one. Its three sprites, `sunlayer1` to `sunlayer3`, are drawn there at their textures' sizes
in pixels on a screen 768 pixels tall, times 0.5, 2 and 2: `sunlayer1` always, `sunlayer3` while the
sun's visibility is above 0.5, and `sunlayer2` while the flares' brightness is above 0.

The six flares are drawn on the line through the sun and the middle of the view, at a multiple of
the sun's offset from the middle: `sunflare2` at 0.5, `sunflare1` at 0.33, `sunflare3` at 0.2,
`sunflare2` at -0.2, `sunflare3` at -0.6 and `sunflare4` at -0.5. Their brightness is
`(0.5 + 0.05v) * (1 - min(1, s))`, with `s` the sun's offset from the middle in view units and `v`
its visibility: 10 at most, less near the edges of the screen, and less again for each triangle of
an object flagged `0x8000` that covers the sun's point on screen. **Unknown:** which views show the
flares (`0x00539A34`, `0x00539A9C`).

## Lights

`backdrop_create` makes six lights; `backdrop_place` (`0x004A5A00`) aims the key lights along the
sun and the fill lights along the nebula marker's forward axis, or `(-1, 0.5, 0)` without one.

| Mask | Kind | Intensity | Colour |
|---|---|---|---|
| `0x01` | Key, directional | 1 | 1, 1, 0.8 |
| `0x02` | Fill, directional | 1 | The nebula's; 0, 0.5, 1 at first |
| `0x04` | Ambient | 1 | 0.04, 0.04, 0.04 |
| `0x08` | Key, directional | 1 | 1, 1, 0.8 |
| `0x10` | Fill, directional | 0.7 | The nebula's; 0, 0.5, 1 at first |
| `0x20` | Ambient | 1 | 0.09, 0.09, 0.09 |

A light reaches an object unless their masks share a bit. A part's object has mask `0x18` when its
model lists components and `0x03` otherwise (`node_add_part`), so models that list components take
the full fill light and the rest take it at 0.7; both take the key light and both ambients.

## Environment effects

`SetEnvironmentFX` sets or clears an effect's bit (`environment_effect_set`, `0x00469C60`), applied
at the next jump or on `UpdateEnvironmentFXState`. The table of effects at `0x004FF808` names two,
Ice Field and Planet Bombard, with no handlers: switching them does nothing.
