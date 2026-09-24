# Shipped Executables & Middleware

This document inventories the binary executables and dynamic libraries shipped on the retail StarLancer discs (primarily extracted from `LANCER.CAB`).

All binaries are 32-bit x86 Windows PE executables (`machine = 0x014C`).

---

## Core Game Executables

| Binary | Size (bytes) | Linker | Default Base | Role |
|---|---|---|---|---|
| `LANCER.EXE` | 249,119 | MSVC 5.0 | `0x00400000` | SafeDisc v1 wrapper and copy protection launcher. |
| `LANCER.ICD` | 1,151,021 | MSVC 6.0 | `0x00400000` | Decrypted game engine payload (Entry point: `0x004D1210`). |
| `LANGUAGE.DLL` | 122,951 | MSVC 6.0 | `0x10000000` | Localized string tables stored as Win32 `.rsrc` resources. |
| `ITACLANG.DLL` | 692,282 | - | - | In-flight tactical audio communications string resources. |

`LANCER.ICD` contains the actual game logic. It was stripped of debug symbols prior to release. It was compiled with Microsoft Visual C++ 6.0 and links the C runtime library (`LIBCMT`) statically (see [`runtime.md`](runtime.md)).

---

## Middleware Libraries

StarLancer was built on top of several late-1990s multimedia and graphics SDKs:

| Middleware | Binaries | Description |
|---|---|---|
| **Surrender** | `srddraw.dll`<br>`srd3d.dll`<br>`srfastmath.dll`<br>`srmemory.dll` | 3D rendering engine developed by Warthog, featuring DirectDraw and Direct3D 7 rasterizers, vectorized math routines, and custom memory allocators. `srmemory.dll` is the only statically linked DLL dependency. |
| **WinVFX** | `winvfx8.dll`<br>`winvfx16.dll`<br>`vfx.dll`<br>`w32sal.dll` | 2D UI sprite, HUD overlay rendering, and system abstraction library. |
| **Miles Sound System** | `mss32.dll`<br>`MSS*.M3D`<br>`MP3DEC.ASI` | Audio mixer and 3D positional audio drivers (EAX, Aureal A3D, DirectSound3D). |
| **Bink Video** | `binkw32.dll` | Smacker/Bink video player used for cutscenes, mission briefings, and UI transitions. |

DirectDraw, Direct3D 7, and DirectInput are accessed through these middleware layers or loaded dynamically at runtime via `LoadLibrary`.

---

## Shipped Game Data Files

| Path / Pattern | Description | Documentation |
|---|---|---|
| `CD1.HOG`, `CD2.HOG`, `resource.hog`, `pilots.hog`, `msspeech.hog` | Asset archives (`BIGF` format / RefPack compression). | [`formats/hog.md`](../formats/hog.md) |
| `shipstats.bin`, `gunstats.bin`, `missilestats.bin`, `pilotstats.bin` | Binary gameplay balance tables. | [`formats/stats.md`](../formats/stats.md) |
| `missions/*.dte` | Mission definitions, triggers, and compiled script bytecode. | [`formats/dte.md`](../formats/dte.md) |
| `*.ccb` | Surrender color lookup tables (`palette.ccb`, `power.ccb`). | [`formats/tcache.md`](../formats/tcache.md) |
| `Forces/*.FRC` | Immersion force-feedback profiles for joystick hardware. | |
| `interface/*.bik`, `*.bik` | Bink video cutscenes and menu animations. | |
| `music/*.wav` | Mission background music and combat tracks. | [`engine/sound.md`](../engine/sound.md) |

---

## SafeDisc Copy Protection

Retail copies were protected by SafeDisc v1 (`SECDRV.SYS`). Because modern operating systems (Windows 10, Windows 11, Linux, macOS) block or lack this obsolete kernel-mode driver, the original retail `LANCER.EXE` cannot execute on modern systems without decryption or a decompiled engine like OpenReliant.
