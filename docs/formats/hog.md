# `.HOG` archives

The game's assets live in `.HOG` files, which use Electronic Arts' **`BIGF`** container. A 16-byte
header is followed by a directory, then the members packed back to back with no padding and no
alignment.

Every integer in the container is **big-endian**.

```bash
sltool hog info <archive>              # size, member count, how much is compressed
sltool hog ls <archive>                # offset, stored size, real size, name
sltool hog extract <archive> <dir>     # decompressing by default; --raw to keep members as stored
make assets                            # extract resource.hog and pilots.hog into game/assets
```

## Header

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | `BIGF` |
| 4 | 4 | Total archive size, which equals the file's own size in every shipped archive |
| 8 | 4 | Entry count |
| 12 | 4 | Offset where the directory ends and the first member begins |

## Directory

Entries follow the header at offset 16, packed with no alignment:

| Size | Field |
|---|---|
| 4 | Member offset from the start of the file |
| 4 | Member size as stored, which is the compressed size for a compressed member |
| n+1 | Name, NUL-terminated |

Entries are variable-length, so the directory can only be read by walking it; there is no index.

Names form a flat namespace with no directories and no path separators, and are not normalised:

- **Case is inconsistent.** `interpal.TGA` and `interpal.tga` are different members of
  `resource.hog`.
- **Names may contain spaces**, for example `Boridin gun dest.SHP`.
- **Names are not unique.** Some names in `resource.hog` appear twice, and the two members are
  usually different sizes, so they are different assets rather than redundant copies. `sltool hog extract` gives the later member a `~2` suffix before
  its extension so nothing is lost, including where two names differ only by case and would
  collide on a case-insensitive filesystem.

### Trailing filler

Two of the five shipped archives, `msspeech.hog` and `pilots.hog`, count one more entry in their
header than their directory holds.

The extra record is `0xCD` filler, the pattern MSVC writes over uninitialized memory, and it sits
past the end of the real directory. The members themselves are unaffected: in every archive they
form one contiguous run from the header's data offset to the last byte of the file, with no gaps. A reader should validate each entry and stop at the first one that is not a plausible
record, rather than trusting the count.

## The shipped archives

| Archive | Compressed | Contents |
|---|---|---|
| `resource.hog` | Almost every member | Models, sprites, images, missions, stat tables, sound banks, fonts |
| `pilots.hog` | No | `.fm8` pilot files |
| `msspeech.hog` | No | Speech, one member per line, no extensions |
| `CD1.HOG` | A few members | Bink video, MP3 music, sprites |
| `CD2.HOG` | No | Bink video, MP3 music, sprites |

`resource.hog`'s members by extension: `.shp` models, `.spr` sprites, `.tga` images, `.dte`
missions, `.fat` [sound banks](fat.md), `.fnt` [fonts](fnt.md), `.ccb` colour tables, and five `.bin` files:
the four stat tables and `profile.bin`.

## RefPack compression

Compressed members begin with `10 FB` and are decompressed transparently by `sltool hog extract`.
The codec is EA's **RefPack**, also called QFS, and named FB10 after those two bytes. See
[`refpack.md`](refpack.md).

Compression is per member, not per archive, and is a property of the archive rather than of the
file type: the same extensions appear compressed in `resource.hog` and uncompressed on the discs.
