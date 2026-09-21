# Reference renderer

[`src/render/`](../../src/render) draws a scene in software by the engine's rules, as the modules
under [`src/lancer/`](../../src/lancer) state them. It is the reference the port's GPU renderer is
checked against: the same scene gives the same image.

`sltool render` draws a model against the backdrop; `make render` draws the Predator toward the
nebula and toward the sun into `game/renders/`.

| Module | Does | Rules from |
|---|---|---|
| `texture.zig` | Textures by name from the texture cache, decoded with a palette; the highlight textures | `tcache`, `srd3d.highlight` |
| `scene.zig` | The camera; a frame's triangles, lines, points and sprites, by layer | |
| `model.zig` | A model's object: parts placed, faces culled, vertices lit, each face's passes | `srmesh`, `srlight`, `srofiles.look`, `objects.lightMask` |
| `backdrop.zig` | The dome, the nebula, the stars and the sun | `nebula`, `backdrop`, `srstars` |
| `raster.zig` | The layers into a colour buffer and a depth buffer | `srd3d.depth`, `srd3d.shade`, `srd3d.blend` |

## Frame

The camera's frame has `x` right, `y` down and `z` forward. A point lies on screen at its position
over its depth, times the view's scale, from the middle.

Each layer is drawn in turn ([Rendering](../engine/rendering.md#frame)): the opaque triangles and
lines as they come, a triangle's second pass straight after its first, then the blended triangles
sorted farthest first, every first pass and then the second passes, then the points and sprites.
Everything the backdrop puts among the points and sprites is added, so their order does not change
the image.

A triangle's colour, alpha and texture coordinates are interpolated in perspective; its depth,
`sqrt(1 / z)`, straight across the screen. Screen positions are kept in sixteenths of a pixel, and a
pixel whose centre lies on an edge belongs to the triangle whose top or left edge it is, so
triangles sharing an edge cover each pixel along it once. Textures are sampled bilinearly, wrapping,
from the mip level nearest to the texels a pixel spans.

## Differences

- Pixel centres lie at half-pixel positions; Direct3D 7 has them at whole ones.
- Polygons and lines are clipped at a depth of 1. **Unknown:** Surrender's own near plane. Points
  and sprites are only kept in front of the camera: the backdrop's lie a unit from it.
- Every star is a point, as for a still camera: there are no streaks.
- Left out: the dust, which the game places at random; baked colours from static lights; the
  objects that cover the sun and lessen its visibility.
- `sltool render` gives the view a quarter turn across its width. **Unknown:** the game's field of
  view.
