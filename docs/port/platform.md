# Platform

The `openreliant` executable runs the game on SDL3, which stands in for everything the original
takes from Windows: the Win32 window and message loop, DirectDraw and Direct3D 7, DirectInput. The
game's own code, under [`src/engine/`](../../src/engine), reaches the platform only through
[`src/platform/`](../../src/platform), so the same code builds for macOS, Linux and Windows.

| Module | In place of |
|---|---|
| [`platform/window.zig`](../../src/platform/window.zig) | The window and message loop `WinMain` runs, and the flip to the screen |
| [`platform/gpu.zig`](../../src/platform/gpu.zig) | Direct3D 7's device, `IDirect3DDevice7`, which the driver draws with ([Renderer](renderer.md#the-gpu-device)) |
| [`platform/keyboard.zig`](../../src/platform/keyboard.zig) | DirectInput's keyboard: SDL's scan codes as DirectInput's (`DIK_*`) |
| [`platform/macos.zig`](../../src/platform/macos.zig) | Nothing: what macOS needs before SDL starts |
| [`openreliant/main.zig`](../../src/openreliant/main.zig) | `WinMain`: opening the game's files and running the frame loop |

SDL comes from the [castholm/SDL](https://github.com/castholm/SDL) package, which builds it from
source for the target, so no SDL has to be installed. `build.zig` translates its header into the
`sdl` module the platform layer imports.

## Running

```bash
make play                                      # optimized, for the host, on game/install
zig build -Doptimize=ReleaseFast               # zig-out/bin/openreliant
zig build -Dtarget=x86_64-windows              # openreliant.exe
zig build -Dtarget=x86_64-linux-gnu
zig build -Dtarget=aarch64-macos               # Apple silicon, from any Zig
```

`openreliant [<game-directory>] [<option>...]` runs in the game's installed directory, or the one
given, and reads `resource.hog` and `tcachehw.dat` from it as the original does
([`bigfile.zig`](../../src/engine/game/bigfile.zig)). It has no data of its own: without those
files it says what it needs and exits.

| Option | Does |
|---|---|
| `--ship <type>` | Shows the ship type by its number in `shipstats.bin` |
| `--screenshot <file.png>` | Draws one frame, with the camera settled, to a PNG and quits |
| `--fullscreen` | Fills the display |
| `--original` | The original's look: 16-bit colour, one sample a pixel, bilinear filtering |
| `--16-bit` | 16-bit colour, dithered |
| `--msaa <1\|2\|4\|8>` | Samples a pixel; 4 by default |
| `--filter <original\|trilinear\|crisp>` | How textures are filtered; `crisp` by default |
| `--no-bloom` | Draws without the bloom around bright things |
| `--no-dither` | Draws without dithering 32-bit colour |
| `--no-vsync` | Draws without waiting for the display |
| `--fps <rate>` | Frames a second at most; 0 for no limit |
| `--software` | Draws on the software device, the port's reference, at the window's size in points |

It shows the ship against the backdrop, drawn through the ported pipeline and driver with the GPU
([Renderer](renderer.md)). The game's own bindings drive the camera
([Controls](../engine/controls.md), [Camera](../engine/camera.md)): the keys 1 to 8 pick the
cockpit, left, right, rear, flyby, target, external and missile views, the cockpit key cycles the
cockpit mode while in it, and in the target and external views the arrow keys orbit and Shift with
up or down zooms. Added for the port: F2 and F3 step back and forth through the ship types, passing
over any whose files the game lacks, Alt and Enter switch between the window and the full screen,
and Escape quits. A ship is shown in the chase view, or, where its own radius is larger than the distance that view
sits behind it, in the external view, which orbits at a distance worked out from its size, so that
a capital ship or a station is seen whole.

A Zig built for Intel Macs runs under Rosetta on Apple silicon and builds for Intel by default;
`make play` asks for Apple silicon, and `build.zig` then hands SDL and the linker the SDK's paths
from `xcrun`.

## Builds and releases

Every push and pull request builds the executables and runs the tests on Linux, macOS and Windows
([`tests.yml`](../../.github/workflows/tests.yml)), next to the check that no game files are
committed ([`check-files.yml`](../../.github/workflows/check-files.yml)).

Releases come from [release-please](https://github.com/googleapis/release-please)
([`release.yml`](../../.github/workflows/release.yml),
[`release-please-config.json`](../../release-please-config.json)). Commit messages follow
[Conventional Commits](https://www.conventionalcommits.org): `feat` for a new feature, `fix` for a
bug fix, `docs` for documentation, and `build`, `ci`, `chore`, `perf`, `refactor` or `test` for the
rest, with a `!` after the type for a breaking change. From these, release-please keeps a release
pull request open with the next version and the changelog so far. Before 1.0, a feature raises the
minor version, a fix the patch version, and a breaking change the minor version.

Merging the release pull request updates [`CHANGELOG.md`](../../CHANGELOG.md) and the version in
`build.zig.zon`, tags the version, and publishes a GitHub release with that version's changelog as
its notes. The workflow then builds `openreliant` for each system and attaches the archives:

| Archive | Built on | Target |
|---|---|---|
| `linux-x86_64.tar.gz` | Linux | `x86_64-linux-gnu` |
| `linux-aarch64.tar.gz` | Linux | `aarch64-linux-gnu` |
| `windows-x86_64.zip` | Windows | `x86_64-windows-gnu` |
| `windows-aarch64.zip` | Windows | `aarch64-windows-gnu` |
| `macos-x86_64.tar.gz` | macOS | `x86_64-macos` |
| `macos-aarch64.tar.gz` | macOS | `aarch64-macos` |

Run by hand from the Actions tab, the workflow builds all six and keeps the archives as the run's
artifacts, but publishes nothing.

Each archive holds the executable, the README, the license and the changelog, and no game files.
Every build names its target explicitly, so it is built for its architecture's baseline processor
and runs on any machine of that kind. The Linux builds need glibc 2.31 or newer, and SDL loads the
display, sound and input libraries at run time. The macOS builds are not signed, so macOS blocks
them until the quarantine flag is removed with `xattr -d com.apple.quarantine openreliant`.

release-please opens its pull request with the workflow's own token, which needs "Allow GitHub
Actions to create and approve pull requests" turned on in the repository's Actions settings.

## Frames

The window is drawn into at the display's own density. With vsync, the default, the display paces
the frames: each waits for the display the window is on, at its refresh rate. Without it, frames
are held to that display's refresh rate, or to `--fps`; `--fps` holds them to its rate with vsync
too. The game's clock ticks 100 times a second, so past 100 frames a second some frames show the
same moment of the game; objects move on every fourth tick ([Game loop](../engine/loop.md)).

SDL's GPU interface runs on Metal on macOS and on Vulkan on Linux and Windows: the game's shader
comes as SPIR-V and in Metal's language, not as DXIL for Direct3D 12.

## macOS

Launched, AppKit looks for windows of an earlier run to restore before SDL's own setting against it
takes effect, which can hold the first frame back by seconds. `macos.zig` registers
`ApplePersistenceIgnoreState` for the run before SDL starts, as SDL itself does later.
