# Reconstructed Source File Manifest

The original developer source file structure of StarLancer has been reconstructed by analyzing string literals, assertion paths, and linker order embedded in `LANCER.EXE`.

The mapping is defined in [`src/engine/sources.zig`](../../src/engine/sources.zig), generated via `make source-map`, and applied to Ghidra via [`ApplySources.java`](../../ghidra/scripts/ApplySources.java).

---

## Recovered Source File Paths

Assertion macros embedded in the retail executable preserve full original developer filesystem paths for 77 C++ source files:

| Original Directory | Reconstructed Source Files |
|---|---|
| `C:\lancer\game\` | `Ai.cpp`, `aidefend.cpp`, `aidock.cpp`, `aifight.cpp`, `aifuncs.cpp`, `aigeneric.cpp`, `aiioncan.cpp`, `ailand.cpp`, `airipper.cpp`, `jump.cpp`, `launch.cpp`, `tractor.cpp`, `wgate.cpp`, `interface.cpp`, `itac.cpp`, `videoreports.cpp`, `Executor.cpp`, `mission.cpp`, `attach.cpp`, `camera.cpp`, `cbox.cpp`, `cloak.cpp`, `collision.cpp`, `Create.cpp`, `environfx.cpp`, `erayfx.cpp`, `explode.cpp`, `gameflow.cpp`, `gameobj.cpp`, `guns.cpp`, `hog_gen.cpp`, `hog_SND.CPP`, `hud.cpp`, `hudmovie.cpp`, `language.cpp`, `main.cpp`, `matmanager.cpp`, `missiles.cpp`, `nebula.cpp`, `objects.cpp`, `particles.cpp`, `pilots.cpp`, `shield.cpp`, `shieldfx.cpp`, `shockwave.cpp`, `sparks.cpp`, `sprites.cpp`, `srofiles.cpp`, `timer.cpp`, `winmain.cpp`, `xtrabits.cpp`, `deathmatch.cpp`, `dmscenarios.cpp`, `DPBits.cpp`, `DPReceivePackets.cpp`, `DPSendPackets.cpp`, `DPSession.cpp`, `hog_file.cpp`, `bigfile.cpp` |
| `C:\lancer\GenILib\` | `interf.cpp` |
| `C:\lancer\interface\loadout\` | `loadout.cpp` |
| `C:\lancer\surrender\surrenderlib\` | `srAPI.cpp`, `srAPIext.cpp`, `srstars.cpp`, `srMesh.cpp`, `srCore.cpp`, `srImage.cpp`, `srTexture.cpp`, `srTGA.cpp`, `srFile.cpp`, `srColor.cpp`, `srClip.cpp`, `srMemCpy.cpp`, `srLight.cpp`, `srBMO.cpp`, `srballs.cpp`, `srline.cpp` |

The MSVC Rich Header documents 147 total object files compiled into the executable; files that lacked embedded assertions reside in the contiguous address spaces between identified files.

---

## Link Order & Module Layout

The MSVC linker linked compiled translation units sequentially into the binary:

1. **AI & Flight Logic**: `Ai.cpp` through `airipper.cpp`, followed by flight transition files (`jump.cpp`, `launch.cpp`, `tractor.cpp`, `wgate.cpp`).
2. **User Interface**: `interf.cpp`, `interface.cpp`, `itac.cpp`, `loadout.cpp`, `videoreports.cpp`.
3. **Mission Scripting**: `Executor.cpp`, `mission.cpp`.
4. **Gameplay & Physics**: `attach.cpp` through `xtrabits.cpp` (object simulation, weapons, rendering hooks, HUD, collisions).
5. **Multiplayer (DirectPlay)**: `deathmatch.cpp` through `DPSession.cpp`.
6. **Surrender 3D Engine & Archives**: Surrender library files grouped with `hog_file.cpp` and `bigfile.cpp`.
7. **Runtime & Thunks**: `srmemory.dll` import thunks and the static C runtime (`LIBCMT`).

---

## Mapping Heuristics

Functions and global variables are attributed to source files using several deterministic rules:
- **Direct String References**: A function referencing a file path string belongs to that translation unit.
- **Literal Clustering**: String and data literals referenced by only one function reside in that function's file.
- **Sequential Enclosure**: A function positioned between two functions belonging to the same source file is attributed to that file.
- **Unplaced Boundaries**: Code blocks located between distinct identified files whose origin cannot be uniquely verified are grouped into transitional ranges (e.g., `aidock.cpp .. aifight.cpp`).
