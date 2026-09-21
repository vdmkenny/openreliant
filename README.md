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

The shipped `LANCER.EXE` is a SafeDisc 1 loader, not the game; the game is the encrypted
`LANCER.ICD` beside it. `sltool safedisc` recovers a readable image from the files alone, with no
disc access and without running the loader: the sections are TEA-ECB encrypted under a 128-bit key
whose four words are equal, which leaves a 32-bit search that takes about 20 seconds. See
[`docs/binary/safedisc.md`](docs/binary/safedisc.md).

The same wrapper empties the `kernel32` and `user32` import tables. `sltool safedisc imports`
recovers the 129 API names from the file (XORed thunks, a zeroed first slot, and chain-XOR
encrypted strings), but SafeDisc also shuffles the thunks, so which slot holds which API is not
recoverable from the table and is left unresolved rather than guessed.

`sltool cd` reads the raw 2352-byte-sector disc images and their ISO 9660 filesystem directly, so
extracting the discs needs no mounting or conversion. See
[`docs/formats/disc-images.md`](docs/formats/disc-images.md).

`sltool hog` reads the `.HOG` asset archives (EA's `BIGF` container) and decompresses the RefPack
members inside them: `make assets` unpacks `resource.hog` into 967 models, sprites, images,
missions and stat tables. See [`docs/formats/hog.md`](docs/formats/hog.md) and
[`docs/formats/refpack.md`](docs/formats/refpack.md).

`sltool shp` reads the `.SHP` models and exports them as Wavefront OBJ: `make models` converts all
440 ships, stations and weapons, and `make check-models` validates them. See
[`docs/formats/shp.md`](docs/formats/shp.md).

`sltool spr` reads the `.SPR` sprite sets, the WinVFX 2D imagery behind the HUD, menus and ship
schematics, and saves their 3,724 shapes as indexed PNG: `make sprites`. See
[`docs/formats/spr.md`](docs/formats/spr.md).

`sltool dte` reads the 44 `.DTE` missions: their ships, triggers, globals, string pools and script
bytecode. The mission scripting VM's instruction set is derived from the game binary rather than
guessed: `src/tools/vmgen` reads the dispatch table and symbolically executes each handler to
recover every opcode's size and control flow, which decodes all 44 missions' opening blocks end to
end. See [`docs/formats/dte.md`](docs/formats/dte.md).

Documentation index: [`docs/README.md`](docs/README.md).

## Layout

| Path | Contents |
|---|---|
| `src/formats/` | The `starlancer` module: readers for the game's formats and containers. |
| `src/tools/sltool/` | `sltool`, the command line front end. |
| `src/tools/vmgen/` | Derives the script VM's opcode table from the game binary. |
| `mk/`, `scripts/` | Makefile fragments and their helpers. |
| `ghidra/scripts/` | Ghidra scripts, run headless by `make ghidra-export`. |
| `docs/` | Reference documentation. |
| `tools/`, `game/`, `references/` | Git-ignored: toolchain, game files, other projects read for reference. |

## Related projects

Independent reverse engineering of the same game, read for cross-reference. No code from either is
used here.

- [LordBlacksun/Starlancer-OSS](https://github.com/LordBlacksun/Starlancer-OSS): format
  documentation, modern-Windows patches and editors, in Python.
- [mini/starlancereditor](https://src.ug.gg/mini/starlancereditor): a .NET library and tools for
  the archive, mission and save formats.
- [DMJC/neoslancer](https://github.com/DMJC/neoslancer) and
  [DMJC/StarLanceDecomp](https://github.com/DMJC/StarLanceDecomp): a C++/SDL2 port and its
  reverse-engineering notes.
