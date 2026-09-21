# `.fat` sound banks

A sound bank packs RIFF/WAVE files into one file. `resource.hog` holds most of them; `CD1.HOG` and
`CD2.HOG` each add `VRSFX.FAT` and `VRSND.FAT`, and a copy of `wlksmp.fat` identical to
`resource.hog`'s.

```bash
sltool fat ls <bank>                  # every sound: offset, size, priority, format, length
sltool fat extract <bank> <out-dir>   # every sound as a WAV file
make sounds                           # every sound in resource.hog into game/sounds
```

## Layout

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | `2.00`, four raw bytes |
| 4 | 4 | Sound count |
| 8 | 12 x count | Entries |

| Offset | Field |
|---|---|
| 0 | Offset of the sound from the start of the bank |
| 4 | Size |
| 8 | Priority |

The sounds follow the entries back to back, to the end of the file, and each is a complete WAVE
file whose RIFF length matches its entry's size. All but one are IMA ADPCM (format `0x11`, 4 bits per
sample, with a `fact` chunk giving the length) at 11,025, 22,050 or 44,100 Hz, mono or stereo; the
other is 16-bit PCM. `sltool fat extract` writes them unchanged.

## Playback

The engine reads a whole bank into memory with its generic file loader, `hog_read_file`
(`0x004C7F60`), and plays sound `n` of it with `sound_play` (`0x00481F80`), which passes Miles the
WAVE file at `bank + offset`. The priority decides whether a sound may take over a voice already
playing: the player finds the busy voice of lowest priority and stops it only for a sound whose
priority is higher, then records the new sound's priority on the voice (`SoundVoice` in
[`src/lancer/sound.zig`](../../src/lancer/sound.zig)).

The shipped banks use priorities 1, 5, 50 and 10000. Most hold a single sound: those named for the
flyable fighters, such as `PREDATOR.FAT`, each hold one at priority 10000. `betty.fat` holds the
cockpit warnings.

The payload loads `stdsmp.fat`, `ldsmp.fat`, `smp3d.fat`, `betty.fat`, `newsloop.fat`,
`waitloop.fat`, `wlksmp.fat`, `vrsfx.fat`, `vrsnd.fat` and `inter\itac\itacsnd.fat` by name.
