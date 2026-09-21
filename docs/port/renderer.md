# Renderer

The port draws with Surrender's own pipeline, ported function by function into the modules of
its original files, and with its Direct3D 7 driver, ported to draw through a device interface in
place of `IDirect3DDevice7`.

| Module | Original | Does |
|---|---|---|
| [`surrenderlib/srcore.zig`](../../src/engine/surrender/surrenderlib/srcore.zig) | `srCore.cpp` | The scene's lists; a frame, layer by layer; the sort of what the driver puts aside |
| [`surrenderlib/srmesh.zig`](../../src/engine/surrender/surrenderlib/srmesh.zig) | `srMesh.cpp` | The mesh pipeline: view test, level of detail, culling, projection or clipping, lighting |
| [`surrenderlib/srbmo.zig`](../../src/engine/surrender/surrenderlib/srbmo.zig) | `srBMO.cpp` | The sprite pipeline |
| [`surrenderlib/srstars.zig`](../../src/engine/surrender/surrenderlib/srstars.zig) | `srstars.cpp` | The star pipeline |
| [`surrenderlib/srapi.zig`](../../src/engine/surrender/surrenderlib/srapi.zig) | `srAPI.cpp` | The projection; a mesh's planes and bounds |
| [`surrenderlib/srapiext.zig`](../../src/engine/surrender/surrenderlib/srapiext.zig) | `srAPIext.cpp` | Meshes, mesh objects, sprite sets |
| [`srd3d/srd3d.zig`](../../src/engine/surrender/srd3d/srd3d.zig) | `srd3d.dll` | The driver: render states, batching, clipping, the sun test |
| [`srd3d/device.zig`](../../src/engine/surrender/srd3d/device.zig) | Direct3D 7 | The device the driver draws with |
| [`srd3d/software.zig`](../../src/engine/surrender/srd3d/software.zig) | | A device that rasterizes as Direct3D 7 does, in software |
| [`platform/gpu.zig`](../../src/platform/gpu.zig) | Direct3D 7 | The device the `openreliant` executable draws with: SDL's GPU interface |
| [`platform/shaders/device.glsl`](../../src/platform/shaders/device.glsl) | Direct3D 7's texture stages | The GPU device's one shader |
| [`game/srofiles.zig`](../../src/engine/game/srofiles.zig) | `srofiles.cpp` | Meshes from `.SHP` models |
| [`game/objects.zig`](../../src/engine/game/objects.zig) | `objects.cpp` | A live object's part nodes, placed and drawn |
| [`game/nebula.zig`](../../src/engine/game/nebula.zig), [`game/backdrop.zig`](../../src/engine/game/backdrop.zig) | `nebula.cpp`, backdrop | The sky dome, the nebula, the stars, the dust, the sun, the lights |
| [`game/xtrabits.zig`](../../src/engine/game/xtrabits.zig) | `xtrabits.cpp` | `scene_add` |

The software device is the reference the GPU device is checked against: the same scene gives the
same image. Pixel centres lie at whole numbers, as in Direct3D 7; screen positions are kept in
sixteenths of a pixel, and a pixel whose centre lies on an edge belongs to the triangle whose top
or left edge it is. Colours, alpha and texture coordinates are interpolated in perspective, depth
straight across the screen. Textures are sampled bilinearly, wrapping, from the mip level nearest
to the texels a pixel spans.

The `openreliant` executable draws with the GPU device, or with the software device when asked
([Platform](platform.md)). `sltool render` draws a model against the backdrop through all of it onto
the software device, two frames as the game draws them one after another, the first finding how much
of the sun shows; `make render` draws the Predator toward the nebula and toward the sun into
`game/renders/`.

## The GPU device

The GPU device draws what the driver hands over with SDL's GPU interface: Metal on macOS, Vulkan
elsewhere. The driver draws a strip, a fan or a single blended polygon at a time, and the game's
textures are small, so the device gathers a frame before drawing it:

- Each texture is a layer of a texture array holding the textures of its width, height and number of
  levels, up to 256 layers, the fewest Vulkan guarantees; a texture goes up to the GPU, every level,
  the first time it is drawn, and the device keeps its array and layer in the image's `device`, as
  the driver's `texture_upload` keeps the device texture it makes.
- Each vertex names its texture's layer, or none. Strips and fans become lists of triangles, and
  consecutive draws with the same primitive and render states, whose textures share an array, go to
  the GPU as one draw.
- A pipeline is made for each primitive and set of render states the frame uses: the depth test
  greater or equal, depth being reversed, and the driver's blend factors. Depth is clamped rather
  than clipped, as Direct3D 7 did not clip transformed vertices in depth, and the pipelines write
  colour only, as the original's back buffer kept no alpha.

The shader, [`device.glsl`](../../src/platform/shaders/device.glsl), takes the driver's vertices as
they are: screen positions with pixel centres at whole numbers, reversed depth, and `rhw`, whose
inverse as the clip-space `w` makes colours and texture coordinates vary in perspective. The
fragment is the texel times the vertex colour, or the vertex colour alone. `make shaders` compiles
it with `glslc` into SPIR-V, and from that into Metal's language with SPIRV-Cross, which `make`
builds; the outputs are committed, so building the game needs neither.

## Improvements

Deliberate differences from the original, each marked **Improvement** where it is made:

- The view is unstretched on any screen: the factor across keeps pixels square, and a wider screen
  shows more at the sides ([Camera](../engine/camera.md#projection)).
- The driver tests a blended polygon's triangles against the sun with the polygon's own corners,
  where the original uses indices left over from the last list it drew.
- A vertex with no counterpart in the next level of detail morphs toward itself, where the original
  reads whatever lies before that level's vertices.
- The GPU device draws at the display's own resolution, with four samples a pixel, where the
  original drew one.
- It filters textures trilinearly, sixteen times anisotropic, where the original sampled bilinearly
  from the nearest level, and magnifies them with a Catmull-Rom filter, which keeps the small
  textures sharp up close.
- It draws in 32-bit colour, where the original drew in 16 bits. `--original` restores the
  original's look: 16-bit colour, dithered, into a 16-bit buffer where the GPU has one, with a
  16-bit depth buffer, one sample a pixel and bilinear filtering.

## Not yet ported

- The software renderer, `srddraw.dll`, and the software renderer's sky dome.
- The mesh sets `model_load` builds for cloaking.
- Hanging each part from its parent part's node (`object_link_parts`), which leaves every part
  where it is, and the moment of inertia `object_bounds` sums.
- What `node_draw` draws besides model parts: lights, engine glows, the cloak; and its leaving out
  objects too far away to see.
- `backdrop_place`, which aims the sun, the lights and the nebula from a mission's markers, and the
  objects `backdrop_frame` turns and makes glow.
- Scene objects of kinds 5 and 6.
