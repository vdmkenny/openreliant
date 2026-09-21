# Documentation

Reference notes on StarLancer (Digital Anvil / Microsoft, 2000; developed by Warthog) and on this
repository's tooling, derived from static analysis of a legally owned copy. The repository stores
no game code or assets.

| Path | Contents |
|---|---|
| [`toolchain.md`](toolchain.md) | What `make setup` installs, and the Ghidra workflow. |
| [`binary/executables.md`](binary/executables.md) | The shipped binaries and the middleware they are built on. |
| [`binary/safedisc.md`](binary/safedisc.md) | SafeDisc 1, and recovering the game executable from it. |
| [`formats/disc-images.md`](formats/disc-images.md) | Raw CD images and the discs' ISO 9660 filesystem. |
| [`formats/hog.md`](formats/hog.md) | `.HOG` archives: EA's `BIGF` container. |
| [`formats/refpack.md`](formats/refpack.md) | RefPack, the compression inside them. |
| [`formats/shp.md`](formats/shp.md) | `.SHP` models: chunks, parts, levels of detail, geometry, coordinate frame. |
| [`formats/spr.md`](formats/spr.md) | `.SPR` sprites: the WinVFX interface imagery. |
| [`formats/fat.md`](formats/fat.md) | `.fat` sound banks. |
| [`formats/dte.md`](formats/dte.md) | `.DTE` missions: directory, ships, triggers, and the script VM. |
| [`formats/stats.md`](formats/stats.md) | Ship, gun, missile and pilot stat tables. |

## Conventions

Addresses are virtual addresses for the payload executable's image base of `0x400000` unless
stated otherwise. Function names of the form `FUN_<address>` are Ghidra placeholders: the shipped
binaries carry no symbols.

Claims are marked where they are not directly verified:

- **Unknown:** not yet determined.
- **Unverified:** inferred from surrounding evidence but not confirmed.
