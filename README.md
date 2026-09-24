# OpenReliant

OpenReliant is an open-source, faithful reimplementation of the engine of **StarLancer**, the space
combat game developed by Warthog and Digital Anvil and published by Microsoft in 2000. It's written
in Zig on SDL3 and renders with Vulkan (Metal on macOS) through SDL's GPU API. It runs on Linux,
Windows and macOS using the files from your copy of the game, and the repository documents how the
original works. To play it, follow [Installing and playing](#installing-and-playing).

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

OpenReliant is in early development. Right now you can fly any ship from the game, with the
keyboard, a joystick or a gamepad, in a sandbox with the game's starfield, nebula and sun: the
Reliant crawls past, and a wing of Coalition fighters comes at you and fights with the game's own
combat maneuvers. They pursue you, dodge, loop and break away, and fire when they have you lined up.
The flight model, throttle, afterburner and camera views (keys 1 to 8) are ported, including the
cockpit view with the ship's cockpit model. Press F2 and F3 to switch ships, and F4 for another
wing.

Ships are solid: fly into a fighter and you both come off it, and fly into the Reliant and you hit
its hull where you meet it. A knock costs you shields and armour, and the damage tells on your
speed, your shields and your guns' charge.

Parts of the HUD work: the targeting cluster, radar, status lights, readouts, and the ECM, spectral
shield and blind fire toggles. The HUD panels (gunnery, damage, power and so on) open and close
with their keys but don't show anything yet.

Your ship carries the guns its model holds. Hold the fire key and they fire, drawing on the gun
charge the power ball feeds, at the rate and cost their type has in the game's own data. The shots
fly, each gun type drawn as the game draws it, and a fighter you hit loses its shields and then its
armour. Once its armour is gone it's destroyed: it spins out and blows up, bursts, or stops dead,
with the game's fireballs, flying wreckage, shockwaves and explosion sounds. When yours goes, you
eject and the camera watches your ship's end, and the sandbox starts again. Shots still pass through
capital ships. How hard hits land follows the game's difficulty, medium by default;
`--difficulty easy` or `--difficulty hard` changes it.

You hear it as the game sounds: your guns and theirs, your engine rising with the throttle and
roaring on afterburner, fighters sweeping past, and the game's music. The sounds are placed around
you, in surround where you have the speakers for it, with a light reverb and a compressor that
keeps loud fights clean; on headphones they are placed for headphones. `--music` picks
another piece from the game's `music` folder, or `none`; `--no-sound` turns it all off, and
`--original` plays the sound plainly, as the original mixed it.

There are no missiles or missions yet. The radio's voices and the
display's beeps are still silent. See the [milestones](../../milestones) for what's planned.

## Installing and playing

OpenReliant plays the files of StarLancer, which it installs from your own discs.

1. **Get OpenReliant.** Download the archive for your system from the
   [latest release](../../releases/latest) and extract it. You get a folder with `openreliant` in it
   (`openreliant.exe` on Windows).
2. **Open a terminal in that folder.** On Windows, right-click inside the folder in Explorer and
   choose *Open in Terminal*. On macOS, right-click the folder in Finder and choose *Services* and
   then *New Terminal at Folder*. On Linux, most file managers have *Open in Terminal* in the
   right-click menu.
3. **On macOS only,** allow the download to run. The builds aren't signed, so macOS blocks them
   until you run this once:

   ```bash
   xattr -d com.apple.quarantine openreliant
   ```

4. **Install the game's files.** Put StarLancer disc 1 in the drive and run:

   ```bash
   ./openreliant install StarLancer
   ```

   On Windows, type `.\openreliant.exe` wherever these steps say `./openreliant`. The installer
   finds the disc by itself, installs from it, and then asks for disc 2. It puts the game's files,
   about 1.2 GB, in a new folder called `StarLancer`. Any other folder name or path works too.
   Without disc 2 at hand, type `skip` when asked for it: running the installer again later with
   disc 2 in the drive adds it.

   If you have images of the discs instead, `.bin` or `.iso` files, or folders with the discs'
   files, tell the installer where they are with `--from`, once for each disc. For a `.bin` with a
   `.cue` next to it, name the `.bin`:

   ```bash
   ./openreliant install --from "StarLancer Disc 1.bin" --from "StarLancer Disc 2.bin" StarLancer
   ```

   If the installer says it doesn't know your disc, for example because it's from another
   country's release, add `--force` to install from it anyway. Please also
   [open an issue](../../issues/new) saying which release you have and the size the installer
   gives for `LANCER.CAB`, so we can add it.
5. **Play.**

   ```bash
   ./openreliant StarLancer
   ```

The manual is on disc 2 as `DOCS/MAUNAL.PDF` (misspelled on the disc), and the quick reference
card as `DOCS/QRC.PDF`.

### Joysticks and gamepads

OpenReliant supports joysticks and gamepads, including flight sticks, HOTAS sets, old gameport
sticks on USB adapters, and Xbox, PlayStation, Nintendo and most other controllers. See
[Joysticks and gamepads](docs/controllers.md) for the default controls and how to set up your
controller.

OpenReliant draws with the GPU at the display's own resolution, with anti-aliasing and sharper
texture filtering than the original had; `--original` restores the original's look and sound.
`openreliant --help` lists the options and keys; [Platform](docs/port/platform.md) has them too,
and
[how the installer works](docs/port/platform.md#installing-the-games-files).

### Building from source

You only need [Zig](https://ziglang.org) 0.16; SDL3, OpenAL Soft and libarchive are built as part
of the build.

```bash
zig build -Doptimize=ReleaseFast
zig-out/bin/openreliant install StarLancer
zig-out/bin/openreliant StarLancer
```

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

The executables link [OpenAL Soft](https://github.com/kcat/openal-soft) statically, which is
licensed under the GNU Lesser General Public License 2.1. The build fetches its source at the
version [`deps/openal-soft`](deps/openal-soft/build.zig.zon) pins; building this repository against
a changed copy of it relinks the executables with your own.

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
