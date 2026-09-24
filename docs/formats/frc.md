# `.frc` force-feedback effects

The force-feedback effects in the game's `Forces` folder, as the SideWinder Force Feedback SDK's
force editor saved them. The game reads them through the SDK's Visual Force Effects server
(`vfx.dll`, `CLSID_VFX`), which turns each into DirectInput effects. The game reads 13 of the
files and never the rest ([Controls](../engine/controls.md#force-feedback)).

## Layout

A RIFF file of form `FORC`:

| Chunk | Contents |
|---|---|
| `LIST` `INFO` | `INAM`, `ICMT`, `ISFT` and `ICOP`, each a single NUL in the shipped files |
| `trgt` | The GUID of the device the effects were made for, `{04ACE095-1FA8-11D0-AA22-00A0C911F471}` in every shipped file |
| `LIST` `trak` | A `LIST` `efct` for each effect |

Each `efct` holds an `id  ` chunk, the effect's number, which a group names it by, and a `data`
chunk, its record. A pause also has an `impl` chunk of one word, 1. **Unknown:** its meaning.

## The record

Every record starts with 104 bytes:

| Offset | Size | Field |
|---|---|---|
| `0x00` | 4 | 104, the size of these fields |
| `0x04` | 64 | The effect's name, such as `Sine1`, NUL-terminated; the editor left the rest of the buffer as it found it |
| `0x44` | 4 | Kind: 1 a pause, 2 a waveform, 3 a group |
| `0x48` | 4 | Type: a waveform's shape, a group's order, 10 for a pause |
| `0x4C` | 4 | 3 in every shipped file: both axes |
| `0x50` | 4 | Direction, in degrees |
| `0x54` | 4 | 0 in every shipped file. **Unknown** |
| `0x58` | 4 | Duration, in milliseconds. A group's is 1000 whatever its members' |
| `0x5C` | 4 | Gain, in percent |
| `0x60` | 4 | 100 in every shipped file. **Unknown** |
| `0x64` | 4 | 0, or 1 in a few groups and effects. **Unknown** |

The envelope follows, 32 bytes:

| Offset | Size | Field |
|---|---|---|
| `0x00` | 4 | 32, the envelope's size |
| `0x04` | 4 | 0 in every shipped file. **Unknown** |
| `0x08` | 4 | Attack, in percent of the duration |
| `0x0C` | 4 | Sustain, in percent |
| `0x10` | 4 | Decay, in percent |
| `0x14` | 4 | The level at the start of the attack, in percent |
| `0x18` | 4 | The level at the end of the decay |
| `0x1C` | 4 | The level held between them |

A waveform's 20 bytes follow:

| Offset | Size | Field |
|---|---|---|
| `0x00` | 4 | 20 |
| `0x04` | 4 | Frequency, in cycles a second |
| `0x08` | 4 | 100, or 0 for a constant force. **Unknown** |
| `0x0C` | 4 | The highest force, in percent, signed |
| `0x10` | 4 | The lowest force |

A group's 12 bytes follow, then the ids of its members, a word each:

| Offset | Size | Field |
|---|---|---|
| `0x00` | 4 | 12 |
| `0x04` | 4 | How many members |
| `0x08` | 4 | Where the editor held the ids in memory as it saved the file |

A pause has nothing after its envelope.

## Types

| Type | Effect |
|---|---|
| 101 | Constant force, at the highest force |
| 102, 103 | Sine, cosine |
| 104, 105 | Square wave, starting at the lowest force and at the highest |
| 106, 107 | Ramp up and down, once over the whole effect |
| 108, 109 | Triangle wave, rising first and falling first |
| 110, 111 | Sawtooth wave, rising and falling |
| 202 | Sequence: the members one after the other |
| 203 | Superimposition: the members all at once |

Every file holds one effect, or a group with its members. The shipped files use 101 to 110.

## The port

[`src/formats/frc.zig`](../../src/formats/frc.zig) reads a file into its effects.
[`input/force.zig`](../../src/engine/input/force.zig) plays them as rumble.
