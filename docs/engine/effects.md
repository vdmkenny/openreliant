# Effects

What the game shows besides its objects and their shots: for now, the particles an explosion
sends out. [Destruction](objects.md#destruction) covers when a ship blows up.

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
ported: the sparks (`particle_spark`, `0x0049C340`), which are the explosions' burning bits, and what
`particles_frame` runs first (`0x004A1BB0`).
