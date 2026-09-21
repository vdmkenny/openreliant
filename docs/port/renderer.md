# Renderer

The port draws with Surrender's own pipeline, ported function by function into the modules of
its original files, and with its Direct3D 7 driver, ported to draw through a device interface in
place of `IDirect3DDevice7`.

| Module | Original | Does |
|---|---|---|
| [`surrenderlib/srcore.zig`](../../src/lancer/surrender/surrenderlib/srcore.zig) | `srCore.cpp` | The scene's lists; a frame, layer by layer; the sort of what the driver puts aside |
| [`surrenderlib/srmesh.zig`](../../src/lancer/surrender/surrenderlib/srmesh.zig) | `srMesh.cpp` | The mesh pipeline: view test, level of detail, culling, projection or clipping, lighting |
| [`surrenderlib/srbmo.zig`](../../src/lancer/surrender/surrenderlib/srbmo.zig) | `srBMO.cpp` | The sprite pipeline |
| [`surrenderlib/srstars.zig`](../../src/lancer/surrender/surrenderlib/srstars.zig) | `srstars.cpp` | The star pipeline |
| [`surrenderlib/srapi.zig`](../../src/lancer/surrender/surrenderlib/srapi.zig) | `srAPI.cpp` | The projection; a mesh's planes and bounds |
| [`surrenderlib/srapiext.zig`](../../src/lancer/surrender/surrenderlib/srapiext.zig) | `srAPIext.cpp` | Meshes, mesh objects, sprite sets |
| [`srd3d/srd3d.zig`](../../src/lancer/surrender/srd3d/srd3d.zig) | `srd3d.dll` | The driver: render states, batching, clipping, the sun test |
| [`srd3d/device.zig`](../../src/lancer/surrender/srd3d/device.zig) | Direct3D 7 | The device the driver draws with |
| [`srd3d/software.zig`](../../src/lancer/surrender/srd3d/software.zig) | | A device that rasterizes as Direct3D 7 does, in software |
| [`game/srofiles.zig`](../../src/lancer/game/srofiles.zig) | `srofiles.cpp` | Meshes from `.SHP` models |
| [`game/objects.zig`](../../src/lancer/game/objects.zig) | `objects.cpp` | A live object's part nodes, placed and drawn |
| [`game/nebula.zig`](../../src/lancer/game/nebula.zig), [`game/backdrop.zig`](../../src/lancer/game/backdrop.zig) | `nebula.cpp`, backdrop | The sky dome, the nebula, the stars, the dust, the sun, the lights |
| [`game/xtrabits.zig`](../../src/lancer/game/xtrabits.zig) | `xtrabits.cpp` | `scene_add` |

The software device is the reference the GPU device is checked against: the same scene gives the
same image. Pixel centres lie at whole numbers, as in Direct3D 7; screen positions are kept in
sixteenths of a pixel, and a pixel whose centre lies on an edge belongs to the triangle whose top
or left edge it is. Colours, alpha and texture coordinates are interpolated in perspective, depth
straight across the screen. Textures are sampled bilinearly, wrapping, from the mip level nearest
to the texels a pixel spans.

The `starlancer` executable draws with it ([Platform](platform.md)), putting the software device's
frames on the screen until the GPU device replaces it. `sltool render` draws a model against the
backdrop through all of it, two frames as the game draws
them one after another, the first finding how much of the sun shows; `make render` draws the
Predator toward the nebula and toward the sun into `game/renders/`.

## Improvements

Deliberate differences from the original, each marked **Improvement** where it is made:

- The view is unstretched on any screen: the factor across keeps pixels square, and a wider screen
  shows more at the sides ([Camera](../engine/camera.md#projection)).
- The driver tests a blended polygon's triangles against the sun with the polygon's own corners,
  where the original uses indices left over from the last list it drew.
- A vertex with no counterpart in the next level of detail morphs toward itself, where the original
  reads whatever lies before that level's vertices.

## Not yet ported

- The software renderer, `srddraw.dll`, and the software renderer's sky dome.
- The static lights `model_load` bakes into meshes, and the mesh sets it builds for cloaking.
- Hanging each part from its parent part's node (`object_link_parts`), which leaves every part
  where it is, and the moment of inertia `object_bounds` sums.
- What `node_draw` draws besides model parts: lights, engine glows, the cloak; and its leaving out
  objects too far away to see.
- `backdrop_place`, which aims the sun, the lights and the nebula from a mission's markers, and the
  objects `backdrop_frame` turns and makes glow.
- Scene objects of kinds 5 and 6.
