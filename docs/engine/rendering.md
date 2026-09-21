# Rendering

How the hardware renderer draws models. Surrender's library in the payload culls, projects and
lights each mesh; its Direct3D 7 driver, `srd3d.dll`, turns materials into render states and draws.
The software renderer, `srddraw.dll`, is not covered here.

[`src/engine/game/srofiles.zig`](../../src/engine/game/srofiles.zig) states the rule from shading to
material; [`src/engine/surrender/srd3d/srd3d.zig`](../../src/engine/surrender/srd3d/srd3d.zig) the
driver's blend factors, depth rule and highlight textures.

## Frame

`sr_render` (`0x004C78A0`) draws a frame through `sr_draw_layers` (`0x004C7960`):

1. The driver clears to black and to depth 0, and begins the scene.
2. For each layer in turn, each object in the layer's list goes through the payload's pipeline for
   its type, then to the driver. Opaque groups are drawn at once; blended ones are deferred.
3. The layer's deferred polygons are sorted farthest first (`depth_sort`, `0x004C7B30`) and drawn:
   every first pass, then the second passes.
4. The scene ends.

| Layer | Depth test | Depth writes |
|---|---|---|
| 0 | Off | Off |
| 1 | On | Opaque passes only |
| 2 | Off | Off |

Depth is reversed: a vertex's depth is `sqrt(1 / z)`, scaled, with `z` its distance along the
view; the test passes on greater or equal, and the buffer clears to 0. The driver culls nothing.

| Object type | Pipeline |
|---|---|
| 1, a mesh | `SR_meshpipe_init` (`0x004C75C0`) |
| 4, a set of sprites | `SR_bmopipe_init` (`0x004CE4D0`) |
| 7, a star field | `stars_project` (`0x004C5380`) |

**Unknown:** types 5 and 6 (`0x004CE830`, `0x004CE7B0`).

The device's render states are set once, with the display mode (`D3D_set_screen_mode`,
`0x10004840`, or `D3D_set_screen_mode_windowed`, `0x10003C20`); afterwards the driver changes only
the depth states and the blending. Anti-aliasing, of the scene or of edges, is off, and no setting
turns it on. Dithering is on, textures are perspective-correct, and there is no alpha test and no
fog.

## Meshes

`mesh_build` (`0x004A3040`) makes a part's mesh for each level of detail as `model_load`
(`0x004A44D0`) loads the model:

- A run of consecutive faces with the same mode, sub-mode and material is a group, with a material
  of its own. A mesh holds up to 20 groups; a level with more stops the game.
- A fan's records become one polygon when `fan_merges` (`0x004A2FD0`) finds each later record's
  normal within a dot product of 0.999 of the first's: the first record's corners, then each later
  record's last. Other records stay polygons of three corners, keeping their fan or strip encoding
  and the count of records still to come, by which the driver draws them together.
- A mode-1 face becomes a polygon of two corners, a line, for each edge its edge mask leaves unset,
  each with the face's plane. It counts one polygon more than it makes; the spare polygons stay
  empty, in no group, and count only toward the frame's limit.
- Every other polygon's plane is that of its first three corners (`SR_mesh_calc_poly_normals`,
  `0x004C3CA0`). A polygon keeps its face's `0x01` and `0x02` flags and a third of its sort bias.
- Texture coordinates are per corner. On a part flagged `0x80`, with `Lmaps` on, the second pass
  takes the first's.
- Each material that a face of mode 3 or above uses has its texture looked up by name
  (`texture_require`, `0x00494A30`): after `g` while the loadout screen loads the ships, after `r`
  while it loads the missiles and guns, and as it is in flight. The light map is `l` and the name.
  A name the cache lacks stops the game.
- The bounding box, and the radius, the farthest vertex's distance from the origin, come from the
  vertices (`SR_mesh_find_bounding_box`, `0x004C3F10`). `mesh_texel_areas` (`0x004C4090`) finds
  each textured polygon's area in texels, which only the software driver reads.

At the finest level, the faces the part's tree nodes and face groups list are renumbered to the
polygons that merging leaves.

The part's object gathers flags from the meshes of its levels:

| Flag | When |
|---|---|
| `0x100` lit, `0x8000` hides the sun | Always |
| `0x400` coordinates from the normals for the second pass | A face of mode 7 or 8, with `Lmaps` on |
| `0x10000` geomorph positions, `0x20000` geomorph normals | Part flags `0x20` and `0x10`: every level but the last also holds each vertex's counterpart in the next |
| `0x40000` baked colours | Part flag `0x40`: the mesh holds a colour for each vertex |
| `0x80000` colours of its own | The model's header flag `0x02`, or a ship type's model while `multiplayer_mission` (`0x00582E8C`) is set |

For those last models `model_load` also builds a second set of meshes, whose groups' first passes
blend by alpha, and a third, one group textured by coordinates from the normals and added
(`cloak_mesh_build`, `0x004A3CB0`), for the cloak effect. **Unverified:** that
`multiplayer_mission` marks the multiplayer maps; missions 81 to 85 and 87 set it.

The material is 16 bytes (`Material` in
[`srapiext.zig`](../../src/engine/surrender/surrenderlib/srapiext.zig)):

| Off | Field |
|---|---|
| `0x00` | `1` when a second pass is drawn over the first |
| `0x02` | Texture coordinates, per pass: `0` none, `1` the mesh's, `2` from the normals |
| `0x04` | Lit, per pass: coloured by the vertex lighting, else by white |
| `0x06` | Blend, per pass |
| `0x08` | Texture, per pass. Below 8, one of the driver's highlight textures |

## Shading modes

A face's mode, the low nibble of its shading (see [`.SHP`](../formats/shp.md#face-tag-0x03)), gives
its material:

| Mode | Texture | Lit | Blend | Second pass |
|---|---|---|---|---|
| `0` | None | Yes | Off | |
| `1` | None, as lines | Yes | Off | |
| `2` | None | Yes | Add | |
| `3` | Material | No | Off | |
| `4` | Material | No | Add | |
| `5` | Material | No | Alpha | |
| `6` | Material | Yes | Off | Light map |
| `7` | Material | Yes | Off | Highlight |
| `8`, `10` | Material | Yes | Add | |

Other modes leave the material zero: untextured, unlit, opaque. A mode-1 face becomes a line for
each edge its edge mask leaves unset.

The second passes need `Lmaps`, in the settings' `Device` section, to be 1, as it is by default
(`light_maps`, `0x005D5618`):

- **Light map**, on parts flagged `0x80` and on the hardware renderers only: the texture named `l`
  and the material's name, by the mesh's coordinates, unlit, added.
- **Highlight**: highlight texture *n*, *n* the face's sub-mode, 0 to 7, by coordinates from the
  normals, lit, added.

## Passes

A textured pass's colour and alpha are the texture's times the vertex colour's; an untextured
pass's are the vertex colour's. An unlit pass's vertex colour is white.

| Blend | Source factor | Destination factor |
|---|---|---|
| `0` off | Blending off | |
| `1` add | One | One |
| `2` premultiplied | One | One minus source alpha |
| `3` alpha | Source alpha | One minus source alpha |
| `4` add alpha | Source alpha | One |

On two card types the driver makes `2`'s destination factor, or `4`'s source factor, one.

When the device can, the driver draws both passes at once, to the same effect. Textures are sampled
bilinearly from the nearest mip level, and wrap.

A blended polygon's sort key is the mean depth of its vertices along the view, plus a third of its
face's sort bias (`0x40` in the face record).

## Culling

The payload drops the polygons facing away (`mesh_cull`, `0x004C6280`). A polygon faces the camera
when the camera lies on the side of its plane its normal points to; the normal is
`(v1 - v0) x (v2 - v0)`, or `(v2 - v0) x (v1 - v0)` for an odd strip member, in the model's frame. A
line keeps its face's plane.

Face flags, where the mesh has any, are tested against the object's face mask, all ones from
creation:

| Flag | With the mask's bit set |
|---|---|
| `0x01` | Hidden. The fighters close their body and cockpit where the two parts meet with such faces |
| `0x02` | Never culled |

An object with flag `0x800` is not culled.

## Lighting

Colours are per vertex (`mesh_light`, `0x004C7060`), then interpolated across each polygon. A
vertex's colour is the sum, each channel then clamped to 1, of:

1. The object's own colour, and each ambient light's colour times its intensity.
2. The part's baked colours, where it has them.
3. Each point light within reach (`SR_mesh_pointlight`, `0x004CDE40`): its colour times its
   intensity, the cosine between the normal and the direction to the light, and `(1 - r / R)^2`,
   with `r` the distance and `R` the light's intensity times its range (light `+0xCC`).
4. Each directional light (`SR_mesh_dirlight`, `0x004CE120`): its colour times its intensity and the
   normal's dot product with the light's forward axis, where that is positive.

Point and directional lights add no alpha. A light reaches an object unless their light masks
share a bit; an object whose mask is all ones takes no lights.

## Static lights

A model carries its own lights as attachments, and the loader bakes them into vertex colours once
rather than lighting them each frame. An attachment counts as one while its kind is `light`, its
brightness is above zero and it does not blink, which is both of its blink values being zero
(`static_lights_mark`, `0x004A4070`). Its `id` is its colour: 0 blue, 1 green, 2 yellow, 3 red, and
nothing at all beyond, so a light of any further id adds no colour.

Parts fall into two classes by their `damaged` flag, and a light shines only on the parts of its
own class, so a component's damaged model is lit separately from its intact one. Every part of a
class that holds a light takes baked colours for all of its levels, which is what the part flag
`has_static_light` marks (`static_lights_bake`, `0x004A4310`).

Drawing a light is another matter, and `node_draw` (`0x0049A8C0`) takes more ids than the baking
does: 0 blue, 1 green, 2 yellow, 3 red, 4 cyan and 5 white, each with a paler colour for the sprite
than for the light it casts. A light of id 4 or 5 is therefore drawn in its own colour but bakes
nothing, since the baking knows only the first four. A light blinks by its two blink values, the
first how long it stays on and the second how long it stays off, from a start its `blink_phase`
sets, and fades over 200 ticks at each end; the light it casts is cut once that fade takes it below
0.9, while its sprite keeps fading.

Each light adds to a vertex what a point light would (`static_light_bake`, `0x004A4130`): its
colour times its brightness, the cosine between the vertex's normal and the direction to the light,
and `(1 - r / R)^2`, with `R` the brightness times the range. So a vertex at the light's own reach
takes nothing, and the colour stops at white. The radius is the same `R` the point lights above
use, and the falloff the same shape, applied once at load instead of every frame.

## Sprites

A set of sprites (`sprite_set_create`, `0x004C4DB0`) shares one material. Each sprite has a centre,
a half width and a half height, a colour, and texture coordinates 0 to 1 across and down; its
pipeline draws it facing the camera, reaching its half size to either side of its centre.

## Coordinates from the normals

For a pass whose coordinates come from the normals (`mesh_sphere_map`, `0x004C7360`), with `n` the
vertex normal turned into the camera's frame: `u = 0.5 + 0.5 * n.x`, `v = 0.5 + 0.5 * n.y`.

## Highlight textures

The driver makes eight 64x64 grey textures at start-up (`make_highlight`, `0x10001620`), brightest at
the centre. For texel `(x, y)`, with `d` its distance from the centre in half-widths, the vector
`((2x - 64) / 64, (2y - 64) / 64)`, and `e` 1.01, 2.01, 5.01 or 10.01 for index 0 to 3:

- `I = ((P * (1 - d))^e + 0.4) / 1.4` inside the circle, `0.4 / 1.4` outside it, where
  `P = (e + 1)^(1 / e)`;
- `v = 200 * I`, rounded; for indices 4 to 7, those of 0 to 3 times seven tenths;
- grey `(v - 200) / 3`, alpha `3 * v / 2`, each clamped to 0 to 255.

The highlight pass is added, so only the grey shows.
