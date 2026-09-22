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
| [`platform/joystick.zig`](../../src/platform/joystick.zig) | DirectInput's joystick: SDL's joysticks and gamepads as the device the game reads into `DIJOYSTATE` |
| [`platform/macos.zig`](../../src/platform/macos.zig) | Nothing: what macOS needs before SDL starts |
| [`openreliant/main.zig`](../../src/openreliant/main.zig) | `WinMain`: opening the game's files and running the frame loop |
| [`openreliant/install.zig`](../../src/openreliant/install.zig) | The installer on disc 1, `SETUP.EXE`: unpacking `LANCER.CAB` and copying the disc's `GAME/CAB` files |

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
| `--size <width>x<height>` | Draws frames of this size in pixels whatever the window's, which shows them scaled; for a screenshot larger than the display |
| `--fullscreen` | Fills the display |
| `--original` | The original's look: 16-bit colour, one sample a pixel, bilinear filtering, lighting each vertex, motion that moves on with the game's ticks |
| `--16-bit` | 16-bit colour, dithered |
| `--msaa <1\|2\|4\|8>` | Samples a pixel; 4 by default |
| `--filter <original\|trilinear\|crisp>` | How textures are filtered; `crisp` by default |
| `--no-bloom` | Draws without the bloom around bright things |
| `--no-pixel-lighting` | Lights each vertex rather than each pixel, as the original does |
| `--no-smooth-motion` | Moves what moves on with the game's ticks, a hundred a second, as the original does, rather than on every frame |
| `--no-dither` | Draws without dithering 32-bit colour |
| `--no-vsync` | Draws without waiting for the display |
| `--fps <rate>` | Frames a second at most; 0 for no limit |
| `--software` | Draws on the software device, the port's reference, at the window's size in points |

It runs a sandbox of its own, drawn through the ported pipeline and driver with the GPU
([Renderer](renderer.md)): the player's ship at the origin, facing along Z, the Reliant standing
still ahead of it, and a wing of four Sabres between the two. The orders that would fly the Sabres
aren't ported yet, so each is set going at its full throttle, which carries it straight at where
the player was. The game's own bindings drive the camera ([Controls](../engine/controls.md),
[Camera](../engine/camera.md)): the keys 1 to 8 pick the cockpit, left, right, rear, flyby,
target, external and missile views, the cockpit key cycles the cockpit mode while in it, and in the
target and external views the arrow keys orbit and Shift with up or down zooms. Added for the port:
F2 and F3 start the sandbox again in the previous or next ship type, passing over any whose files
the game lacks, F4 brings another wing in front of the player, Alt and Enter switch between the
window and the full screen, and Escape quits. A ship is shown in the chase view, or, where its own
radius is larger than the distance that view sits behind it, in the external view, which orbits at
a distance worked out from its size, so that a capital ship or a station is seen whole.

A Zig built for Intel Macs runs under Rosetta on Apple silicon and builds for Intel by default;
`make play` asks for Apple silicon, and `build.zig` then hands SDL and the linker the SDK's paths
from `xcrun`.

## Installing the game's files

`openreliant install [--from <disc>] [--force] <directory>` does the same job as the installer on
disc 1: it unpacks `LANCER.CAB` into the directory, without the cabinet's top-level `CAB` folder,
and copies the files from the disc's `GAME/CAB` folder next to them. The result is the directory
`openreliant` runs from, and it's the same on every system. `make game` uses it to create
`game/install`.

The disc can be a disc image, raw (`.bin`) or cooked (`.iso`), which is read with the project's own
readers ([Disc images](../formats/disc-images.md)), or a folder with the disc's files, which is how
a mounted disc appears. File names on the disc are matched case-insensitively, as on Windows,
because Linux shows discs without Joliet names, like StarLancer's, in lower case. The files copied
from `GAME/CAB` get upper-case names, as on the disc, so the engine finds `LANGUAGE.DLL` on every
system.

Without `--from`, the installer searches for disc 1:

| System | Where it looks |
|---|---|
| Windows | CD drives that contain a disc, including mounted disc images |
| Linux | Mount points of ISO 9660 and UDF file systems, read from `/proc/self/mounts` |
| macOS | The volumes in `/Volumes` |

It identifies the discs by their files:

| Disc | Identified by |
|---|---|
| Disc 1 of a known release | `LANCER.CAB` with that release's size: 226,746,308 bytes for the North American release |
| Disc 1 of another release | `LANCER.CAB` with any other size; only installed with `--force` |
| Disc 2 | The volume label `SL_CD2`, or `GAME/CD2.HOG` |

The install stops if a file name in the cabinet would end up outside the target directory. At the
end, the installer checks that the files the engine needs at startup are present, and reports the
first one that's missing.

The cabinet is unpacked with [libarchive](https://libarchive.org), which
[`deps/libarchive`](../../deps/libarchive) builds from source for the target, using the build
script of the [allyourcodebase/libarchive](https://github.com/allyourcodebase/libarchive) package
with libarchive pinned to the 3.7.9 release. The LZX decoder in libarchive 3.8.9 fails on
`LANCER.CAB` ([libarchive#3542](https://github.com/libarchive/libarchive/issues/3542)).

## Joysticks and gamepads

[`platform/joystick.zig`](../../src/platform/joystick.zig) replaces DirectInput's joystick support.
Each controller that SDL detects is presented to the game as a DirectInput-style joystick device
(`engine.input.JoystickDevice`). As in the original, the game sets a range for each axis it uses
and a dead zone for the device, and reads the device into a `DIJOYSTATE` at every simulation step
([Controls](../engine/controls.md#devices)). [`docs/controllers.md`](../controllers.md) is the
user guide.

- SDL reports axes from -32768 to 32767. The platform maps them to the range the game set, applying
  the dead zone the way DirectInput does: inside the dead zone the axis reads as the center of its
  range, and outside it the remaining travel is scaled to cover the full range.
- Hats are converted to DirectInput point-of-view values: hundredths of a degree clockwise from
  forward, or centered. Opposite directions pressed together cancel out.
- `DIJOYSTATE` has room for 32 buttons and four hats; any beyond that are ignored.

The game uses one controller at a time, selected by `platform.joystick.choose`: if `Joystick` is
set in `JoyConfig`, the first controller whose name contains that text; otherwise the first
joystick that isn't a gamepad or a standalone throttle, then the first gamepad. When a controller
is connected or disconnected, SDL sends an event, and the driver selects the controller again and
reloads the settings with `load_key_config`, since the bindings depend on the type of controller.
A controller that is disconnected reads as centered, with no buttons pressed.

### Joysticks

SDL numbers a joystick's axes in the same order on every system (X, Y, Z, Rx, Ry, Rz, then
sliders), but it doesn't say which of these axes a given joystick has. The platform therefore
guesses the throttle and twist axes from the number of axes, based on common joysticks:

| Axes | X | Y | Throttle | Twist | Typical device |
|---|---|---|---|---|---|
| 2 | 0 | 1 | | | Old gameport sticks |
| 3 | 0 | 1 | 2 | | Sticks with a throttle wheel |
| 4 | 0 | 1 | 3 | 2 | Most flight sticks: X, Y, twist and a throttle slider |
| 5 | 0 | 1 | 2 | 3 | HOTAS sets |
| 6 or more | 0 | 1 | 2 | 5 | HOTAS sets with X, Y, Z, Rx, Ry and Rz |

If SDL identifies the device as a standalone throttle, its first axis is the throttle. If SDL
identifies it as a gamepad but has no mapping for it, axis 2 is the twist and there is no
throttle. The game receives the throttle as its Z axis and the twist as Rz. `ThrottleAxis` and
`TwistAxis` in `JoyConfig` override the guess with an SDL axis number, or -1 for none.
`ThrottleInvert=1` reverses the throttle, for levers that report their highest value when pushed
forward.

### Gamepads

A controller that SDL maps as a gamepad is presented to the game as a joystick with a fixed layout
(`input.GamepadButton`): the left stick is X and Y, the right stick's horizontal axis is the twist,
the D-pad is the hat, and there are 32 buttons. Buttons 0 to 25 are SDL's gamepad buttons in SDL's
order, 26 and 27 are the triggers (pressed past a quarter of their travel), and 28 to 31 are the
right stick's four directions (pushed past half). Gamepads have no throttle axis, so the throttle
is controlled with ACCELERATE and DECELERATE, which gamepads bind to the right stick's up and
down.

SDL's built-in database covers Xbox, PlayStation and Nintendo controllers and many others. A
`gamecontrollerdb.txt` file in the game folder can add mappings, in SDL's format, for gamepads SDL
doesn't recognize.

### Improvements

Deliberate differences from the original's joystick support:

- Gamepads get their own default bindings (`input.gamepad_buttons`) and have `TwistEnable` on by
  default, so the right stick rolls. The original treated a gamepad like any other joystick.
- A joystick is preferred over a gamepad. The original preferred joysticks with force feedback,
  which the port doesn't support yet.
- Controllers can be connected and disconnected while the game runs. The original only looked for
  a joystick at startup.
- The `DeadZone`, `Joystick`, `ThrottleAxis`, `TwistAxis` and `ThrottleInvert` settings and the
  `gamecontrollerdb.txt` file are new; the original game ignores them.
- Two bugs in how `load_key_config` reads bindings are fixed
  ([Controls](../engine/controls.md#bindings)).

### Listing controllers

`openreliant joysticks [<game-directory>] [--watch]` lists the connected controllers, shows which
one the game will use and, for joysticks, which axis is used for what. It reads the settings from
the game's `starlancer.ini`. With `--watch`, it prints the selected controller's state as the game
sees it whenever it changes, until you press Ctrl+C.

### Testing

The unit tests in `platform/joystick.zig` use SDL's virtual controllers, modelled on real ones, on
every system. `make test-controllers` also tests the Linux path end to end: in a privileged Docker
container, [`scripts/controllers`](../../scripts/controllers) creates kernel virtual devices
(uinput) with the USB IDs, names, axes and buttons of real controllers (an Xbox 360 controller, a
DualShock 4, a Logitech Extreme 3D Pro, a Saitek X52, a gameport stick and an unknown gamepad),
and checks what `openreliant joysticks` reports for each of them.

## Builds and releases

Changes go to `main` through pull requests. Each pull request, and each push to `main`, builds the
executables and runs the tests on Linux, macOS and Windows
([`tests.yml`](../../.github/workflows/tests.yml)), next to the check that no game files are
committed ([`check-files.yml`](../../.github/workflows/check-files.yml)). `main` is protected: a
pull request needs those four checks to pass before it can be merged. Pull requests are squash
merged, so the pull request's title becomes the commit on `main` and has to follow Conventional
Commits too. A pull request that finishes an issue says `Closes #N` in its description.

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
GitHub doesn't run workflows for pull requests opened with that token, so the release pull
request never gets its checks, and an admin merges it past the branch protection.

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
