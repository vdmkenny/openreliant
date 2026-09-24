# Space Backdrop & Environmental Lighting

This document describes the background rendering pipeline in StarLancer, including the sky dome, volumetric nebulae, starfield, floating space dust, sun flares, and global directional lighting.

Backdrop elements are centered on the active camera position and rendered into the background pass, with the exception of screen-space lens flares which render into the overlay pass ([Rendering](rendering.md#frame)).

---

## Backdrop Elements

| Element | Asset Source | Render Mode | Notes |
|---|---|---|---|
| **Sky Dome** | `starref12.tga` | Untextured, opaque | Ambient gradient sphere enclosing the scene. |
| **Nebula** | `neb01` – `neb07` | Additive textured mesh | Spherical billboard patch representing local nebulae. |
| **Stars** | `space.tga` | Additive points/streaks | Partitioned celestial star map with motion streaking. |
| **Space Dust** | Procedural | Additive points/streaks | Floating particles near the ship to provide velocity cues. |
| **Sun** | `sunlayer1` – `sunlayer3` | Additive billboards | Multi-layer solar corona and glare sprites. |
| **Lens Flares** | `sunflare1` – `sunflare4` | Additive overlays | Dynamic screen-space lens flare artifacts. |

Backdrop creation is managed by `backdrop_create` (`0x004A4E70`) and `nebula_create` (`0x00498B30`). Per-frame updates are dispatched by `backdrop_frame` (`0x004A5CD0`) and `nebula_frame` (`0x00498E10`).

---

## Sky Dome Geometry

The background sky dome (`nebula_dome`, `0x00498810`) forms a 15x8 vertex cylindrical band centered at the camera:
- **Geometry**: Vertices are placed at radius 5,000, spanning polar angles up to approximately 68° from the equator (terminating 22° short of the poles).
- **Coloration**: Colors are sampled directly from `starref12.tga`.
- **Render Flags**: Rendered with culling and lighting disabled (`flags = 0x81800`), providing the foundational background color for the scene.

---

## Nebulae & Environmental Lighting

Nebulae render as an 11x11 spherical mesh patch with radius 5,000 (`sky_patch_create`, `0x00498EA0`), spanning 90° across the sky (72° for Nebula 5).

Missions configure the active nebula via script command `SetEnvironmentFXNebula(0..6)`. Selecting a nebula automatically tints the mission's ambient fill lights to complement the cloud's coloration:

| Nebula Index | Texture Asset | Fill Light Color (R, G, B) |
|---|---|---|
| `0` | `neb01` | `(0.24, 0.50, 1.00)` |
| `1` | `neb02` | `(0.00, 1.00, 0.80)` |
| `2` | `neb03` | `(0.33, 0.46, 1.00)` |
| `3` | `neb04` | `(0.74, 1.00, 0.32)` |
| `4` | `neb05` | `(0.00, 0.75, 1.00)` |
| `5` | `neb06` | `(0.92, 0.66, 0.33)` |
| `6` | `neb07` | `(0.00, 1.00, 1.00)` |

---

## Starfield Projection & Streaking

The celestial sphere is generated from `space.tga` (a 360x360 map where each non-black pixel represents a star):
- **Spatial Partitioning**: The texture is divided into 100 angular sectors (36x36 pixels each). Each sector represents an 18° polar by 18° azimuthal field in the celestial sphere.
- **Frustum Culling**: Fields outside the camera's field of view (cosine < 0.6) are culled before rendering.
- **Motion Streaking**: During high angular velocities or afterburner acceleration, stars moving more than one screen pixel between consecutive frames are drawn as velocity lines trailing back toward their previous screen coordinates.
- **Camera Cut Protection**: When camera views switch, `backdrop_reset_streaks` (`0x004A5C80`) clears historical positions to prevent full-screen streak artifacts.

---

## Space Dust Particles

To provide visual feedback for ship speed and drift in open space, the engine distributes 200 dust motes in an 8,192-unit cubic volume around the camera:
- Mote coordinates wrap periodically as the ship moves.
- Brightness attenuates with distance from the camera, fading completely by 4,096 units.
- Motes streak along velocity vectors when flying at high speeds or boosting with afterburners.

---

## Sun & Screen-Space Lens Flares

The sun direction vector is defined by the mission sun marker orientation (or defaults to normalized `(1.0, -0.5, 0.2)`).

The sun renders as three concentric additive billboard layers:
- `sunlayer1`: Primary bright core (always drawn).
- `sunlayer2` & `sunlayer3`: Corona and secondary glare, scaling in brightness based on sun visibility and angle to camera center.

### Occlusion & Lens Flares
Sun visibility (`0.0` to `1.0`) is evaluated by testing whether geometry obscures the sun's screen-space position. When the sun is visible and unoccluded:
- Four flare sprites (`sunflare1` through `sunflare4`) render along the axis connecting the sun's screen position to the screen center.
- Flares fade out when the sun passes behind ship hulls, stations, or off the screen edges.

---

## Scene Lighting Rig

`backdrop_create` sets up a standard six-light lighting rig for the mission environment:

| Mask | Type | Intensity | Base Color | Role |
|---|---|---|---|---|
| `0x01` | Directional | 1.0 | `(1.00, 1.00, 0.80)` | Primary sun key light |
| `0x02` | Directional | 1.0 | *(Active Nebula)* | Nebula diffuse fill light |
| `0x04` | Ambient | 1.0 | `(0.04, 0.04, 0.04)` | Deep shadow ambient floor |
| `0x08` | Directional | 1.0 | `(1.00, 1.00, 0.80)` | Secondary key light |
| `0x10` | Directional | 0.7 | *(Active Nebula)* | Secondary fill light |
| `0x20` | Ambient | 1.0 | `(0.09, 0.09, 0.09)` | Secondary ambient fill |
