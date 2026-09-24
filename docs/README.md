# Documentation

This directory contains technical documentation for OpenReliant, including engine architecture notes, reverse engineering findings from the original 2000 PC release of StarLancer, file format specifications, and developer tooling guides.

---

## User Guide

For guides on installing and playing OpenReliant, see the **[User Guide](guide/README.md)**:

- [**Installation & Quickstart**](guide/installation.md): System requirements, installing from retail discs or disc images, and running the game.
- [**Controllers & Input**](guide/controllers.md): Setting up gamepads, flight sticks, and HOTAS hardware, default controls, and deadzone configuration.
- [**Configuration & Options**](guide/configuration.md): Complete command-line reference, graphics/audio options, difficulty levels, and `starlancer.ini`.

---

## Technical Documentation

### Engine Architecture & Subsystems

Detailed documentation of runtime systems in `src/engine/`:

| Document | Topic |
|---|---|
| [`engine/loop.md`](engine/loop.md) | **Game Loop**: Pacing, 100 Hz game ticks, 25 Hz simulation steps, and collision updates. |
| [`engine/objects.md`](engine/objects.md) | **Live Objects**: Object arrays, component hierarchies, collision boxes, and the flight physics model. |
| [`engine/rendering.md`](engine/rendering.md) | **Rendering Pipeline**: Draw layers, depth buffering, lighting passes, materials, and blending modes. |
| [`engine/camera.md`](engine/camera.md) | **Camera Subsystem**: Projection matrices, viewport calculations, and camera perspectives (1–8). |
| [`engine/backdrop.md`](engine/backdrop.md) | **Backdrop**: Sky domes, nebulae, starfields, space dust, sun flares, and ambient lighting. |
| [`engine/hud.md`](engine/hud.md) | **Head-Up Display**: Reticle, radar, shield/armor gauges, status indicators, and tactical panels. |
| [`engine/guns.md`](engine/guns.md) | **Guns & Lasers**: Hardpoint weapon slots, firing rates, projectile simulation, and energy consumption. |
| [`engine/missiles.md`](engine/missiles.md) | **Missiles & Torpedoes**: Guidance systems, lock-on mechanics, missile models, and exhaust trails. |
| [`engine/effects.md`](engine/effects.md) | **Visual Effects**: Particle systems, fireballs, hull damage smoke, and ship destruction sequences. |
| [`engine/sound.md`](engine/sound.md) | **Sound Engine**: Bank loading, voice allocation, 3D audio positioning, engine pitch, and music streaming. |
| [`engine/controls.md`](engine/controls.md) | **Controls & Input**: Action bindings, input state machines, steering, and throttle processing. |
| [`engine/orders.md`](engine/orders.md) | **AI Orders**: Object order stacks, AI state transitions, navigation, and command execution. |
| [`engine/maneuvers.md`](engine/maneuvers.md) | **Combat Maneuvers**: AI dogfighting maneuvers, bytecode syntax, and situational selection logic. |
| [`engine/pause-menu.md`](engine/pause-menu.md) | **In-Game Menu**: Options menu architecture, settings persistence, and screen navigation. |
| [`engine/script-vm.md`](engine/script-vm.md) | **Mission Script VM**: Thread execution, event queues, timers, and bytecode opcodes. |

---

### File & Asset Formats

Specifications for game asset formats found on the retail discs and decoded in `src/formats/`:

| Document | Format | Description |
|---|---|---|
| [`formats/disc-images.md`](formats/disc-images.md) | `.bin` / `.iso` | CD-ROM sector structures and ISO 9660 filesystem layouts. |
| [`formats/hog.md`](formats/hog.md) | `.HOG` | EA `BIGF` archive container format and member directories. |
| [`formats/refpack.md`](formats/refpack.md) | RefPack | LZ-based compression used within `.HOG` archives. |
| [`formats/shp.md`](formats/shp.md) | `.SHP` | 3D models: chunks, levels of detail (LOD), vertices, faces, and hardpoints. |
| [`formats/spr.md`](formats/spr.md) | `.SPR` | 2D UI sprites, WinVFX frames, and color palettes. |
| [`formats/tcache.md`](formats/tcache.md) | Texture Cache | Texture atlases (`tcache*.dat`), palette lookups, and mipmaps. |
| [`formats/fat.md`](formats/fat.md) | `.fat` | Audio sound banks containing indexed sound samples. |
| [`formats/fnt.md`](formats/fnt.md) | `.fnt` | Bitmap font structures and character width metrics. |
| [`formats/dte.md`](formats/dte.md) | `.DTE` | Mission definition files: object spawn tables, triggers, and script bytecode. |
| [`formats/stats.md`](formats/stats.md) | `.bin` stats | Ship, weapon, missile, and pilot stat tables (`shipstats.bin`, etc.). |

---

### Binary Reverse Engineering

Analysis of the original executables and compilation environment:

| Document | Topic |
|---|---|
| [`binary/executables.md`](binary/executables.md) | Overview of shipped executables (`LANCER.EXE`, `srd3d.dll`, etc.) and middleware libraries. |
| [`binary/runtime.md`](binary/runtime.md) | Visual C++ 6.0 C runtime (`LIBCMT`) linked into the game binary. |
| [`binary/sources.md`](binary/sources.md) | Reconstructed source file manifest, link order, and module mappings. |

---

### Port & Platform Internals

Documentation of OpenReliant's modern platform and hardware abstractions in `src/platform/`:

| Document | Topic |
|---|---|
| [`port/platform.md`](port/platform.md) | Platform abstraction layer: SDL3 integration, window lifecycle, and input dispatching. |
| [`port/renderer.md`](port/renderer.md) | Modern GPU renderer pipeline (Vulkan/Metal via SDL_GPU), shaders, and software reference device. |
| [`port/sound.md`](port/sound.md) | Audio engine reimplementation: OpenAL Soft spatial audio, HRTF, and software fallback mixer. |

---

### Development & Toolchain

- [`toolchain.md`](toolchain.md): Build dependencies, environment setup, Ghidra decompilation workflow, and GhydraMCP bridge configuration.

---

## Reverse Engineering Conventions

- **Virtual Addresses**: Memory addresses cited in documentation are virtual addresses relative to the payload executable's default base address (`0x00400000`), unless explicitly noted otherwise.
- **Symbol Names**: Because the retail binaries were stripped of debug symbols, function and global variable names reflect the labels assigned during Ghidra static analysis (via `make ghidra-annotate`). Generic placeholders follow Ghidra's `FUN_<address>` convention.
- **Binary Layouts**: In-memory structs and binary file headers are modeled as `extern struct` types in Zig with compile-time offset assertions ([`src/formats/layout.zig`](../src/formats/layout.zig)).
- **Verification Levels**: Where reverse engineering conclusions are provisional, they are tagged:
  - **Unknown**: Behavior or structure not yet fully analyzed.
  - **Unverified**: Inferred from surrounding patterns but awaiting empirical confirmation.
