# Toolchain & Reverse Engineering Workflow

OpenReliant uses an automated toolchain based on **Ghidra** and custom code generators to analyze the original StarLancer executable, extract static data tables, and maintain symbolic annotations.

Running `make setup` installs all necessary tooling into the git-ignored `tools/` directory.

---

## Prerequisites

| Tool | Purpose |
|---|---|
| **Zig 0.16** | Compiles OpenReliant, `sltool`, and code generators in `src/`. |
| **`uv`** | Manages Python environments for the `ghydra` CLI and MCP bridge. |
| **C++ Toolchain** | Compiles Ghidra's native decompiler binaries (Xcode command-line tools on macOS; GCC/Clang on Linux). |
| **Gradle 8.5+** | Builds Ghidra's native decompiler components. |

Run `make doctor` to inspect installed tools and environment status.

---

## Toolchain Setup (`make setup`)

`make setup` installs the following components locally into `tools/`:

- **Eclipse Temurin JDK 21**: Required runtime for Ghidra.
- **Ghidra**: Downloaded and verified against official SHA-256 checksums, with native decompiler binaries built for your host architecture.
- **GhydraMCP**: Installs the Ghidra plugin and command-line bridge to expose Ghidra's analysis API over HTTP (port 8192).

Setup targets create timestamp markers under `tools/.stamps/`, ensuring repeated runs only execute missing steps.

---

## Ghidra Workflow

The Ghidra project is stored at `ghidra/projects/starlancer.gpr` (git-ignored because it contains disassembled game code). Target binaries are organized into groups:

| Group | Binaries Analyzed |
|---|---|
| `game` | Decrypted game executable (`LANCER.EXE`) and localized resources (`LANGUAGE.DLL`). |
| `surrender` | 3D rendering drivers (`srd3d.dll`, `srddraw.dll`). |
| `vfx` | WinVFX system abstraction library (`winvfx.dll`). |

### Common Analysis Commands

```bash
# Headless import and automated analysis of all binaries
make ghidra-import

# Export disassembly, decompiled C, and segment data to ghidra/export/
make ghidra-export

# Apply symbol annotations, function names, and data types
make ghidra-annotate

# Open the project in the Ghidra graphical user interface
make ghidra-gui

# Execute a headless Ghidra script
make ghidra-run SCRIPT=DefineFunctions.java ARGS="0x00405010 ..." GROUP=game
```

*Note: Ghidra projects support single-user access only. Close the Ghidra GUI before running headless make targets, and vice versa.*

---

## Annotation & Type Synchronization

Running `make ghidra-annotate`:
1. Generates Ghidra C types from Zig definitions in [`src/engine.zig`](../src/engine.zig) and [`src/formats/dte.zig`](../src/formats/dte.zig) using `src/tools/ghidragen`.
2. Applies function names, data structures, and comments from version-controlled TSV symbol maps:
   - [`ghidra/names/LANCER.EXE.tsv`](../ghidra/names/LANCER.EXE.tsv): Manually identified game functions and data.
   - [`ghidra/names/LANCER.EXE.runtime.tsv`](../ghidra/names/LANCER.EXE.runtime.tsv): Statically linked C runtime functions ([`docs/binary/runtime.md`](binary/runtime.md)).
   - [`ghidra/names/srd3d.dll.tsv`](../ghidra/names/srd3d.dll.tsv): Direct3D renderer functions.
3. Automatically maps jump tables for mission script opcodes, executor commands, and AI maneuvers.
4. Generates the source tree hierarchy in Ghidra ([`ApplySources.java`](../ghidra/scripts/ApplySources.java)) matching reconstructed source file boundaries ([`docs/binary/sources.md`](binary/sources.md)).

---

## Automated Table Generation (`src/tools/tablegen`)

Static data tables within the engine are extracted directly from the decrypted binary and decompiled exports, ensuring fidelity with the original retail game:

| Target | Generated Module | Extracted Data |
|---|---|---|
| `make vm-opcodes` | `src/engine/vm/opcodes.zig` | Mission script bytecode opcodes and jump targets. |
| `make vm-commands` | `src/engine/game/executor/commands.zig` | Script executor command table. |
| `make vm-conditions` | `src/engine/vm/conditions.zig` | Mission trigger condition handlers. |
| `make model-tables` | `src/engine/game/create/models.zig` | Ship model definitions and attachment slots. |
| `make combat-tables` | `src/engine/game/create/combat.zig` | Ship combat ratings, factions, and targeting flags. |
| `make control-tables` | `src/engine/input/controls.zig` | Input action catalog and default key/joystick bindings. |
| `make order-tables` | `src/engine/game/ai/orders.zig` | AI order dispatch table. |
| `make maneuver-tables` | `src/engine/game/aidefend/maneuvers.zig` | AI dogfighting maneuver scripts. |
| `make source-map` | `src/engine/sources.zig` | Address ranges mapped to original C++ source files. |

All generated tables are committed to git; compiling OpenReliant or running tests does not require the game binary or Ghidra installation.
