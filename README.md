# starlancer-decomp

Reverse engineering of **StarLancer** (Digital Anvil / Microsoft, 2000; developed by Warthog),
working toward a source-level understanding of the engine and a port to modern systems.

Tools are written in Zig; `make` drives the toolchain, the extraction and the analysis.

<p align="center">
  <img src="docs/images/predator-wireframe.svg" width="560"
       alt="Wireframe of the Predator light fighter, exported from its .SHP model">
</p>
<p align="center">
  <sub>The Predator light fighter, read out of <code>USLF_Prd.SHP</code> by <code>sltool shp obj</code>.</sub>
</p>

> You must own a copy of the game. This repository contains no game code, assets or disc images,
> and none are ever committed: `game/`, `ghidra/projects/` and `ghidra/export/` are git-ignored.
> Work derived from the game, such as the wireframe above, is fine; the game's own files are not.

## Getting started

```bash
make setup     # JDK, Ghidra with native decompiler, GhydraMCP, into tools/
make build     # build sltool into zig-out/bin
make doctor    # report what is in place
```

Then supply the game, from your own discs. Put an image of each at `game/discs/disc1.bin` and
`disc2.bin` (a raw `.bin` of 2352-byte sectors, or an `.iso`; a `.zip` containing one works too),
and unpack them:

```bash
make game      # extract both discs, unpack the installer, decrypt the payload executable
```

That produces `game/cd1/`, `game/cd2/`, `game/install/` and `game/decrypted/LANCER.EXE`, the
readable game binary. Load it into Ghidra:

```bash
make ghidra-import    # import and auto-analyse, headless
make ghidra-export    # dump strings, functions, disassembly and C under ghidra/export/
make ghidra-gui       # open the project
```

`make help` lists every target.

## What is here

The shipped `LANCER.EXE` is a SafeDisc 1 loader; the game is the encrypted `LANCER.ICD` beside it.
`sltool safedisc` decrypts it from the files alone, with no disc access and without running the
loader, by a 32-bit key search that takes about 20 seconds. It also recovers the names of the 129
`kernel32` and `user32` imports SafeDisc hides, but not their order, which SafeDisc shuffles, so it
does not write them back.

| Command | Reads | Doc |
|---|---|---|
| `sltool cd` | Raw CD images and their ISO 9660 filesystem | [disc-images](docs/formats/disc-images.md) |
| `sltool safedisc` | The protected executable | [safedisc](docs/binary/safedisc.md) |
| `sltool hog` | `.HOG` archives and their RefPack compression | [hog](docs/formats/hog.md), [refpack](docs/formats/refpack.md) |
| `sltool shp` | `.SHP` models; exports Wavefront OBJ | [shp](docs/formats/shp.md) |
| `sltool spr` | `.SPR` interface sprites; exports indexed PNG | [spr](docs/formats/spr.md) |
| `sltool dte` | `.DTE` missions, including a disassembler for their script | [dte](docs/formats/dte.md) |
| `sltool stats` | Ship, gun, missile and pilot stat tables | [stats](docs/formats/stats.md) |

`make assets`, `models` and `sprites` run the extractors over every file; `check-models` and
`check-missions` validate them. The script VM's opcode table is derived from the game binary by
`src/tools/vmgen` (`make vm-opcodes`).

Documentation index: [`docs/README.md`](docs/README.md).

## Layout

| Path | Contents |
|---|---|
| `src/formats/` | The `starlancer` module: readers for the game's formats and containers. |
| `src/tools/sltool/` | `sltool`, the command line front end. |
| `src/tools/vmgen/` | Derives the script VM's opcode table from the game binary. |
| `mk/`, `scripts/` | Makefile fragments and their helpers. |
| `ghidra/scripts/` | Ghidra scripts, run headless by `make`. |
| `docs/` | Reference documentation. |
| `tools/`, `game/`, `references/` | Git-ignored: toolchain, game files, other projects read for reference. |

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
