# Effects

What the game shows besides its objects and their shots: for now, the particles, fireballs and
burning bits of an explosion. [Destruction](objects.md#destruction) covers when a ship blows up.

## Particles

`particles.cpp` keeps particles: sprites that fly off an emitter and change size and colour over
their life. `particles_init` (`0x0049BF60`) makes the only pool the game fills (`particle_pool`,
`0x0058A94C`) of the ten `particle_pools` (`0x0058A948`) has room for: 1000 particles over
`gunflare\partic4`, drawn as one set of sprites that take their own texture coordinates, are
coloured by their own colour and add to what is behind them. A particle is a record of 0x18 bytes,
its birth and life in ticks, its velocity a tick and its template, and the sprite of the same index.
It is free once its birth plus its life is before the frame.

A template (`particle_template_create`, `0x0049C5D0`, 0x50 bytes) says how its particles live:

| Offset | What |
|---|---|
| `0x00` | Its kind: 0 particles; 1 particles and, one time in 200, a spark; 2 sparks |
| `0x04` | How long a particle lives, in ticks |
| `0x08` | Up to how many more at random, `rand() % spread` |
| `0x0C` | The rate an emitter streams at over its own life, in particles a tick in hundredths |
| `0x18` | A particle's half-size over its life |
| `0x24`, `0x30`, `0x3C` | Its red, green and blue over its life, each held within 0 to 1 |
| `0x48` | The pool |
| `0x4C` | How far a burst thins with distance: 1 unless set; none at 0 |

Each curve is a quadratic `a t² + b t + c`, `t` running from 0 at the particle's birth to 1 at its
end, that `particle_curve_set` (`0x0049C180`) puts through a start, a middle and an end value at 0,
0.5 and 1.

An emitter (`particle_emitter_create`, `0x0049C600`, 0xFC bytes) holds its life and birth, a
Surrender frame of its own at `+0x08` that it can hang off another, then how its particles leave:
along a direction (`0xBC`), strayed by up to half its spread either way on each axis (`0xC8`), at
its speed and up to its speed's range more (`0xD4`, `0xD8`) a tick, turned into the world, plus a
velocity they inherit (`0xDC`); and the span of the texture they show (`0xE8`).

- `particle_emit` (`0x0049C1C0`) gives one particle its life, velocity and template, and puts its
  sprite where the emitter stands.
- `particle_burst` (`0x0049C450`) sends a number of them out at once, into the free particles. Half
  as many go where the emitter stands behind the camera, and the rest are thinned by their
  template's half-size halfway through its life times 150, over their distance times the template's
  `0x4C`, which takes all of them at most.
- `particle_stream` (`0x0049C680`) sends particles out over the emitter's own life: each tick of the
  frame, one goes with the chance the template's rate gives at that point, thinned as a burst is but
  by the distance alone, and each moves on at once as if it had left at the frame's start. It
  returns 0 once the emitter's life is over.

`particles_frame` (`0x0049C8E0`), once a frame after the shots, moves each particle alive on by its
velocity times the frame's ticks, sets its sprite's half-size and colour from its template's curves,
and hides the rest; the set is drawn up to its last particle alive, in the world's layer.

An explosion's blast (`explode_blast`, `0x0046C980`) bursts into two templates that `explosions_init`
(`0x0046B240`) makes:

| Template | Life | Half-size | Colour | Burst |
|---|---|---|---|---|
| Flame (`0x00553348`) | 500 to 599 | 0, 100, 400 | yellowish white, orange, nothing | 400, at 200 to 500 a tick, from an emitter turned 60 degrees back from the camera and a random way about its axis, spread across the view; it thins with distance at 0.05 |
| Sparkle (`0x0055334C`) | 100 to 599 | 0, 25, 25 | white, fading out | 150, at up to 7 a tick every way |

Both carry some of the ship's velocity on: a quarter of it to half for the flame, a quarter for the
sparkle. A ship that bursts (`explode_burst`, `0x00471DB0`) sends 200 of the flame at 20 to 25 a
tick, carrying a quarter, and the sparkle carrying half.

[`particles.zig`](../../src/engine/game/particles.zig) ports the pool, templates, emitters and the
frame; [`explode.zig`](../../src/engine/game/explode.zig) the two templates and the bursts. Not
ported: the sparks (`particle_spark`, `0x0049C340`), which it hands to `explode.cpp`
(`0x00471B20`), and what `particles_frame` runs first (`0x004A1BB0`).

## Fireballs

`explosion_fireball` (`0x0046BD00`) sets a fireball off in the first free of the thirty
`explosion_fireballs` (`0x00553398`), and none at all where they are all going off. A fireball is
one sprite, as large either way as it is told and sorted as if it stood that much nearer, that plays
an animation where it was set off:

| Kind | Frames |
|---|---|
| 0, the bang | The sixteen textures `explosion\bang_00000` to `bang_00015` (`explosion_bang_images`), one after another over its life |
| 1, the sheet | The nine cells of `explosion\explosion sheet` (`explosion_sheet_image`), three across and three down, 82 texels apart and 81 across, mirrored left for right and top for bottom by two random bits |

It is blended over what is behind it by its texture's alpha. It waits out a delay before it shows,
drifts at a velocity a tick, and plays for its life, 150 ticks from every caller here. A fireball
told it is lit is coloured by how far it has played, from black to white. One with a light carries
a point light coloured (1, 0.5, 0.1) that starts at intensity 10 and fades to nothing as it plays,
reaching 50 times the square root of its size. `explosions_update` (`0x0046E480`) plays each one on
once a frame and frees it once it is done.

| Who | Where | Size | Light | Delay | Drift |
|---|---|---|---|---|---|
| A blast (`explode_blast`) | At the ship | Its radius | Yes | None | A quarter of the ship's velocity |
| A burst (`explode_burst`), 18 of them | Within 0.3 of the radius, a random way | 0.8 of the radius | Yes | Up to 9 ticks | Half of it |
| A spin-out and a halt, as they begin | At the ship | Its radius | No | None | None |
| A halting torpedo, 5 more | Within 750 each way | 1000 to 1500 | Yes | 30 ticks apart, and up to 19 later | None |

[`explode.zig`](../../src/engine/game/explode.zig) ports the fireballs as `Explosions.setOff` and
`Fireball`, and [`aiexplode.zig`](../../src/engine/game/aiexplode.zig) the spin-out's, the halt's
and the torpedo's. Not ported: a special fireball's own texture (`0x00562CCC`), which none of these
sets off, and the rest of `explosions_update`.

## Burning bits

`explosion_bit` (`0x004717D0`) throws a small lit mesh out of an explosion into the next of
`explosion_bits` (`0x005538C8`), in place of whatever flew there. The options' detail sets how many
fly at once: 100, 300 or 500 at low, medium and high. The port starts at high.

A bit is a piece of debris, one of the ten models of types `0x4E` to `0x57`, which
`explosions_init` loads through `ship_type_first_levels` (`0x004AE190`) and draws half as far again
before a coarser level. The piece goes by one number `r` from 0 to 1: the first below a quarter, the
last below a half, and above that the second to the tenth, `1 + (r - 0.5) × 16`. Its scale is half
to one and a half times the throw's size. It leaves along its direction at 1500 to 4500 a second,
strayed up to a quarter of a radian about each axis, times the throw's speed; it turns up to 0.05
radians a frame about each axis; and it flies for 1750 to 2250 ticks. `explosions_update` moves each
bit on by its velocity times the ticks since the last frame, over 100, turns it once, and lets it go
once its life is over.

| Who | Bits | Direction | Size | Speed |
|---|---|---|---|---|
| A blast | 25 | Every way | 0.4 | 0.2 |
| A blast of an escape pod, a proximity mine or a ship its pilot left | 5 | Every way | 0.2 | 0.1 |
| A burst | 25 | Every way | 0.2 | 0.2 |
| A spin-out, each frame while fewer ticks are left than ten times its trail, from 50 | 1 | Backwards, from within 250 of the ship each way | 0.1 | 1 |

A ship with flag 24 set leaves only every other bit of its trail. The game can also throw a body
(types `0x58` to `0x5B`) by a chance, or a rock chunk (types `0xB2` to `0xB6`), which none of these
asks for.

[`explode.zig`](../../src/engine/game/explode.zig) ports the bits as `Explosions.throwBit` and
`Bit`, and [`aiexplode.zig`](../../src/engine/game/aiexplode.zig) the spin-out's trail. The port
throws debris only, and leaves a piece out where the game has no model for it.
