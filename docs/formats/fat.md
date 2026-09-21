# `.fat` sound banks

A sound bank packs RIFF/WAVE files into one file. `resource.hog` holds 34 banks with 186 sounds.
`CD1.HOG` and `CD2.HOG` each hold two more, `VRSFX.FAT` (3 sounds) and `VRSND.FAT` (6), and a copy
of `wlksmp.fat` identical to `resource.hog`'s.

```bash
sltool fat ls <bank>                  # every sound: offset, size, priority, format, length
sltool fat extract <bank> <out-dir>   # every sound as a WAV file
make sounds                           # resource.hog's 186 into game/sounds
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
file whose RIFF length matches its entry's size. 185 are IMA ADPCM (format `0x11`, 4 bits per
sample, with a `fact` chunk giving the length) at 11,025, 22,050 or 44,100 Hz, mono or stereo; one
is 16-bit PCM. `sltool fat extract` writes them unchanged.

## Playback

The engine reads a whole bank into memory with its generic file loader, `FUN_004C7F60`, and plays
sound `n` of it with `FUN_00481F80`, which passes Miles the WAVE file at `bank + offset`. The
priority decides whether a sound may take over a voice already playing: the player finds the busy
voice of lowest priority and stops it only for a sound whose priority is higher, then records the
new sound's priority on the voice.

| Priority | Sounds |
|---|---|
| 1 | 169 |
| 5 | 1 |
| 50 | 2 |
| 10000 | 14 |

27 banks hold one sound. The twelve named for the flyable fighters, such as `PREDATOR.FAT`, hold one
each at priority 10000; `smp3d.fat` holds 77, and `betty.fat` 22 cockpit warnings.

The payload loads `stdsmp.fat`, `ldsmp.fat`, `smp3d.fat`, `betty.fat`, `newsloop.fat`,
`waitloop.fat`, `wlksmp.fat`, `vrsfx.fat`, `vrsnd.fat` and `inter\itac\itacsnd.fat` by name.
