# OpenReliant

OpenReliant is an open-source reimplementation of the space combat game **StarLancer**, originally developed by Warthog and Digital Anvil and published by Microsoft in 2000.

Written in Zig on SDL3, it renders with Vulkan (Metal on macOS) through SDL's GPU API. It runs natively on Linux, Windows and macOS using the files from your own copy of the game. For player setup, see the [user guide](docs/guide/README.md) or follow [Installing and playing](#installing-and-playing) below.

<p align="center">
  <img src="docs/images/predator-wireframe.svg" width="560"
       alt="Wireframe of the Predator light fighter, exported from its .SHP model">
</p>

## Legal

OpenReliant is an independent project. It is not affiliated with, endorsed by, or associated with Warthog Games, Digital Anvil or Microsoft. StarLancer is a trademark of its owner, named here only to identify the game OpenReliant runs.

This repository holds none of the game's files: no models, textures, sprites, sounds, music, videos, fonts, executables or archives. OpenReliant reads them from an installed, legally obtained copy of StarLancer, which you must provide; without one it does nothing but report the missing files. We do not support or condone piracy.

## Status

OpenReliant is in early development. You can fly any ship from the game using a keyboard, joystick or gamepad in a sandbox with the game's starfield, nebula and sun. The Reliant crawls past while a wing of Coalition fighters engages you using the game's own combat maneuvers: they pursue you, dodge, loop and break away, and fire when they have you lined up. The flight model, throttle, afterburner, missiles, countermeasures and camera views (keys 1 to 8) are ported, including the cockpit view with the ship's 3D cockpit model. Press F2 and F3 to switch ships, and F4 to spawn another wing.

Ships have solid collision: fly into a fighter and both ships bounce off each other, or fly into the Reliant to collide with its hull. Collisions damage shields and armour, and the damage reduces your speed, shields and gun recharge rate.

Parts of the HUD work: the targeting cluster, radar, status lights, readouts, and toggles for ECM, spectral shield and blind fire. The missile window works, and other HUD panels (gunnery, damage, power and related windows) open and close with their keys but do not display data yet.

Your ship carries the guns defined on its model. Holding the fire key fires them, drawing from the gun charge supplied by the power distribution ball, at the rate and energy cost defined in the game's data. Shots fly and render as the game draws them, and hitting a fighter strips its shields and then its armour. Once its armour is gone it is destroyed: it spins out and blows up, bursts, or stops dead, accompanied by fireballs, flying wreckage, shockwaves and explosion sounds. When your ship is destroyed, you eject while the camera watches your ship explode, and the sandbox restarts. Shots pass through capital ships for now. Hit damage scales with the difficulty setting, which defaults to medium; `--difficulty easy` or `--difficulty hard` changes it.

Positional sound matches the original game: your guns and enemy fire, your engine rising with throttle and roaring on afterburner, passing fighters, and game music. Sounds are placed around you in 3D surround sound where supported, with light reverb and a compressor that keeps loud combat clean; on headphones, audio uses HRTF. `--music` selects another track from the `music` folder, or `none`; `--no-sound` turns audio off, and `--original` plays sound with the original plain stereo mix.

Missions are not ported yet. The radio voices are still silent. See the [milestones](../../milestones) for planned work.

## Installing and playing

OpenReliant runs the files of StarLancer, which it installs from your own discs. For more details, see the [installation guide](docs/guide/installation.md).

1. **Get OpenReliant.** Download the archive for your system from the [latest release](../../releases/latest) and extract it. You get a folder containing `openreliant` (`openreliant.exe` on Windows).
2. **Open a terminal in that folder.** On Windows, right-click inside the folder in Explorer and choose *Open in Terminal*. On macOS, right-click the folder in Finder and choose *Services* and then *New Terminal at Folder*. On Linux, most file managers provide *Open in Terminal* in the right-click menu.
3. **On macOS only,** allow the download to run. The builds are not signed, so macOS blocks them until you run this once:

   ```bash
   xattr -d com.apple.quarantine openreliant
   ```

4. **Install the game's files.** Put StarLancer disc 1 in the drive and run:

   ```bash
   ./openreliant install StarLancer
   ```

   On Windows, type `.\openreliant.exe` wherever these steps say `./openreliant`. The installer detects the disc automatically, installs from it, and then prompts for disc 2. It places the game's files, about 1.2 GB, in a new folder called `StarLancer`. Any other folder name or path works too. If you do not have disc 2 at hand, type `skip` when prompted: running the installer again later with disc 2 in the drive adds it.

   If you have disc images instead (`.bin` or `.iso` files), or folders containing the discs' files, provide their locations with `--from`, once for each disc. Each disc is optional and the two can come in either order; disc 2 alone adds to an existing install. For a `.bin` with a `.cue` next to it, specify the `.bin`:

   ```bash
   ./openreliant install --from "StarLancer Disc 1.bin" --from "StarLancer Disc 2.bin" StarLancer
   ```

   If the installer reports that it does not recognize your disc (for example, with a release from another region), add `--force` to install from it anyway. Please also [open an issue](../../issues/new) noting which release you have and the size the installer reports for `LANCER.CAB`, so we can add it.
5. **Play.**

   ```bash
   ./openreliant StarLancer
   ```

   The game starts in its pause menu, where audio and video settings can be adjusted; CONTINUE, or Escape, starts flying, and Escape reopens the menu. LEAVE MISSION quits, and RESTART restarts the sandbox.

The manual is on disc 2 as `DOCS/MAUNAL.PDF` (misspelled on the disc), and the quick reference card as `DOCS/QRC.PDF`.

### Joysticks and gamepads

OpenReliant supports joysticks and gamepads, including flight sticks, HOTAS setups, legacy gameport sticks on USB adapters, and Xbox, PlayStation, Nintendo and most other controllers. See [Controllers and input](docs/guide/controllers.md) for default controls and configuration options.

OpenReliant renders with the GPU at your display's native resolution, with anti-aliasing and sharper texture filtering than the original; `--original` restores the original visual and audio presentation. `openreliant --help` lists all options and keys; [Platform](docs/port/platform.md) also covers them, along with [how the installer works](docs/port/platform.md#installing-the-games-files).

### Building from source

You only need [Zig](https://ziglang.org) 0.16; SDL3, OpenAL Soft and libarchive build automatically as part of the build:

```bash
zig build -Doptimize=ReleaseFast
zig-out/bin/openreliant install StarLancer
zig-out/bin/openreliant StarLancer
```

## How it works

The engine follows the game's original design, reimplemented in Zig one module at a time and structured to mirror the original source tree, with SDL3 replacing Win32, DirectDraw, Direct3D 7 and DirectInput. It reads game files directly where they are installed: archives, compression, models, textures and missions decode in memory as the game decodes them, without extracting or converting assets beforehand. Behaviour matches the original; deliberate changes, such as rendering at modern resolutions, are documented as improvements ([Renderer](docs/port/renderer.md)).

## Studying the game

The repository also includes tools and documentation supporting the reverse engineering effort. `make` runs them:

```bash
make setup     # JDK, Ghidra with its native decompiler, GhydraMCP, into tools/
make build     # build tools into zig-out/bin
make test      # run unit tests, which create their own inputs and require no game files
make doctor    # report toolchain status
```

Analysis begins with your retail discs. Place a disc image of each at `game/discs/disc1.bin` and `disc2.bin` (raw `.bin` files with 2352-byte sectors, or `.iso` files; a `.zip` containing either also works), then run:

```bash
make game             # extract both discs and the installer into game/
make ghidra-import    # import the game executable into Ghidra and analyse it, headless
make ghidra-annotate  # apply identified names and types
make ghidra-gui       # open the Ghidra project
make play             # build OpenReliant optimized and run it on game/install
```

Ghidra and the table generators read the game executable, with its code readable, from `game/decrypted/LANCER.EXE`; the repository does not provide one. Everything under `game/` remains on your machine and is git-ignored.

`sltool` inspects and extracts the game's file formats:

| Command | Reads | Documentation |
|---|---|---|
| `sltool cd` | Raw CD images and their ISO 9660 filesystem | [disc-images](docs/formats/disc-images.md) |
| `sltool hog` | `.HOG` archives and RefPack compression | [hog](docs/formats/hog.md), [refpack](docs/formats/refpack.md) |
| `sltool shp` | `.SHP` models; exports Wavefront OBJ; lists an object's components | [shp](docs/formats/shp.md) |
| `sltool spr` | `.SPR` interface sprites; exports indexed PNG | [spr](docs/formats/spr.md) |
| `sltool tcache` | Texture caches for model and effect textures; exports PNG | [tcache](docs/formats/tcache.md) |
| `sltool fat` | `.fat` sound banks; exports WAV | [fat](docs/formats/fat.md) |
| `sltool fnt` | `.fnt` bitmap fonts; renders glyph atlases | [fnt](docs/formats/fnt.md) |
| `sltool dte` | `.DTE` missions, including a bytecode disassembler | [dte](docs/formats/dte.md) |
| `sltool stats` | Ship, gun, missile and pilot stat tables | [stats](docs/formats/stats.md) |
| `sltool render` | Draws a model against the backdrop through the engine's renderer, as PNG | [renderer](docs/port/renderer.md) |

`make assets`, `models`, `sprites`, `textures`, `sounds` and `fonts` extract assets into `game/`; `check-models` and `check-missions` validate them. The script VM opcode, command and condition tables, model tables, control bindings, order table and combat maneuvers are derived from the game executable by `src/tools/tablegen`, as is the mapping of which source file compiled each stretch of code; `make help` lists available targets.

The [documentation](docs/README.md) covers file formats, the executable, and the engine.

## Keeping the game's files out

No assets or binaries from the game are ever committed. `make hooks` installs a pre-commit hook that rejects game files, `make check-files` checks each commit, and CI runs the same verification on every push. The check rejects game file types, executable, archive, image and audio signatures, binary data outside of compiled shaders, and any file exceeding 1 MiB.

## Layout

| Path | Contents |
|---|---|
| `src/openreliant/` | `openreliant`, the engine executable. |
| `src/engine.zig`, `src/engine/` | The reimplementation, laid out as the original's source tree: `game/`, `surrender/surrenderlib/` and `surrender/srd3d/` mirror `C:\lancer`, a module per original file; `sources.zig` places the code in those files; `libcmt.zig` is the C runtime; `vm.zig` and `input.zig` hold code whose file is unknown. |
| `src/platform.zig`, `src/platform/` | The platform layer: SDL3 in place of Win32 and DirectX, and the GPU renderer shader. |
| `src/formats/` | Parsers for the game's file formats and containers. |
| `src/tools/sltool/` | `sltool`, the command-line utility for inspecting game formats. |
| `src/tools/tablegen/` | Derives the engine's static tables from the game executable. |
| `src/tools/ghidragen/` | Generates names and data types applied by Ghidra scripts. |
| `mk/`, `scripts/` | Makefile fragments, helper scripts, and git hooks. |
| `ghidra/scripts/` | Ghidra scripts executed headlessly by `make`. |
| `ghidra/names/` | Names and types for identified functions and data in the game executable and Direct3D driver. |
| `docs/` | Reference documentation. |
| `tools/`, `game/`, `references/` | Git-ignored: the toolchain, game files, and reference material. |

## License

Copyright 2026 the OpenReliant contributors.

The code is licensed under the [Mozilla Public License 2.0](LICENSE): it can be used in any project, open or not, but changes to its files must be shared under the same license. The documentation under `docs/` is licensed under [Creative Commons Attribution-ShareAlike 4.0](docs/LICENSE).

The executables link [OpenAL Soft](https://github.com/kcat/openal-soft) statically, which is licensed under the GNU Lesser General Public License 2.1. The build fetches its source at the version pinned in [`deps/openal-soft`](deps/openal-soft/build.zig.zon); building against a modified copy relinks the executables with your own.

StarLancer, its code and its assets belong to their owners, and neither license covers them. Parts of this repository reproduce content from the game executable, and those parts are not ours to license: tables transcribed from it carry names, descriptions and scripts written by the game's developers, and `docs/images/predator-wireframe.svg` is drawn from the game's own model.

## Related projects

Independent reverse engineering projects for StarLancer, consulted for cross-reference. No code from them is used here:

- [LordBlacksun/Starlancer-OSS](https://github.com/LordBlacksun/Starlancer-OSS): format documentation, modern Windows patches and editors, in Python.
- [mini/starlancereditor](https://src.ug.gg/mini/starlancereditor): a .NET library and tools for archive, mission and save formats.
- [DMJC/neoslancer](https://github.com/DMJC/neoslancer) and [DMJC/StarLanceDecomp](https://github.com/DMJC/StarLanceDecomp): a C++/SDL2 port and reverse engineering notes.
