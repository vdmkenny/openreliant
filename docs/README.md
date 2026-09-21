# Documentation

Reference notes on StarLancer (Digital Anvil / Microsoft, 2000; developed by Warthog) and on this
repository's tooling. Everything here is derived from static analysis of a legally owned copy. No
game code or assets are stored in this repository.

| Path | Contents |
|---|---|
| [`toolchain.md`](toolchain.md) | What `make setup` installs and how the targets fit together. |
| [`binary/executables.md`](binary/executables.md) | The shipped binaries, the middleware they are built on, and where each lives. |
| [`binary/safedisc.md`](binary/safedisc.md) | The SafeDisc 1 copy protection and how the payload executable is recovered from it. |
| [`formats/disc-images.md`](formats/disc-images.md) | Raw CD image layout and the ISO 9660 / Joliet filesystem on the two discs. |
| [`formats/hog.md`](formats/hog.md) | `.HOG` asset archives: the EA `BIGF` container. |
| [`formats/refpack.md`](formats/refpack.md) | RefPack, the compression used inside them. |
| [`formats/shp.md`](formats/shp.md) | `.SHP` 3D models: chunk stream, parts, levels of detail, geometry. |
| [`formats/dte.md`](formats/dte.md) | `.DTE` missions: the 27-section image, ships, triggers and conditions. |
| [`formats/spr.md`](formats/spr.md) | `.SPR` sprites: the WinVFX 2D interface imagery, and where model textures are not. |
| [`formats/stats.md`](formats/stats.md) | The ship, gun, missile and pilot stat tables, as the engine's loaders read them. |

## Conventions

Addresses are virtual addresses for the payload executable's image base of `0x400000` unless
stated otherwise. Function names of the form `FUN_<address>` are Ghidra placeholders: the shipped
binaries carry no symbols.

Claims are marked where they are not directly verified:

- **Unknown:** not yet determined.
- **Unverified:** inferred from surrounding evidence but not confirmed.
