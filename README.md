# starlancer-decomp

Reverse engineering of **StarLancer** (Digital Anvil / Microsoft, 2000; developed by Warthog),
working toward a source-level understanding of the engine and a port to modern systems.

Tools are written in Zig; `make` drives the toolchain, the extraction and the analysis.

> You must own a copy of the game. This repository contains no game code, assets or disc images,
> and none are ever committed: `game/`, `ghidra/projects/` and `ghidra/export/` are git-ignored.

## Getting started

```bash
make setup     # JDK, Ghidra with native decompiler, GhydraMCP, into tools/
make build     # build sltool into zig-out/bin
make doctor    # report what is in place
```

Then supply the game. Place your own disc images at `game/discs/disc1.bin` and `disc2.bin` (raw
`.bin` or `.iso`), or run `make fetch-game`, and unpack them:

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

`sltool cd` reads the raw 2352-byte-sector disc images and their ISO 9660 filesystem directly, so
extracting the discs needs no mounting or conversion. See
[`docs/formats/disc-images.md`](docs/formats/disc-images.md).

Documentation index: [`docs/README.md`](docs/README.md).

## Layout

| Path | Contents |
|---|---|
| `src/formats/` | The `starlancer` module: readers for the game's formats and containers. |
| `src/tools/sltool/` | `sltool`, the command line front end. |
| `mk/`, `scripts/` | Makefile fragments and their helpers. |
| `ghidra/scripts/` | Ghidra scripts, run headless by `make ghidra-export`. |
| `docs/` | Reference documentation. |
| `tools/`, `game/`, `references/` | Git-ignored: toolchain, game files, other projects read for reference. |

## Related projects

Independent reverse engineering of the same game, read for cross-reference. No code from either is
used here.

- [LordBlacksun/Starlancer-OSS](https://github.com/LordBlacksun/Starlancer-OSS): format
  documentation, modern-Windows patches and editors, in Python.
- [DMJC/neoslancer](https://github.com/DMJC/neoslancer) and
  [DMJC/StarLanceDecomp](https://github.com/DMJC/StarLanceDecomp): a C++/SDL2 port and its
  reverse-engineering notes.
