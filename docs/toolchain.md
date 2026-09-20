# Toolchain

`make setup` installs everything this project needs into `tools/`, which is git-ignored. Nothing is
installed system-wide and nothing outside the repository is modified, with one exception noted
under [Ghidra](#ghidra).

## Prerequisites

| Tool | Used for |
|---|---|
| Zig 0.16 | Building `sltool` and everything else in `src/`. |
| `7z` | Unpacking `LANCER.CAB`, which is LZX-compressed. |
| `uv` | Creating the virtualenv for the `ghydra` CLI and MCP bridge. |
| A C++ toolchain | Compiling Ghidra's native helpers. On macOS, the Xcode command line tools. |
| Gradle 8.5+ | Driving that native build. |

`make doctor` reports which of these, and which build products, are present.

## What `make setup` installs

| Target | Installs |
|---|---|
| `make jdk` | Eclipse Temurin JDK 21, the minimum Ghidra 12 accepts. |
| `make ghidra` | Ghidra, verified against its published SHA-256, plus native helpers. |
| `make ghydra` | The GhydraMCP Ghidra plugin and the `ghydra` CLI. |

Versions are pinned in [`mk/config.mk`](../mk/config.mk) and can be overridden on the command line,
for example `make setup GHIDRA_VERSION=12.1.2 GHIDRA_DATE=... GHIDRA_SHA256=...`.

Each step writes a stamp under `tools/.stamps/`, so re-running `make setup` does only what is
missing. Downloaded archives are order-only prerequisites: re-fetching one never forces a rebuild.

### Ghidra

Ghidra's release archives contain native binaries for Windows and Linux x86-64 only. On any other
host, including Apple Silicon, the decompiler and demangler must be compiled locally, which is what
`make ghidra` does via Ghidra's own `support/gradle/buildNatives`. Without them the decompiler
cannot run at all.

`make ghidra` also sets `JAVA_HOME_OVERRIDE` in `support/launch.properties`, so Ghidra starts with
the project JDK even when launched outside of make.

### GhydraMCP

[GhydraMCP](https://github.com/starsong-consulting/GhydraMCP) exposes an open Ghidra program over
an HTTP API, which the `ghydra` CLI and an MCP client can drive. Its Ghidra plugin is version
locked: the extension's `ghidraVersion` must equal the Ghidra version exactly, and the published
releases are built against other versions. `make ghydra` therefore builds the plugin from source
against the pinned Ghidra.

Installing it touches one path outside the repository, the per-user Ghidra settings directory
(`~/Library/ghidra/ghidra_<version>_PUBLIC` on macOS,
`~/.config/ghidra/ghidra_<version>_PUBLIC` elsewhere):

- `Extensions/Ghydra/` receives the built plugin, which is what `File > Install Extensions` would
  do.
- `tools/_code_browser.tcd` is written with the plugin already enabled, so a fresh install serves
  the API without anyone opening `File > Configure`. An existing file is never overwritten.

The plugin listens on port 8192, one port per open program. [`.mcp.json`](../.mcp.json) registers
the MCP bridge for Claude Code. `make ghydra-status` lists the instances the CLI can reach.

## Working with Ghidra

The project lives at `ghidra/projects/starlancer.gpr` and is git-ignored: it embeds the game's
code. Programs are grouped into project folders, one group per make target:

| Group | Programs |
|---|---|
| `game` | The decrypted payload executable and `LANGUAGE.DLL`. |
| `safedisc` | The loader and its support DLLs. |
| `surrender` | The renderer DLLs. |
| `vfx` | WinVFX and the system abstraction layer. |

```bash
make ghidra-import           # import and auto-analyse every group, headless
make ghidra-import-game      # or just one group
make ghidra-export           # dump each program as greppable text under ghidra/export/
make ghidra-gui              # open the project
```

Imports are one-shot by construction: every prerequisite is order-only, `-overwrite` is never
passed, and a stamp records that a group has been imported. Nothing in the Makefile can replace a
program that has been annotated by hand. To deliberately re-import, run `make ghidra-forget-<group>`
and delete the folder in the GUI first.

The Ghidra project is single-user. Close the GUI before running a headless target, and vice versa.

`ghidra-export` runs [`ghidra/scripts/ExportProgram.java`](../ghidra/scripts/ExportProgram.java),
which writes per program: `segments.tsv`, `imports.tsv`, `exports.tsv`, `strings.tsv`,
`functions.tsv`, `disassembly.asm` and `decompiled.c`. That output is derived from the game and is
git-ignored.
