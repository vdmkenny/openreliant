# OpenReliant

OpenReliant is an open-source reimplementation of the engine of **StarLancer**, the space combat
game developed by Warthog and Digital Anvil and published by Microsoft in 2000. It plays the game's
own files on macOS, Linux and Windows, and documents how the original works.

<p align="center">
  <img src="docs/images/predator-wireframe.svg" width="560"
       alt="Wireframe of the Predator light fighter, exported from its .SHP model">
</p>

## Legal

OpenReliant is an independent project. It is not affiliated with, endorsed by, or associated with
Warthog Games, Digital Anvil or Microsoft. StarLancer is a trademark of its owner, named here only
to say which game OpenReliant plays.

This repository holds none of the game's files: no models, textures, sprites, sounds, music,
videos, fonts, executables or archives. OpenReliant reads them from an installed, legally obtained
copy of StarLancer, which you must provide; without one it does nothing but say so. We do not
support or condone piracy.

## Status

Early, but it flies. OpenReliant is a flying sandbox: pick any of the game's ships and fly it
around an empty stretch of space, with the starfield, nebula and sun from the game's files. The
flight model, throttle and afterburner are ported from the game, and so are the camera views on
keys 1 to 8, including the cockpit, where the ship's cockpit model sways as you turn, and the chase
view. F2 and F3 switch ships.

Much of the HUD is in: the targeting cluster, the radar, the status lights, the readouts, and the
ECM, spectral shields and blind fire switches. The HUD's panels (gunnery, damage, power and the
rest) open and close on their keys, but are still empty.

There are no other ships yet, and no weapons, missions or sound. The
[milestones](../../milestones) track what comes next.

## Running

The [latest release](../../releases/latest) has ready-made builds for Linux, Windows and macOS,
each for x86_64 and arm64: download the one for your system, unpack it, and run `openreliant`.
The macOS builds aren't signed, so macOS refuses to open them at first; run
`xattr -d com.apple.quarantine openreliant` once to allow it.

To build it yourself, OpenReliant needs [Zig](https://ziglang.org) 0.16 and nothing else: SDL3 is
built from source for the target.

```bash
zig build -Doptimize=ReleaseFast
zig-out/bin/openreliant <game-directory>
```

`<game-directory>` is where StarLancer is installed, the directory holding `resource.hog` and
`tcachehw.dat`. It draws with the GPU at the display's own resolution, with anti-aliasing and
sharper texture filtering than the original had; `--original` restores the original's look.
[Platform](docs/port/platform.md) lists the options and keys, and how to build for each system.
The manual is on disc 2 as `DOCS/MAUNAL.PDF` (misspelled on the disc), and the quick reference
card as `DOCS/QRC.PDF`.

## How it works

The engine is the game's own design, reimplemented in Zig a module at a time and laid out as the
original's source tree, with SDL3 in place of Win32, DirectDraw, Direct3D 7 and DirectInput. It
reads the game's files where they are installed: archives, compression, models, textures and
missions are decoded in memory as the game decodes them, and nothing is extracted or converted
first. Behaviour matches the original's; each deliberate difference, such as rendering at modern
resolutions, is documented as an improvement ([Renderer](docs/port/renderer.md)).

## Studying the game

The repository also holds the tools and notes behind the reimplementation. `make` drives them:

```bash
make setup     # JDK, Ghidra with its native decompiler, GhydraMCP, into tools/
make build     # build the tools into zig-out/bin
make test      # run the unit tests, which build their own inputs and need no game files
make doctor    # report what is in place
```

The analysis starts from your own discs. Put an image of each at `game/discs/disc1.bin` and
`disc2.bin` (a raw `.bin` of 2352-byte sectors, or an `.iso`; a `.zip` holding one works too), then:

```bash
make game             # extract both discs and the installer into game/
make ghidra-import    # import the game executable into Ghidra and analyse it, headless
make ghidra-annotate  # apply the names and types identified so far
make ghidra-gui       # open the project
make play             # build OpenReliant optimized and run it on game/install
```

Ghidra and the table generators read the game executable, with its code readable, from
`game/decrypted/LANCER.EXE`; the repository does not provide one. Everything under `game/` stays on
your machine: it is git-ignored.

`sltool` reads the game's formats:

| Command | Reads | Doc |
|---|---|---|
| `sltool cd` | Raw CD images and their ISO 9660 filesystem | [disc-images](docs/formats/disc-images.md) |
| `sltool hog` | `.HOG` archives and their RefPack compression | [hog](docs/formats/hog.md), [refpack](docs/formats/refpack.md) |
| `sltool shp` | `.SHP` models; exports Wavefront OBJ; lists an object's components | [shp](docs/formats/shp.md) |
| `sltool spr` | `.SPR` interface sprites; exports indexed PNG | [spr](docs/formats/spr.md) |
| `sltool tcache` | Texture caches, the models' and effects' textures; exports PNG | [tcache](docs/formats/tcache.md) |
| `sltool fat` | `.fat` sound banks; exports WAV | [fat](docs/formats/fat.md) |
| `sltool fnt` | `.fnt` fonts; renders glyph atlases | [fnt](docs/formats/fnt.md) |
| `sltool dte` | `.DTE` missions, including a disassembler for their script | [dte](docs/formats/dte.md) |
| `sltool stats` | Ship, gun, missile and pilot stat tables | [stats](docs/formats/stats.md) |
| `sltool render` | Draws a model against the backdrop through the engine's renderer, as PNG | [renderer](docs/port/renderer.md) |

`make assets`, `models`, `sprites`, `textures`, `sounds` and `fonts` run the extractors over every
file into `game/`; `check-models` and `check-missions` validate them. The script VM's opcode,
command and condition tables, the model tables, the control bindings, the order table and the
combat maneuvers are derived from the game executable by `src/tools/tablegen`, as is the map of
which source file each stretch of code was compiled from; `make help` lists their targets.

The [documentation](docs/README.md) covers the formats, the executable and the engine.

## Keeping the game's files out

Nothing from the game is ever committed. `make hooks` installs a pre-commit hook that refuses its
files, `make check-files` checks every commit, and CI runs the same check on every push. The check
refuses the game's file types, the signatures of executables, archives, images and sounds, binary
data other than the compiled shaders, and files over 1 MiB.

## Layout

| Path | Contents |
|---|---|
| `src/openreliant/` | `openreliant`, the engine's executable. |
| `src/engine.zig`, `src/engine/` | The reimplementation, laid out as the original's source tree: `game/`, `surrender/surrenderlib/` and `surrender/srd3d/` mirror `C:\lancer`, a module per original file; `sources.zig` places the code in those files; `libcmt.zig` is the C runtime; `vm.zig` and `input.zig` hold code whose file is unknown. |
| `src/platform.zig`, `src/platform/` | The platform layer: SDL3 in place of Win32 and DirectX, and the GPU renderer's shader. |
| `src/formats/` | Readers for the game's file formats and the containers it shipped in. |
| `src/tools/sltool/` | `sltool`, the command line front end to the format readers. |
| `src/tools/tablegen/` | Derives the engine's static tables from the game executable. |
| `src/tools/ghidragen/` | Writes the names and data types the Ghidra scripts apply. |
| `mk/`, `scripts/` | Makefile fragments, their helpers and the git hooks. |
| `ghidra/scripts/` | Ghidra scripts, run headless by `make`. |
| `ghidra/names/` | Names and types for the identified functions and data of the game executable and its Direct3D driver. |
| `docs/` | Reference documentation. |
| `tools/`, `game/`, `references/` | Git-ignored: the toolchain, the game's files, other projects read for reference. |

## License

Copyright 2026 the OpenReliant contributors.

The code is licensed under the [Mozilla Public License 2.0](LICENSE): it can be used in any
project, open or not, but changes to its files are shared under the same license. The
documentation under `docs/` is licensed under
[Creative Commons Attribution-ShareAlike 4.0](docs/LICENSE).

StarLancer, its code and its assets belong to their owners, and neither license covers them. Parts
of this repository reproduce what the game executable contains, and those parts are not ours to
license: the tables transcribed from it carry names, descriptions and scripts the game's developers
wrote, and `docs/images/predator-wireframe.svg` is drawn from the game's own model.

## Related projects

Independent reverse engineering of the same game, read for cross-reference. No code from them is
used here.

- [LordBlacksun/Starlancer-OSS](https://github.com/LordBlacksun/Starlancer-OSS): format
  documentation, modern-Windows patches and editors, in Python.
- [mini/starlancereditor](https://src.ug.gg/mini/starlancereditor): a .NET library and tools for
  the archive, mission and save formats.
- [DMJC/neoslancer](https://github.com/DMJC/neoslancer) and
  [DMJC/StarLanceDecomp](https://github.com/DMJC/StarLanceDecomp): a C++/SDL2 port and its
  reverse-engineering notes.
