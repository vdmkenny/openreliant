# Configuration & Command-Line Options

OpenReliant provides flexible command-line arguments and configuration file options to adjust graphics, sound, gameplay settings, and controls.

---

## Command-Line Options

Pass options when launching the executable:

```bash
./openreliant [options] [game-directory]
```

*(If omitted, `game-directory` defaults to the current working directory or `StarLancer`.)*

### General Options

| Option | Description |
|---|---|
| `-h`, `--help` | Show available command-line arguments and in-game key bindings. |
| `--version` | Display the current OpenReliant version. |
| `--original` | Disable modern enhancements and run with authentic 2000 settings: 16-bit color, 1x MSAA, bilinear texture filtering, per-vertex lighting, 100 Hz stepped motion, and uncompressed stereo sound. |

### Sandbox & Gameplay Options

| Option | Description |
|---|---|
| `--ship <id>` | Select player ship by ID from `shipstats.bin` (default: `0`, the Predator light fighter). |
| `--view <0\|1\|2>` | Starting camera perspective: `0` = cockpit (default), `1` = chase camera, `2` = forward view without cockpit geometry. |
| `--difficulty <level>` | Combat difficulty: `easy`, `medium` (default), or `hard`. Controls weapon damage scaling. |
| `--music <file>` | Track to play from the `music/` folder (default: `New_Mission01.wav`), or `none` to disable music. |
| `--no-pause-menu` | Skip the startup pause menu and jump straight into flight. |

### Display & Window Options

| Option | Description |
|---|---|
| `--fullscreen` | Launch in fullscreen mode. Press **Alt + Enter** in-game to toggle. |
| `--size <W>x<H>` | Internal rendering resolution in pixels (e.g., `1920x1080`). Independent of window size; useful for taking high-resolution screenshots. |
| `--fps <rate>` | Frame rate cap. Set to `0` for uncapped. |
| `--no-vsync` | Disable vertical synchronization. |

### Graphics Options

| Option | Description |
|---|---|
| `--filter <mode>` | Texture filtering: `crisp` (default, sharp modern mipmapping), `trilinear`, or `original` (bilinear). |
| `--msaa <1\|2\|4\|8>` | Multi-sample anti-aliasing sample count (default: `4`). |
| `--16-bit` | Render in 16-bit dithered color instead of 32-bit. |
| `--no-bloom` | Disable the glow/bloom shader effect around lights and engines. |
| `--no-dither` | Disable color dithering in 32-bit output. |
| `--no-pixel-lighting` | Use original per-vertex lighting instead of per-pixel lighting. |
| `--no-smooth-motion` | Update positions at the original 100 Hz simulation rate rather than interpolating smoothly on every rendered frame. |
| `--few-shot-lights` | Limit dynamic lights to the latest two shots from the player and enemies (matches retail engine limits). |
| `--software` | Render using the built-in software rasterizer reference device instead of the GPU. |
| `--screenshot <file.png>` | Render one settled frame to a PNG image and exit immediately. |

### Audio Options

| Option | Description |
|---|---|
| `--hrtf` | Force Head-Related Transfer Function (HRTF) 3D audio processing for headphones, regardless of output device. (Enabled automatically when headphones are detected.) |
| `--no-hrtf` | Force standard stereo/surround speaker panning without headphone HRTF filtering. |
| `--no-reverb` | Disable environmental reverb effects. |
| `--no-compressor` | Disable dynamic range compression on the master audio bus. |
| `--no-sound` | Disable all audio output. |

---

## In-Flight Controls

During sandbox flight, the following keys are available:

| Key | Action |
|---|---|
| **Escape** | Open or close the pause options menu. |
| **Alt + Enter** | Toggle between windowed and fullscreen display. |
| **F2** / **F3** | Switch to the previous or next ship model. |
| **F4** | Spawn a new wave of enemy fighters. |
| **1** | Cockpit view (press repeatedly to cycle cockpit visual modes). |
| **2** / **3** / **4** | Left, right, and rear cockpit views. |
| **5** | Flyby camera. |
| **6** | Target tracking camera. |
| **7** | External chase camera (use arrow keys to orbit, Shift + Up/Down to zoom). |
| **8** | Missile tracking camera. |

---

## Configuration File (`starlancer.ini`)

Game settings are saved in `starlancer.ini` inside your game installation folder. If the file is missing, you can create it with a standard text editor.

Example configuration:

```ini
[KeyConfig]
JoystickInvert=1
TwistEnable=1
HatEnable=1
Controller=0

[JoyConfig]
DeadZone=5
Joystick=Extreme 3D
ThrottleAxis=3
TwistAxis=2
ThrottleInvert=0
```

For detailed controller configuration, deadzone tuning, and button remapping, see [Controllers & Input](controllers.md).
