# `.SHP` models

Every ship, station, weapon, asteroid and piece of debris in the game is a `.SHP` file in
`resource.hog`. There are 440 of them, holding 1,771 parts, 202,272 vertices and 351,855 faces.

```bash
sltool shp info <model>                 # parts, levels, materials, turret limits
sltool shp chunks <model>               # the raw chunk stream
sltool shp check <model>                # validate indices, parents and bounds
sltool shp obj <model> <out.obj> [--lod n]
make models                             # export all 440 to game/models
make check-models                       # validate all 440
```

## Chunk stream

A model is a flat sequence of chunks with no nesting. Each is a 6-byte header followed by its
records, and the stream ends with a chunk whose tag is `0xFFFF`.

| Offset | Size | Field |
|---|---|---|
| 0 | 2 | Tag |
| 2 | 2 | Record size **in this file** |
| 4 | 2 | Record count |
| 6 | count x size | Records |

All fields are little-endian, unlike the `.HOG` container around them.

`record_size` is the format's versioning mechanism. Older exporters wrote shorter records, and the
loader copies `min(record_size, sizeof(struct))` bytes per record, leaving the rest of the
destination untouched. A reader must do the same; this one zero-fills, so a field a later exporter
added reads as zero in a file written by an earlier one.

The loader locates a chunk by scanning forward from a cursor until the tag matches or the
terminator is reached. A miss leaves the cursor where it was, so a chunk the exporter omitted is
simply skipped and the next request still finds what follows. Chunks must therefore appear in the
order the loader asks for them, because a miss never rewinds.

### Tags

| Tag | Record | Sizes seen *(chunks)* | Belongs to |
|---|---|---|---|
| `0x00` | header | 88 *(386)*, 24 *(25)*, 20 *(29)* | model |
| `0x01` | part | 312 *(277)*, 264 *(128)*, 288 *(29)*, 260 *(1)*, 244 *(5)* | model |
| `0x02` | level of detail | 4 | part |
| `0x03` | face | 80 *(5885)*, 72 *(182)* | level |
| `0x04` | vertex | 32 *(6061)*, 28 *(6)* | level |
| `0x06` | material | 64 | level |
| `0x07` | tree node | 72 *(1413)*, 64 *(358)* | part |
| `0x08` | node face list | 4 | node |
| `0x09` | attachment point | 168 *(1428)*, 124 *(333)*, 136 *(5)*, 100 *(5)* | part |
| `0x0A` | animation clip | 24 *(1591)*, 8 *(180)* | part |
| `0x0B` | keyframe | 28 | clip |
| `0x0C` | clip event | 12 | clip |
| `0x0D` | face group | 4 | part |
| `0x0E` | group entry | 20 | group |
| `0x0F` | trigger polygon | 16 | part |
| `0x10` | tail | 76 *(260)*, 12 *(7)* | model |

### Order

```
header, parts, then for each part:
    levels, nodes, attachments, clips, groups, trigger polygons
    for each level:  vertices, faces, materials
    for each node:   face list
    for each clip:   keyframes, events
    for each group:  entries
tail
```

All 440 models follow this order and end with the terminator at the last byte of the file.

## Records

Offsets below are within a record. Only the fields this project reads are listed; the rest are
noted in [§ Unread fields](#unread-fields).

### Header (tag `0x00`)

| Off | Type | Field |
|---|---|---|
| `0x00` | u32 | Version. `107`, except three models carrying `200`. Not read by the loader. |
| `0x14` | u32 | Flags. Bit 1 makes the loader build a second mesh set, used for the cloak effect. |

### Part (tag `0x01`)

A part is a hull section, cockpit, turret, engine, door or similar. Parts form a tree and each
carries its own levels of detail.

| Off | Type | Field |
|---|---|---|
| `0x00` | char[64] | Name, NUL-terminated: `Crusader Cockpit`, `Rus Big Tur Guns`, `Stalag Door 1 DEST` |
| `0x40` | u32 | Subsystem class. The engine tests for 1 and 6, and treats 3, 9, 10 and 18 as turrets |
| `0x44` | vec3 | Origin, relative to the parent |
| `0x50` | vec3 | Bounding box minimum (see [Bounding boxes](#bounding-boxes)) |
| `0x5C` | vec3 | Bounding box maximum |
| `0x94` | i32 | Parent part index, or `-1` for a root |
| `0x98` | vec3 | A point on the part: the far end of a gun, the base of a mount |
| `0xA4` | f32[9] | Orientation, row-major 3x3 |
| `0xD4` | u32 | Link id. Parts sharing a non-zero id form one assembly, such as a turret and its barrels |
| `0xD8`, `0xE4` | f32 | Yaw minimum and maximum, in degrees, bounding a turret's traverse |
| `0xDC`, `0xE8` | f32 | Pitch minimum and maximum |
| `0xF0` | u32 | Flags (below) |
| `0xF4` | u16 | Turret kind, 0 to 3 |

Part flags at `0xF0`:

| Bit | Meaning |
|---|---|
| `0x02` | Read by the turret tests |
| `0x04` | Splits parts into two classes for static-light baking |
| `0x10` | Geomorph normals: the mesh builder also copies each vertex's next-level normal |
| `0x20` | Geomorph positions, likewise |
| `0x40` | Set by the loader when a static light exists in this part's class |
| `0x80` | On multitexture hardware, bind a second texture named `l<material>` |
| `0x1000` | Propagated to the spawned sub-object |

### Level of detail (tag `0x02`)

One 4-byte record per level, up to nine per part, holding only the distance beyond which the level
applies: `0` for single-level parts, otherwise a rising sequence such as 5000, 10000, 15000. The
geometry follows in the vertex, face and material chunks, in level order.

### Vertex (tag `0x04`)

| Off | Type | Field |
|---|---|---|
| `0x00` | vec3 | Position, in model units |
| `0x0C` | vec3 | Normal |
| `0x1C` | i32 | This vertex's counterpart in the next, coarser level, for geomorphing; `-1` when it has none. Absent from 28-byte records |

### Face (tag `0x03`)

Every record is one triangle.

| Off | Type | Field |
|---|---|---|
| `0x00` | u32 | Material index, into this level's material list |
| `0x04` | u32 | Shading: low nibble is the mode, high nibble a sub-mode |
| `0x0C` | u32[3] | Vertex indices, into this level's vertex list |
| `0x18` | f32[3] | Texture coordinate u, per corner |
| `0x24` | f32[3] | Texture coordinate v, per corner |
| `0x30` | vec3 | Face normal. Not read by the loader |
| `0x44` | u32 | Edge mask for wire shading: edge *k* is drawn unless bit *k* is set |
| `0x48` | u32 | Polygon encoding: `0` plain triangle, `1` member of a fan, `2` or `3` member of a strip |
| `0x4C` | u32 | Records still to come in the same polygon, counting down |

Shading modes: `0` flat, `1` wire, `2` wire shaded, `3` textured, `4` textured with alpha,
`5` textured blended, `6` textured and lit, `7` multitexture, `8` lit with alpha. Mode 6 dominates,
then 7; mode 1 emits line primitives rather than a filled triangle.

Records marked as fan or strip members would be merged by the loader into one larger polygon, but
each record is already a complete triangle of that polygon, so treating every record as its own
triangle renders the same surface. 72-byte records stop before the polygon fields and are always
plain triangles.

### Material (tag `0x06`)

A single NUL-terminated 64-byte texture name without its extension. The engine resolves it through
the image registry with a context-dependent prefix: `g` while the loadout screen preloads ships,
`r` for its missile and gun loops, bare in flight, and a second `l<name>` lookup when the part's
`0x80` flag is set on multitexture hardware.

## Bounding boxes

The box stored in each part is derived from its finest level's vertices, but not always in the
part's own frame. Across all 1,771 parts:

| Relationship to the level-0 vertex extent | Parts |
|---|---|
| Equal as stored | 1,477 |
| Equal after applying the part's orientation matrix | 237 |
| Same box up to an axis swap or reflection the record does not describe | 31 |
| Zero-sized: never filled in | 16 |
| A different box | 10 |

`sltool shp check` classifies each part rather than requiring a match, since all five cases occur
in shipped, working models. The vertices are authoritative; the stored box is a hint.

## Coordinate frame

The model frame is **X lateral, Y down, Z forward**. Neither axis direction is recorded in the
file; both are settled by what the parts are named and where they sit, across all 1,771 parts:

| Test | Result |
|---|---|
| Parts named `Lower`, `bottom`, `under` | 11 of 11 at **positive Y** |
| Parts named `cockpit` or `canopy` | 35 of 48 at **negative Y** |
| Parts named `engine`, `exhaust`, `thruster` | 22 of 26 at **negative Z** |
| Parts named `rear`, `back`, `aft` | 45 of 64 at **negative Z** |
| Parts named `nose`, `front` | 7 of 9 at **positive Z** |
| Parts named `cockpit` or `canopy` | 37 of 48 at **positive Z** |

So `+Y` points at the ship's belly and `+Z` out of its nose. A model loaded without accounting for
this is upside down.

Righting it is a half turn about the forward axis: negate X and Y, keep Z. That keeps the nose on
`+Z`, where a viewer's default camera looks, and does not mirror the model, since negating two axes
keeps the determinant positive. Negating Y alone would mirror it; negating Y and Z would face it away
from the camera.

`sltool shp obj` applies that half turn to positions and normals; `--model-space` writes the
coordinates exactly as the file stores them. `shp info` and `shp check` always report model space.

Wavefront OBJ also numbers texture coordinates from the bottom up, the opposite of this format, so
the exporter emits `1 - v`.

Positions are in model units. The Predator light fighter spans about 1,100 units nose to tail, which
puts a unit near a centimetre (**unverified**: it assumes a fighter about 11 m long). Part positions are relative to the parent, so
placing a part in model space means summing the chain up to the root.

## Unread fields

These are present in every record and read by nothing in the engine: the header's `0x04` scalar and
`0x08` vector, the part's six floats at `0x68` and its `0x80` block, and the face's normal and
`0x3C` word. The reader preserves them.

**Unknown:** the interpretation of tree nodes (`0x07`), attachment points (`0x09`), animation
clips (`0x0A`) and trigger polygons (`0x0F`). They are parsed and counted, and their records are
available, but their fields are not decoded here.

## Prior art

The container and chunk framing here were read from the files directly. The record field
semantics, the loader's search-forward rule and the chunk catalogue come from the independent
analysis in
[Starlancer-OSS `docs/shp-format.md`](https://github.com/LordBlacksun/Starlancer-OSS/blob/main/docs/shp-format.md),
which traced them to the engine's own loader. Every structure offset and count in this document was
re-verified against the 440 shipped models; the bounding-box frames above are a refinement, since
the box does not always match the vertex extent as stored.
