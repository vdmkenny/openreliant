# Controllers & Input

OpenReliant supports modern gamepads, flight sticks, single-cable HOTAS setups, and legacy joysticks connected through USB adapters. You can plug in or unplug controllers at any time while the game is running, and the keyboard remains active regardless of connected hardware.

---

## Device Selection

OpenReliant uses one active controller at a time:
1. If multiple devices are plugged in, it prioritizes a flight stick over a gamepad.
2. It ignores standalone throttle quadrants when a flight stick is present.
3. You can explicitly select a specific controller using the `Joystick` option in `starlancer.ini` (see [Selecting a Specific Controller](#selecting-a-specific-controller)).

---

## Default Controls

### Gamepad Layout

| Control | Action |
|---|---|
| **Left Stick** | Pitch and yaw (push forward to pitch down; pull back to pitch up) |
| **Right Stick (Left/Right)** | Roll |
| **Right Stick (Up/Down)** | Accelerate / Decelerate |
| **Right Trigger** | Fire primary lasers |
| **Left Trigger** | Launch missile |
| **Bottom Button (A / Cross / B)** | Afterburner (hold) |
| **Right Button (B / Circle / A)** | Match target speed |
| **Left Button (X / Square / Y)** | Deploy countermeasures |
| **Top Button (Y / Triangle / X)** | Target nearest enemy |
| **Right Bumper** | Next enemy target |
| **Left Bumper** | Previous enemy target |
| **Left Stick Click** | Toggle afterburner |
| **Right Stick Click** | Target object under reticle |
| **Back / View / Share** | Cycle radar range |
| **D-Pad (Left/Right/Down)** | Look left, right, or behind while held |
| **D-Pad (Up)** | Look forward |

*Note: Face buttons correspond to physical position rather than button labels (e.g., the bottom button is `A` on Xbox, `Cross` on PlayStation, and `B` on Nintendo).*

### Flight Stick Layout

| Control | Action |
|---|---|
| **Stick X (Left/Right)** | Yaw / turn (banks automatically into turns) |
| **Stick Y (Forward/Back)** | Pitch down (push) and pitch up (pull) |
| **Throttle Lever** | Engine speed (fully forward = 100% throttle) |
| **Rudder Twist** | Unbound by default; set `TwistEnable=1` in `starlancer.ini` to roll |
| **POV Hat** | Look left, right, or rear while held; forward centers view |
| **Button 0 (Trigger)** | Fire primary lasers |
| **Button 1** | Launch missile |
| **Button 2** | Afterburner (hold) |
| **Button 3** | Target nearest enemy |
| **Button 4** | Strafe right |
| **Button 5** | Next friendly target |
| **Button 7** | Strafe left |

*Tip: Hold **Insert** on the keyboard while moving the stick horizontally to roll instead of banking. If your joystick lacks a throttle, use the keyboard throttle keys.*

---

## Inspecting and Testing Controllers

Run the `joysticks` command to view all detected controllers, their axis assignments, and which device OpenReliant selects:

```bash
./openreliant joysticks StarLancer
```

*(On Windows, run `.\openreliant.exe joysticks StarLancer`)*

Example output:
```text
1. Logitech Extreme 3D (used by the game)
   joystick, USB ID 046d:c215, 4 axes, 12 buttons, 1 hat
   X: axis 0, Y: axis 1, throttle: axis 3, twist: axis 2
```

To test inputs in real time, add `--watch`:

```bash
./openreliant joysticks StarLancer --watch
```

Move each axis and press buttons to identify their assigned numbers. Press **Ctrl + C** to exit.

---

## Configuration (`starlancer.ini`)

Settings are stored in `starlancer.ini` within your game directory. You can edit or add options in the `[KeyConfig]` and `[JoyConfig]` sections:

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
FIRE LASERS=JOY BUTTON 0
LAUNCH MISSILE=JOY BUTTON 1
```

### General Input Settings

| Setting | Section | Default | Description |
|---|---|---|---|
| `JoystickInvert` | `KeyConfig` | `1` | Pitch axis direction (`1` = flight standard / pull to climb; `0` = inverted). |
| `TwistEnable` | `KeyConfig` | `0` (`1` on gamepads) | Enables rolling with joystick twist or gamepad right stick. |
| `HatEnable` | `KeyConfig` | `1` | Enables directional viewing with POV hat or D-pad. |
| `Controller` | `KeyConfig` | `0` | Primary input mode (`0` = joystick/gamepad; `1` = keyboard flight). |
| `DeadZone` | `JoyConfig` | `10` | Deadzone percentage (0–100) before stick movements register. |
| `Joystick` | `JoyConfig` | *(empty)* | Substring match to pick a specific controller name. |
| `ThrottleAxis` | `JoyConfig` | `automatic` | SDL axis index for throttle, or `-1` to disable. |
| `TwistAxis` | `JoyConfig` | `automatic` | SDL axis index for twist rudder, or `-1` to disable. |
| `ThrottleInvert` | `JoyConfig` | `0` | Invert throttle direction (`1` = push for zero throttle, pull for full). |

### Custom Button Remapping

In `[JoyConfig]`, bind actions using the format `ACTION NAME=JOY BUTTON <number>`:

```ini
[JoyConfig]
FIRE LASERS=JOY BUTTON 0
LAUNCH MISSILE=JOY BUTTON 1
STRAFE LEFT=JOY BUTTON 13
STRAFE RIGHT=JOY BUTTON 14
```

*(If you bind flight controls like strafing to the D-pad, set `HatEnable=0` so view pans do not conflict.)*

#### Gamepad Button Reference

| ID | Button | ID | Button |
|---|---|---|---|
| `0` | A / Cross (bottom) | `16` | Right rear paddle 1 |
| `1` | B / Circle (right) | `17` | Left rear paddle 1 |
| `2` | X / Square (left) | `18` | Right rear paddle 2 |
| `3` | Y / Triangle (top) | `19` | Left rear paddle 2 |
| `4` | Back / View / Share | `20` | Touchpad click |
| `5` | Guide / Home | `26` | Left trigger |
| `6` | Start / Menu | `27` | Right trigger |
| `7` | Left stick click (L3) | `28` | Right stick up |
| `8` | Right stick click (R3) | `29` | Right stick down |
| `9` | Left bumper (L1) | `30` | Right stick left |
| `10` | Right bumper (R1) | `31` | Right stick right |
| `11`–`14` | D-pad (Up, Down, Left, Right) | | |

#### Valid Action Names

```text
COCKPIT CAMERA, LEFT VIEW CAMERA, RIGHT VIEW CAMERA, REAR VIEW CAMERA,
FLYBY CAMERA, TARGET CAMERA, EXTERNAL CAMERA, MISSILE CAMERA,
NEXT ENEMY TARGET, PREVIOUS ENEMY TARGET, NEXT FRIENDLY TARGET, PREVIOUS FRIENDLY TARGET,
NEXT SUBTARGET, PREVIOUS SUBTARGET, TARGET UNDER RETICULE, TARGET NEAREST ENEMY,
TARGET NEAREST FRIENDLY, TARGET TORPEDO, SMART TARGET, PRIMARY TARGET,
AFTERBURNERS, AFTERBURNER TOGGLE, REVERSE THRUST, JUMP DRIVE, MATCH SPEED,
ACCELERATE, DECELERATE, ZERO THROTTLE, FULL THROTTLE,
ROLL SHIP CLOCKWISE, ROLL SHIP ANTI-CLOCKWISE, NOSE UP, NOSE DOWN,
ROTATE CLOCKWISE, ROTATE ANTI-CLOCKWISE, STRAFE LEFT, STRAFE RIGHT, JOYSTICK ROLL,
FIRE LASERS, FULL GUNS, GUNNERY WINDOW, GUNNERY WINDOW LOCKED, SYNCHRONISE GUNS,
TOGGLE BLINDFIRE, LAUNCH MISSILE, MISSILE WINDOW, ROTATE MISSILES CLOCKWISE,
ROTATE MISSILES ANTICLOCKWISE, COMMS WINDOW, POWERBALL WINDOW, POWERBALL WINDOW LOCKED,
FULL POWER TO GUNNERY, FULL POWER TO ENGINES, FULL POWER TO SHIELDS, EQUALIZE POWER,
OBJECTIVES WINDOW, WING STATUS WINDOW, WING STATUS WINDOW LOCKED,
DAMAGE WINDOW, DAMAGE WINDOW LOCKED, RADAR RANGES, SHIELD BALANCING,
COUNTERMEASURES, EJECT, CLOAK SHIP, ECM, SPECTRAL SHIELDS,
ATTACK MY TARGET, BACK OFF, HELP ME, PERMISSION TO LAND, DISPLAY KILLS,
SEND COMMS MESSAGE, KEY CONFIG
```

### Selecting a Specific Controller

If multiple controllers are connected, set `Joystick` in `[JoyConfig]` to part of the device name (case-insensitive):

```ini
[JoyConfig]
Joystick=Xbox
```

---

## Hardware-Specific Notes & Troubleshooting

- **Xbox, PlayStation, and Switch Controllers**: Supported natively with standard button layouts.
- **Flight Sticks with Twist Rudder (e.g., Logitech Extreme 3D Pro)**: Work out of the box. Set `TwistEnable=1` to use the twist axis for rolling.
- **HOTAS Systems (Single USB Cable, e.g., Saitek X52)**: Detected automatically. Run `openreliant joysticks --watch` to verify throttle axis detection.
- **Dual-USB Flight Stick + Throttle Combinations**: OpenReliant currently binds the primary flight stick. For dual-device setups, use keyboard throttle controls or map throttle buttons onto the stick until multi-device binding is expanded.
- **Stick Drift / Unintended Turning**: If your ship slowly turns on its own, increase the `DeadZone` value (e.g., `DeadZone=12`).
- **Sluggish Response Near Center**: If the stick feels unresponsive during fine adjustments, lower `DeadZone` (e.g., `DeadZone=3` or `4`).
- **Inverted Throttle**: If pushing forward cuts engines and pulling back accelerates, add `ThrottleInvert=1`.
- **Linux Device Permissions**: Ensure your user account has read permissions for devices in `/dev/input/` (usually handled automatically by systemd/udev).
- **Custom Gamepad Mappings**: If an unusual controller is not recognized as a gamepad, add its SDL mapping string to a `gamecontrollerdb.txt` file placed in the game directory.
