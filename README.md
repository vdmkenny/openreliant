# OpenReliant

OpenReliant is an open-source, faithful engine reimplementation of **StarLancer**, the space combat simulator developed by Warthog and Digital Anvil and published by Microsoft in 2000.

Written in **Zig** and built on **SDL3**, OpenReliant renders with Vulkan (Metal on macOS) via SDL's GPU API. It runs natively on Linux, macOS, and Windows using assets directly from your retail copy of the game.

<p align="center">
  <img src="docs/images/predator-wireframe.svg" width="560"
       alt="Wireframe of the Predator light fighter exported from its .SHP model">
</p>

---

## Legal & Asset Policy

OpenReliant is an independent, non-commercial open-source project. It is not affiliated with, endorsed by, or associated with Warthog Games, Digital Anvil, or Microsoft. StarLancer is a trademark of its respective owner.

**This repository contains no copyrighted game assets**: no textures, 3D models, sound effects, music, cinematics, mission scripts, or game binaries. OpenReliant requires assets extracted from a legally owned copy of StarLancer to run. We do not support or condone software piracy.

---

## Current Status

OpenReliant is currently in active early development. It features a playable sandbox environment:

- **Flight & Combat**: Fly any ship from the game using mouse/keyboard, flight sticks, HOTAS, or gamepads. The authentic flight model, throttle, afterburners, and 8 camera modes (including 3D cockpits) are implemented.
- **AI Dogfighting**: Encounter a hostile Coalition fighter wing executing authentic combat maneuvers (pursuit, evasion, loops, and strafing runs).
- **Collision & Damage**: Collision physics and damage models are active. Collisions deplete shields and armor, which progressively reduce flight speed and weapon recharge rates. Ships break up with explosion effects, debris, and shockwaves upon destruction.
- **Weapons & Power Management**: Laser weapons fire authentically based on ship stats and draw energy from the power distribution grid.
- **HUD & Cockpit Displays**: The targeting reticle, radar, shield/armor status indicators, and tactical toggles (ECM, spectral shields, blind fire) are functional.
- **Positional 3D Audio**: Dynamic sound effects, engine audio, directional flybys, and game music are mixed with 3D spatial positioning, environmental reverb, and headphone HRTF support.
- **In Development**: Missiles, campaign missions, and voice dialogue are currently in progress. See the [milestones](../../milestones) for the development roadmap.

---

## Documentation

The project documentation is organized into two distinct sections:

- [**User Guide**](docs/guide/README.md):
  - [Installation & Quickstart](docs/guide/installation.md): Requirements and installing from retail CDs or disc images.
  - [Controllers & Input](docs/guide/controllers.md): Setting up flight sticks, HOTAS hardware, gamepads, and button bindings.
  - [Configuration & Options](docs/guide/configuration.md): Command-line switches, graphics settings, audio modes, and `starlancer.ini`.
- [**Developer & Technical Documentation**](docs/README.md):
  - [Engine Architecture](docs/README.md#engine-architecture--subsystems): Runtime subsystems, physics, rendering pipeline, sound, and scripting VM.
  - [Asset & File Formats](docs/README.md#file--asset-formats): Specifications for `.SHP` models, `.HOG` archives, textures, and mission formats.
  - [Binary Reverse Engineering](docs/README.md#binary-reverse-engineering): Analysis of the retail binaries, C runtime, and decompilation.
  - [Toolchain & Setup](docs/toolchain.md): Build instructions, Ghidra disassembly setup, and the `sltool` command-line utility.

---

## Quickstart

### 1. Download OpenReliant
Download the pre-compiled archive for your platform from the [latest release](../../releases/latest) and extract it.

*(macOS users: run `xattr -d com.apple.quarantine openreliant` to clear the gatekeeper quarantine flag).*

### 2. Install Game Files
Insert StarLancer Disc 1 into your CD drive (or prepare `.bin`/`.iso` images) and run the built-in installer:

```bash
# Physical CD-ROM
./openreliant install StarLancer

# Or from disc image files
./openreliant install --from "StarLancer Disc 1.bin" --from "StarLancer Disc 2.bin" StarLancer
```

*(On Windows, use `.\openreliant.exe`.)*

### 3. Launch
```bash
./openreliant StarLancer
```

Press **Continue** (or **Escape**) in the options menu to start flying. Press **F2** / **F3** to switch ships, **F4** to spawn another fighter wing, and number keys **1-8** to change camera views.

For complete setup instructions, see the [Installation Guide](docs/guide/installation.md).

---

## Building from Source

Building OpenReliant requires [Zig 0.16](https://ziglang.org). Dependencies (SDL3, OpenAL Soft, libarchive) are fetched and built automatically:

```bash
# Build optimized release binary
zig build -Doptimize=ReleaseFast

# Run tests
zig build test

# Install and play
zig-out/bin/openreliant install StarLancer
zig-out/bin/openreliant StarLancer
```

---

## Reverse Engineering & Analysis Tools

The repository includes tools used during reverse engineering:

```bash
make setup     # Download JDK and Ghidra, and build native decompilers
make build     # Compile development tools into zig-out/bin
make test      # Run unit test suite
make doctor    # Verify installed prerequisites
```

The `sltool` utility inspects and exports game formats:

| Command | Description | Documentation |
|---|---|---|
| `sltool cd` | Inspect CD images and ISO 9660 filesystems | [disc-images](docs/formats/disc-images.md) |
| `sltool hog` | Extract `.HOG` archives (`BIGF` container / RefPack) | [hog](docs/formats/hog.md), [refpack](docs/formats/refpack.md) |
| `sltool shp` | Inspect `.SHP` 3D models; export Wavefront OBJ | [shp](docs/formats/shp.md) |
| `sltool spr` | Inspect `.SPR` 2D interface sprites; export PNG | [spr](docs/formats/spr.md) |
| `sltool tcache` | Extract texture caches to PNG | [tcache](docs/formats/tcache.md) |
| `sltool fat` | Extract `.fat` sound banks to WAV | [fat](docs/formats/fat.md) |
| `sltool fnt` | Render `.fnt` bitmap fonts into glyph atlases | [fnt](docs/formats/fnt.md) |
| `sltool dte` | Disassemble `.DTE` mission bytecode | [dte](docs/formats/dte.md) |
| `sltool stats` | Parse ship, weapon, and pilot stat tables | [stats](docs/formats/stats.md) |
| `sltool render` | Render 3D ship models with the software reference renderer | [renderer](docs/port/renderer.md) |

---

## Repository Layout

| Directory | Contents |
|---|---|
| `src/openreliant/` | Main application entry point, CLI parser, and installer. |
| `src/engine/` | Reimplemented engine modules mirroring original source layout. |
| `src/platform/` | Platform abstraction layer: SDL3, Vulkan/Metal GPU backend, audio, and inputs. |
| `src/formats/` | Parsers and decoders for StarLancer file formats. |
| `src/tools/sltool/` | Command-line asset inspection and extraction tool. |
| `src/tools/tablegen/` | Generates static engine lookup tables from the original executable. |
| `docs/` | Documentation (see [docs/README.md](docs/README.md)). |
| `ghidra/` | Ghidra scripts, symbol annotations, and type maps. |

---

## License

Copyright 2026 the OpenReliant contributors.

- Source code is licensed under the [Mozilla Public License 2.0](LICENSE).
- Documentation under `docs/` is licensed under [Creative Commons Attribution-ShareAlike 4.0](docs/LICENSE).
- Statically linked libraries: [OpenAL Soft](https://github.com/kcat/openal-soft) is licensed under the GNU LGPL 2.1.
