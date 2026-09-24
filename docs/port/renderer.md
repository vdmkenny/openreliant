# Renderer Architecture

OpenReliant implements the Surrender 3D graphics pipeline, ported module-by-module to mirror the original source layout. Its Direct3D 7 driver has been adapted to render via a modern device interface rather than legacy `IDirect3DDevice7` calls.

---

## Module Overview

| Module | Original File | Responsibility |
|---|---|---|
| [`surrenderlib/srcore.zig`](../../src/engine/surrender/surrenderlib/srcore.zig) | `srCore.cpp` | Scene lists, layer-by-layer frame scheduling, and sorting deferred driver draws. |
| [`surrenderlib/srmesh.zig`](../../src/engine/surrender/surrenderlib/srmesh.zig) | `srMesh.cpp` | Mesh processing: view frustum tests, LOD selection, culling, clipping/projection, and vertex lighting. |
| [`surrenderlib/srbmo.zig`](../../src/engine/surrender/surrenderlib/srbmo.zig) | `srBMO.cpp` | Sprite and billboard rendering pipeline. |
| [`surrenderlib/srstars.zig`](../../src/engine/surrender/surrenderlib/srstars.zig) | `srstars.cpp` | Starfield simulation and rendering. |
| [`surrenderlib/srapi.zig`](../../src/engine/surrender/surrenderlib/srapi.zig) | `srAPI.cpp` | Projection math, bounding volumes, and plane definitions. |
| [`surrenderlib/srapiext.zig`](../../src/engine/surrender/surrenderlib/srapiext.zig) | `srAPIext.cpp` | Mesh instances, mesh object creation, and sprite sets. |
| [`srd3d/srd3d.zig`](../../src/engine/surrender/srd3d/srd3d.zig) | `srd3d.dll` | Render states, primitive batching, polygon clipping, and sun occlusion queries. |
| [`srd3d/device.zig`](../../src/engine/surrender/srd3d/device.zig) | Direct3D 7 | Abstract device interface implemented by the backends. |
| [`srd3d/software.zig`](../../src/engine/surrender/srd3d/software.zig) | *(New)* | Software rasterizer reference device matching Direct3D 7 rasterization rules. |
| [`platform/gpu.zig`](../../src/platform/gpu.zig) | Direct3D 7 | Hardware accelerated rendering backend built on SDL3's GPU API. |
| [`platform/shaders/device.glsl`](../../src/platform/shaders/device.glsl) | Texture stages | Main fragment and vertex shader replacing fixed-function texture stages. |
| [`surrenderlib/srshadow.zig`](../../src/engine/surrender/surrenderlib/srshadow.zig) | *(New)* | Cascaded shadow map generation and caster culling. |
| [`platform/gpu/geometry.zig`](../../src/platform/gpu/geometry.zig) | *(New)* | Dynamic vertex and index buffer allocators for the GPU backend. |
| [`game/srofiles.zig`](../../src/engine/game/srofiles.zig) | `srofiles.cpp` | Converts loaded `.SHP` model records into renderable meshes. |
| [`game/objects.zig`](../../src/engine/game/objects.zig) | `objects.cpp` | Hierarchical transform updates and rendering for live game objects. |
| [`game/nebula.zig`](../../src/engine/game/nebula.zig), [`game/backdrop.zig`](../../src/engine/game/backdrop.zig) | `nebula.cpp`, backdrop | Sky dome, volumetric nebulae, stars, space dust, sun, and ambient lights. |

Scene objects are routed to pipelines based on their object type:
- **Type 1**: 3D polygonal mesh
- **Type 4**: Sprite set / billboard particles
- **Type 7**: Background starfield
*(Types 5 and 6 are unused legacy pipes; see [Unused Pipeline Types](#unused-pipeline-types-5-and-6) below).*

---

## Software Reference Device

The software rasterizer (`srd3d/software.zig`) serves as a pixel-accurate reference to validate the GPU backend:
- Pixel centers follow Direct3D 7 conventions (integer coordinates).
- Subpixel coordinates are tracked in 1/16th pixel precision with top-left fill rules.
- Color, alpha, and texture coordinates are interpolated with perspective correctness; depth is linearly interpolated across screen space.
- Textures are sampled using bilinear filtering with wrap addressing.

---

## GPU Device Backend

The hardware GPU device (`platform/gpu.zig`) uses SDL3's modern GPU abstraction (Vulkan on Linux/Windows, Metal on macOS). Because the original driver issued small draw calls (strips, fans, and individual blended polygons), the modern device batches geometry before submitting to the GPU:

1. **Texture Arrays**: Textures with matching dimensions and mipmap levels are packed into texture arrays (up to 256 layers per array). Textures are uploaded on first use.
2. **Batching**: Strips and fans are converted into indexed triangle lists. Consecutive draw calls sharing render states and texture arrays are merged into a single multi-instance draw call.
3. **Pipeline States**: Dedicated pipelines are created for each unique combination of blend modes and depth test configurations. Depth test uses greater-or-equal with reversed floating-point depth buffers for improved precision.
4. **Shader Architecture** ([`device.glsl`](../../src/platform/shaders/device.glsl)):
   - Reconstructs perspective interpolation using `rhw` (reciprocal homogeneous `w`).
   - Evaluates up to 64 active directional and point lights per pixel.
   - Applies cascaded shadow map attenuation to primary key lights.
   - Shaders are pre-compiled to SPIR-V and Metal Shading Language (MSL).

---

## Cascaded Shadow Mapping

OpenReliant adds dynamic directional shadows cast by the primary star:

1. **Cascades**: The view frustum is partitioned into four depth cascades, each rendered using an orthographic projection centered around its slice of the view frustum. Cascade boundaries stabilize to world texel grids to prevent edge shimmering when the camera rotates.
2. **Cockpit Cascade**: A dedicated 5th high-resolution cascade tightly encloses the cockpit interior and cockpit frame.
3. **Caster Culling**: All opaque meshes within range cast shadows. Non-visible hulls casting into the view frustum are included. Sprites and transparent surfaces are excluded.
4. **Filtering**: Soft shadow filtering is evaluated with PCF (Percentage-Closer Filtering) sampling with normal-offset bias to eliminate self-shadowing artifacts.
5. **Configuration**:
   - `high` (default): 4096x4096 cascade maps, 16 PCF taps.
   - `low`: 1024x1024 cascade maps, 4 PCF taps.
   - `off`: Disables shadow rendering (`--shadows off` or `--original`).

---

## Visual & Technical Improvements

OpenReliant incorporates several deliberate visual enhancements over the 2000 retail release:

- **Widescreen & Aspect Ratio Correction**: Viewports adapt dynamically to modern aspect ratios without stretching; field of view expands horizontally to maintain square pixels.
- **Extended Level of Detail (LOD)**: Highest-detail ship meshes render at up to 8x the distance of the original game, preventing noticeable geometric pop-in on modern high-resolution screens.
- **Native Resolution & Anti-Aliasing**: Renders at display native resolution with 4x MSAA enabled by default.
- **Modern Texture Filtering**: Textures use trilinear filtering with 16x anisotropic filtering and Catmull-Rom bicubic magnification.
- **HDR Bloom**: High-intensity light sources (thruster plumes, lasers, explosions, sun) bleed subtly into adjacent pixels through a downsampled Gaussian blur pass.
- **Per-Pixel Lighting**: Evaluates directional and point lights per pixel rather than per vertex, eliminating lighting artifacts on low-poly geometry.
- **Dynamic Weapon Illumination**: Projectiles emit dynamic point lights illuminating nearby ship hulls, expanding beyond the original engine's limit of 2 active shot lights.
- **Enhanced Explosion Sequences**: Supports up to 128 simultaneous expanding fireballs (up from 30) with smooth inter-frame blending and circular shockwave geometry.
- **Linear Color Processing**: Lighting calculations and texture lookups occur in linear sRGB space, preventing color banding and unnatural color saturation.

*(All enhancements can be turned off with `--original` to match the 2000 release's visual output).*

---

## Unused Pipeline Types (5 and 6)

Static analysis indicates the original retail engine linked skeletal remnants of two unused primitives:
- **Type 5 (`line_pipe`)**: Line segment rasterizer from `srline.cpp`.
- **Type 6 (`balls_pipe`)**: Screen-space point sprite / sphere rasterizer from `srballs.cpp`.

Neither type is instantiated by the shipped game assets; weapon tracers and beams are standard textured quad meshes rather than line primitives. Driver jump tables leave the handlers for types 5 and 6 unassigned.

---

## Pending Work

- Software DirectDraw fallback driver (`srddraw.dll`).
- Cloaking shader distortion effects.
- Dynamic scene backdrop alignment from mission script marker vectors.
