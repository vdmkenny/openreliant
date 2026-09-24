# Platform Layer

The `openreliant` executable uses **SDL3** to replace the legacy Windows APIs used by the original retail release: the Win32 window and message loop, DirectDraw, Direct3D 7, and DirectInput.

Game logic in [`src/engine/`](../../src/engine) accesses platform services exclusively through the abstraction layer in [`src/platform/`](../../src/platform), allowing the same codebase to compile and run across macOS, Linux, and Windows.

---

## Module Overview

| Module | Replaces | Responsibility |
|---|---|---|
| [`platform/window.zig`](../../src/platform/window.zig) | Win32 `WinMain` & Window Loop | Window lifecycle, event pump, and presenting backbuffers. |
| [`platform/gpu.zig`](../../src/platform/gpu.zig) | Direct3D 7 (`IDirect3DDevice7`) | Modern GPU device implementation via SDL's GPU API ([Renderer](renderer.md#the-gpu-device)). |
| [`platform/keyboard.zig`](../../src/platform/keyboard.zig) | DirectInput Keyboard | Maps SDL scancodes to DirectInput `DIK_*` constants. |
| [`platform/joystick.zig`](../../src/platform/joystick.zig) | DirectInput Joystick | Maps SDL joysticks and gamepads into `DIJOYSTATE` structures. |
| [`platform/audio.zig`](../../src/platform/audio.zig) | Win32 WaveOut | Audio device management; feeds the software mixer or OpenAL ([Sound](sound.md)). |
| [`platform/openal.zig`](../../src/platform/openal.zig) | Miles 3D Providers (A3D, EAX) | Positional 3D spatial audio and environmental effects via OpenAL Soft ([Sound](sound.md#openal-soft)). |
| [`platform/macos.zig`](../../src/platform/macos.zig) | macOS AppKit quirks | Configures `ApplePersistenceIgnoreState` before SDL initializes. |
| [`openreliant/main.zig`](../../src/openreliant/main.zig) | `WinMain` | Application entry point, CLI parsing, and main frame loop. |
| [`openreliant/install.zig`](../../src/openreliant/install.zig) | Retail `SETUP.EXE` | Unpacks `LANCER.CAB` via libarchive and copies disc game archives. |

### Third-Party Dependencies

Dependencies are compiled from source during the build:
- **SDL3**: Provided by [castholm/SDL](https://github.com/castholm/SDL) and built from source for the target platform.
- **OpenAL Soft**: Built from source via [`deps/openal-soft`](../../deps/openal-soft/build.zig).
- **libarchive**: Pinned to release 3.7.9 and built via [`deps/libarchive`](../../deps/libarchive) to extract Microsoft Cabinet (`.CAB`) archives. *(Note: libarchive 3.8.x is avoided due to an upstream LZX decompression regression on `LANCER.CAB`).*

---

## Compilation & Cross-Compilation

OpenReliant supports cross-compilation out of the box using Zig:

```bash
# Host build (optimized)
zig build -Doptimize=ReleaseFast

# Cross-compile for Windows (x86_64)
zig build -Dtarget=x86_64-windows

# Cross-compile for Linux (x86_64)
zig build -Dtarget=x86_64-linux-gnu

# Cross-compile for macOS (Apple Silicon)
zig build -Dtarget=aarch64-macos
```

On macOS, `build.zig` queries `xcrun` to provide the linker with Apple SDK paths.

---

## Runtime Architecture

### Asset Loading
When started, `openreliant` looks in the specified game directory (or current directory) for `resource.hog` and `tcachehw.dat` ([`bigfile.zig`](../../src/engine/game/bigfile.zig)). The engine does not bundle assets; if these files are not found, it reports the missing data and exits.

For command-line options and configuration, see [User Guide: Configuration & Options](../guide/configuration.md).

### The Sandbox Scenario
In its current development state, launching the engine boots into a combat sandbox:
- The player ship spawns at the coordinate origin along the Z axis.
- The carrier *Reliant* flies forward at cruise speed across the path.
- A wing of four Coalition Sabre fighters intercepts the player, driven by the AI `Fight` order ([Orders](../engine/orders.md)) and authentic tactical maneuver scripts ([Maneuvers](../engine/maneuvers.md)).
- Capital ship *Badanov* cruises parallel to the *Reliant*.
- Standard camera modes (1–8) are operational, and sandbox shortcuts allow switching ships (F2/F3) or spawning waves (F4).

### Frame Pacing & Display Timing
The window renders at the display's native pixel density:
- **VSync (Default)**: Frames synchronize with the monitor's refresh rate.
- **Decoupled Simulation**: The engine simulation steps at a fixed 25 Hz rate with 100 Hz timer ticks ([Game Loop](../engine/loop.md)). Frame rendering smoothly interpolates object positions between simulation steps.
- **Framerate Limits**: Can be restricted using `--fps <rate>`.

### Modern GPU Pipeline
SDL3's GPU interface abstracts modern graphic APIs:
- **Metal** is used on macOS.
- **Vulkan** is used on Linux and Windows.
- Shaders are compiled to SPIR-V and MSL.

---

## Input Subsystem

[`platform/joystick.zig`](../../src/platform/joystick.zig) replaces DirectInput joystick handling. Every connected controller detected by SDL is mapped to a virtual DirectInput device (`engine.input.JoystickDevice`).

1. **Deadzone & Scaling**: DirectInput-style deadzones are calculated in software. Input within the deadzone is zeroed; values outside the deadzone are scaled linearly across the remaining range.
2. **Axis Detection**: Common flight stick configurations (X/Y pitch and yaw, Z throttle, Rz rudder twist) are detected automatically based on detected axis counts. Manual overrides can be specified in `starlancer.ini`.
3. **Hot-Plugging**: Connect or disconnect controllers at runtime without restarting. The input subsystem automatically updates active device bindings.

For complete controller layouts and configuration instructions, see [User Guide: Controllers & Input](../guide/controllers.md).

---

## Built-In Installer Architecture

[`openreliant/install.zig`](../../src/openreliant/install.zig) recreates the retail installer's behavior without modifying the system registry:

1. **Extraction**: Unpacks `LANCER.CAB` from Disc 1 into the target directory using libarchive.
2. **Asset Transfer**: Copies required archives (`GAME/CD1.HOG` as `CD1.HOG`, and `GAME/CD2.HOG` as `CD2.HOG`).
3. **Drive Auto-Detection**:
   - **Windows**: Queries mounted optical drives via standard volume APIs.
   - **Linux**: Scans `/proc/self/mounts` for ISO 9660 and UDF mount points.
   - **macOS**: Searches active volumes in `/Volumes`.
4. **Disc Identification**: Verifies disc identity using volume labels (`SL_CD2`) or file size signatures of `LANCER.CAB` (226,746,308 bytes on North American releases).

For end-user installation instructions, see [User Guide: Installation](../guide/installation.md).

---

## Continuous Integration & Release Pipeline

- **Automated Testing**: Pull requests run CI workflows across Linux, macOS, and Windows ([`tests.yml`](../../.github/workflows/tests.yml)).
- **Asset Guard**: [`check-files.yml`](../../.github/workflows/check-files.yml) prevents proprietary game assets or copyrighted binaries from being committed to git.
- **Version Management**: Releases follow [Conventional Commits](https://www.conventionalcommits.org) managed by Google's [release-please](https://github.com/googleapis/release-please).
- **Binary Distribution**: Releases publish static tarballs/zips for Linux (`x86_64`, `aarch64`), Windows (`x86_64`, `aarch64`), and macOS (`x86_64`, `aarch64`).
