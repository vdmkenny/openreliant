# Platform

The `starlancer` executable runs the game on SDL3, which stands in for everything the original
takes from Windows: the Win32 window and message loop, DirectDraw and Direct3D 7, DirectInput. The
game's own code, under [`src/lancer/`](../../src/lancer), reaches the platform only through
[`src/platform/`](../../src/platform), so the same code builds for macOS, Linux and Windows.

| Module | In place of |
|---|---|
| [`platform/window.zig`](../../src/platform/window.zig) | The window and message loop `WinMain` runs, and the flip to the screen |
| [`platform/keyboard.zig`](../../src/platform/keyboard.zig) | DirectInput's keyboard: SDL's scan codes as DirectInput's (`DIK_*`) |
| [`platform/macos.zig`](../../src/platform/macos.zig) | Nothing: what macOS needs before SDL starts |
| [`starlancer/main.zig`](../../src/starlancer/main.zig) | `WinMain`: opening the game's files and running the frame loop |

SDL comes from the [castholm/SDL](https://github.com/castholm/SDL) package, which builds it from
source for the target, so no SDL has to be installed. `build.zig` translates its header into the
`sdl` module the platform layer imports.

## Running

```bash
make play                                      # optimized, for the host, on game/install
zig build -Doptimize=ReleaseFast               # zig-out/bin/starlancer
zig build -Dtarget=x86_64-windows              # starlancer.exe
zig build -Dtarget=x86_64-linux-gnu
zig build -Dtarget=aarch64-macos               # Apple silicon, from any Zig
```

`starlancer [<game-directory>] [--ship <type>] [--screenshot <file.png>]` runs in the game's
installed directory, or the one given, and reads `resource.hog` and `tcachehw.dat` from it as the
original does ([`bigfile.zig`](../../src/lancer/game/bigfile.zig)). `--ship` picks the ship type
shown, by its number in `shipstats.bin`; `--screenshot` draws one frame, with the camera settled, to
a PNG and quits.

It shows the ship against the backdrop, drawn through the ported pipeline and driver
([Renderer](renderer.md)) onto the software device, whose frames go to the screen through SDL's GPU
interface. The game's own bindings drive the camera ([Controls](../engine/controls.md),
[Camera](../engine/camera.md)): the keys 1 to 8 pick the cockpit, left, right, rear, flyby,
target, external and missile views, the cockpit key cycles the cockpit mode while in it, and in the
target and external views the arrow keys orbit and Shift with up or down zooms. Added for the port:
F2 and F3 step back and forth through the ship types, passing over any whose files the game lacks,
and Escape quits. The chase view keeps its offsets for the ships the player flies, so a capital ship
fills it; the external view orbits any ship at a distance by its size.

A Zig built for Intel Macs runs under Rosetta on Apple silicon and builds for Intel by default;
`make play` asks for Apple silicon, and `build.zig` then hands SDL and the linker the SDK's paths
from `xcrun`.

## macOS

Launched, AppKit looks for windows of an earlier run to restore before SDL's own setting against it
takes effect, which can hold the first frame back by seconds. `macos.zig` registers
`ApplePersistenceIgnoreState` for the run before SDL starts, as SDL itself does later.
