# Documentation

Reference notes on StarLancer (Digital Anvil / Microsoft, 2000; developed by Warthog) and on this
repository's tooling, derived from static analysis of a legally owned copy. The repository stores
no game code or assets.

| Path | Contents |
|---|---|
| [`toolchain.md`](toolchain.md) | What `make setup` installs, and the Ghidra workflow. |
| [`binary/executables.md`](binary/executables.md) | The shipped binaries and the middleware they are built on. |
| [`binary/safedisc.md`](binary/safedisc.md) | SafeDisc 1, and recovering the game executable from it. |
| [`binary/runtime.md`](binary/runtime.md) | The C runtime linked into the game: Visual C++ 6.0's `LIBCMT`. |
| [`binary/sources.md`](binary/sources.md) | The game's source files, their link order, and which code each holds. |
| [`formats/disc-images.md`](formats/disc-images.md) | Raw CD images and the discs' ISO 9660 filesystem. |
| [`formats/hog.md`](formats/hog.md) | `.HOG` archives: EA's `BIGF` container. |
| [`formats/refpack.md`](formats/refpack.md) | RefPack, the compression inside them. |
| [`formats/shp.md`](formats/shp.md) | `.SHP` models: chunks, parts, levels of detail, geometry, coordinate frame. |
| [`formats/spr.md`](formats/spr.md) | `.SPR` sprites: the WinVFX interface imagery. |
| [`formats/tcache.md`](formats/tcache.md) | Texture caches: every model and effect texture, their palettes and colour cubes. |
| [`formats/fat.md`](formats/fat.md) | `.fat` sound banks. |
| [`formats/fnt.md`](formats/fnt.md) | `.fnt` bitmap fonts. |
| [`formats/dte.md`](formats/dte.md) | `.DTE` missions: directory, ships, triggers, and the script VM. |
| [`formats/stats.md`](formats/stats.md) | Ship, gun, missile and pilot stat tables. |
| [`engine/script-vm.md`](engine/script-vm.md) | The script VM at run time: threads, calls, commands, timers, events. |
| [`engine/camera.md`](engine/camera.md) | The camera: the projection, the views, and where each puts the camera. |
| [`engine/backdrop.md`](engine/backdrop.md) | The backdrop: sky dome, nebula, stars, dust, sun, lens flares and the default lights. |
| [`engine/rendering.md`](engine/rendering.md) | Rendering: layers, depth, shading modes as materials, lighting, blending, highlights. |
| [`engine/objects.md`](engine/objects.md) | Live objects: the object array, model hierarchies, components, the flight model. |
| [`engine/loop.md`](engine/loop.md) | The game loop: the 100 Hz tick, the 25 Hz simulation step, collisions. |
| [`engine/controls.md`](engine/controls.md) | Player input: devices, bindings, settings, steering and throttle. |
| [`engine/orders.md`](engine/orders.md) | Orders: the table of what objects can be told to do, each object's stack, and how orders run. |
| [`engine/maneuvers.md`](engine/maneuvers.md) | Combat maneuvers: the scripts Fight runs, their language, and how it chooses them. |
| [`port/renderer.md`](port/renderer.md) | The renderer: Surrender's pipeline and Direct3D driver as ported, the software reference device, improvements and what is not yet ported. |

## Conventions

Addresses are virtual addresses for the payload executable's image base of `0x400000` unless
stated otherwise. The shipped binaries carry no symbols. Function and data names are those
`make ghidra-annotate` gives the Ghidra project; names of the form `FUN_<address>` are Ghidra's
placeholders.

Claims are marked where they are not directly verified:

- **Unknown:** not yet determined.
- **Unverified:** inferred from surrounding evidence but not confirmed.
