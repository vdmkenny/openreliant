# Sound in the port

The game's sound code ([Sound](../engine/sound.md)) calls the Miles Sound System; the port calls a
stand-in of its own, [`engine/mss.zig`](../../src/engine/mss.zig), which SDL3 plays. Nothing of
Miles is carried over but what its calls mean.

| Module | In place of |
|---|---|
| [`formats/wave.zig`](../../src/formats/wave.zig) | Miles's reading of WAVE files: 8- and 16-bit PCM and IMA ADPCM, decoded a frame at a time |
| [`engine/mss.zig`](../../src/engine/mss.zig) | `MSS32.DLL`: the digital driver, its samples, 3D samples and streams, and their mix |
| [`engine/mss/voice.zig`](../../src/engine/mss/voice.zig) | Playing one sound: its rate, its loops, and resampling to the output's rate |
| [`engine/mss/positional.zig`](../../src/engine/mss/positional.zig) | The 3D providers the game chooses from |
| [`platform/audio.zig`](../../src/platform/audio.zig) | The wave-out device Miles opened (`AIL_waveOutOpen`) |

## The stand-in

`mss.Driver` holds fixed pools of samples, 3D samples and streams, each handle an index into its
pool, and a call for each `AIL_` function the game makes, named for it. A handle's status is
Miles's: done once finished or never started, playing, or stopped part of the way. Samples, 3D
samples and streams play a WAVE sound from memory the caller keeps, at a rate of their own, as many
times as their loop count says (0 for ever), resampled to the output's rate by linear
interpolation. IMA ADPCM is decoded as it plays, so the game's decompression of its 3D sounds into
PCM (`AIL_decompress_ADPCM`) has nothing to do in the port. A stream's loop block and position, byte
offsets into its data, fall on the start of their ADPCM block.

What Miles made of a volume or a pan, and how its providers placed a sound, is not known here; the
port takes:

- A volume's share of 127 as its gain.
- A pan as a balance: 64 in the middle leaves both ears at full volume, 0 the left alone and 127 the
  right alone.
- A 3D sample as DirectSound3D would have it, which the providers followed: full volume within its
  minimum distance, falling off as the minimum over the distance and no further past its maximum;
  quietened by its cone when it faces away, to its outside volume past the outer angle; and shifted
  in pitch by its velocity along the line to the listener, against a speed of sound of 343 metres a
  second in Miles's units a millisecond. It is panned by how far to the side it lies, with the same
  power in both ears, which places it left and right only.
- A provider of 32 3D samples, which picks the voice classes' third row.

The mix adds everything playing and clips the sum to full scale.

## Output

[`platform/audio.zig`](../../src/platform/audio.zig) opens the default playback device as an SDL
audio stream, in 32-bit float stereo at the device's own rate, which the driver mixes at. SDL asks
for more from its own thread; the driver takes the stream's lock around every call the game makes,
so the two never meet halfway. Where no device opens, the game runs silent.

`openreliant` sets the sound up as `WinMain` does, with 10 voices, the volumes of `[Sound]` in
`starlancer.ini`, `bank_stdsmp` and `smp3d.fat`, and runs the frame's sound once the camera is
placed. The fades step then too, where `tick_timer` steps them on a timer of its own every five
ticks, which comes to the same while frames come faster. The sandbox starts the player's engine
with its ship and plays a piece of music from `music\`, `New_Mission01.wav` unless `--music` names
another or `none`; `--no-sound` runs silent ([Platform](platform.md#running)).

## Improvements

- **Improvement:** `sound_pitch_factor` works a quarter tone's factor out, `2^(n/24)`, where the game
  looks it up in a table of rounded values.

Upgrades to how it sounds, from resampling to surround, are gathered in
[#162](https://github.com/vdmkenny/openreliant/issues/162).

## Not ported

- The radio's speech, its double buffer and the speech volume.
- The CD's own audio.
