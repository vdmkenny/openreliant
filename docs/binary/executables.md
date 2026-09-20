# Shipped binaries

Every file listed here comes from a retail install: disc 1 plus the contents of `LANCER.CAB`.
`make game` reproduces that layout under `game/install/`, and the payload executable under
`game/decrypted/`.

All binaries are 32-bit x86 PE images (`machine = 0x14C`).

## The game

| File | Size | Linker | Image base | Notes |
|---|---|---|---|---|
| `LANCER.EXE` (loader) | 249,119 | 5.0 | `0x400000` | SafeDisc 1 loader, not the game. See [`safedisc.md`](safedisc.md). |
| `LANCER.ICD` | 1,151,021 | 6.0 | `0x400000` | The game, encrypted. Entry point `0x004D1210`. |
| `LANGUAGE.DLL` | 122,951 | 6.0 | `0x10000000` | Localised strings, in `.rsrc`. |
| `ITACLANG.DLL` | 692,282 | - | - | In-flight communication system language resources. |

Decrypting `LANCER.ICD` yields 2,205 functions and 4,218 strings under Ghidra's auto-analysis. The
binary is stripped, so Ghidra names functions `FUN_<address>`.

## Middleware

The game is a thin layer over several late-1990s SDKs. Source paths surviving in the payload's
`.rdata` show the original tree as `lancer\game\*.cpp`, `lancer\interface\loadout` and
`lancer\surrender\surrenderlib`.

| Library | Files | Role |
|---|---|---|
| **Surrender** | `srddraw.dll`, `srd3d.dll`, `srfastmath.dll`, `srmemory.dll` | 3D renderer, with DirectDraw and Direct3D 7 back ends, its own math library and allocator. `srmemory.dll` is the payload's only statically imported middleware. Build paths name `srAPI.cpp`. |
| **WinVFX** | `winvfx8.dll`, `winvfx16.dll`, `vfx.dll`, `w32sal.dll` | 2D sprite and overlay drawing, in 8-bit and 16-bit variants, plus a system abstraction layer. |
| **Miles Sound System** | `mss32.dll`, `MSS*.M3D`, `MP3DEC.ASI` | Audio. The `.m3d` files are selectable 3D providers: EAX, Aureal A3D, RSX, Dolby Surround, DirectSound3D. |
| **Bink** | `binkw32.dll` | Video playback for briefings, cutscenes and interface transitions. |

DirectDraw, Direct3D, DirectInput and DirectPlay are reached through those libraries or loaded
dynamically; only `DINPUT.dll` is imported statically, for `DirectInputCreateEx`.

## Data files

Named here for orientation; the formats are not yet documented in this repository.

| Path | Contents |
|---|---|
| `CD1.HOG`, `CD2.HOG`, `ms_speech/msspeech.hog`, `pilots/pilots.hog` | Asset archives. All four begin with `BIGF`, the Electronic Arts BIG container signature. |
| `shipstats.bin`, `gunstats.bin`, `missilestats.bin`, `pilotstats.bin` | Stat tables. |
| `missions/*.dte` | Mission scripts. Only missions 18 and 25 are installed loose; the rest are in the archives. |
| `*.ccb` | Colour lookup tables for Surrender (`palette`, `power`, `softpal`). |
| `Forces/*.FRC` | Force-feedback effects, one per weapon and event. |
| `interface/*.bik`, `inter/`, `*.bik` | Bink video: menu transitions, branding, cutscenes. |
| `music/*.wav` | Music, one file per mission and state. |

## Protection dependencies

`SECDRV.SYS` is the SafeDisc kernel driver. Windows Vista and later disabled it, and Windows 10
removed it, so the shipped `LANCER.EXE` cannot start on a current system. The payload executable
recovered by `sltool safedisc decrypt` does not depend on it.
