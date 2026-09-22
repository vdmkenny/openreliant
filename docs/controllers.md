# Joysticks and gamepads

OpenReliant supports joysticks and gamepads: flight sticks, sticks with a throttle, HOTAS sets
that connect with a single USB cable, old gameport sticks on USB adapters, and gamepads such as
Xbox, PlayStation and Nintendo Switch controllers. You can connect a controller before starting
the game or while it's running. The keyboard still works when a controller is connected.

## Which controller is used

OpenReliant uses one controller at a time. If several are connected, it prefers a joystick over a
gamepad, and it never picks a standalone throttle while a stick is connected. To choose a
controller yourself, see [Choosing a controller](#choosing-a-controller).

## Gamepad controls

| Control | Action |
|---|---|
| Left stick | Pitch and turn. Push forward to pitch the nose down |
| Right stick left and right | Roll |
| Right stick up and down | Increase and decrease speed |
| Right trigger | Fire lasers |
| Left trigger | Launch missile |
| A (bottom button) | Afterburner, while held |
| B (right button) | Match target speed |
| X (left button) | Countermeasures |
| Y (top button) | Target nearest enemy |
| Right bumper | Next enemy target |
| Left bumper | Previous enemy target |
| Left stick click | Toggle afterburner |
| Right stick click | Target what's under the reticle |
| Back, View or Share | Change radar range |
| D-pad | Look left, right or back while held; up looks forward |

The face buttons are identified by position, not by label: the bottom button is A on an Xbox
controller, cross on a PlayStation controller and B on a Nintendo controller.

Some of these actions, such as weapons and targeting, aren't implemented in OpenReliant yet. They
are mapped now so they work once they are.

The left stick works like a flight stick: pushing it forward points the nose down. To invert
this, set `JoystickInvert=0` (see [Settings](#settings)).

## Flight stick controls

| Control | Action |
|---|---|
| Stick left and right | Turn, banking into the turn |
| Stick forward and back | Pitch the nose down and up |
| Throttle | Speed: fully forward is full throttle |
| Twist | Nothing by default; set `TwistEnable=1` to roll with it |
| Hat | Look left, right or back while held; forward looks forward |
| Button 0 (trigger) | Fire lasers |
| Button 1 | Launch missile |
| Button 2 | Afterburner, while held |
| Button 3 | Target nearest enemy |
| Button 4 | Strafe right |
| Button 5 | Next friendly target |
| Button 7 | Strafe left |

These are StarLancer's original defaults. Button numbers start at 0, as shown by
`openreliant joysticks`, so the button your stick calls "1" is button 0 here. To roll with the
stick instead of turning, hold the Insert key. If your stick has no throttle, use the keyboard's
throttle keys.

## Checking your controller

`openreliant joysticks` lists the connected controllers, shows which one the game will use, and
for joysticks shows which axis is used for what. Open a terminal in the folder where you extracted
OpenReliant, as you did for installing, and run:

```bash
./openreliant joysticks StarLancer
```

On Windows, use `.\openreliant.exe` instead of `./openreliant`. `StarLancer` is the folder the game
is installed in; the tool reads your settings from there. The output looks like this:

```
1. Logitech Extreme 3D (used by the game)
   joystick, USB ID 046d:c215, 4 axes, 12 buttons, 1 hat
   X: axis 0, Y: axis 1, throttle: axis 3, twist: axis 2
```

To see live input as the game reads it, add `--watch`. Move each axis and press each button to find
its number. Press Ctrl+C to stop.

```bash
./openreliant joysticks StarLancer --watch
```

## Settings

StarLancer stores its settings in `starlancer.ini` in the game folder, and OpenReliant reads the
same file. If it doesn't exist, create it with a text editor. Here's an example with every setting
described on this page:

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

Any setting you leave out keeps its default.

| Setting | Section | Default | Description |
|---|---|---|---|
| `JoystickInvert` | `KeyConfig` | 1 | 1: pull back to pitch up. 0: inverted |
| `TwistEnable` | `KeyConfig` | 0 (1 for gamepads) | 1: the stick's twist, or a gamepad's right stick, rolls the ship |
| `HatEnable` | `KeyConfig` | 1 | 1: the hat, or a gamepad's D-pad, looks around |
| `Controller` | `KeyConfig` | 0 | 0: use the joystick or gamepad. 1: use the keyboard |
| `DeadZone` | `JoyConfig` | 10 | How far an axis must move before it registers, in percent of its travel |
| `Joystick` | `JoyConfig` | | Part of the name of the controller to use |
| `ThrottleAxis` | `JoyConfig` | automatic | Number of the throttle axis, or -1 for none |
| `TwistAxis` | `JoyConfig` | automatic | Number of the twist axis, or -1 for none |
| `ThrottleInvert` | `JoyConfig` | 0 | 1: the throttle works in reverse |

`DeadZone`, `Joystick`, `ThrottleAxis`, `TwistAxis` and `ThrottleInvert` are OpenReliant settings;
the original game ignores them. Axis numbers are the ones `openreliant joysticks` shows.

### Button bindings

To bind a button to an action, add `ACTION NAME=JOY BUTTON number` to the `JoyConfig` section. The
action names are:

COCKPIT CAMERA, LEFT VIEW CAMERA, RIGHT VIEW CAMERA, REAR VIEW CAMERA, FLYBY CAMERA, TARGET CAMERA,
EXTERNAL CAMERA, MISSILE CAMERA, NEXT ENEMY TARGET, PREVIOUS ENEMY TARGET, NEXT FRIENDLY TARGET,
PREVIOUS FRIENDLY TARGET, NEXT SUBTARGET, PREVIOUS SUBTARGET, TARGET UNDER RETICULE, TARGET NEAREST
ENEMY, TARGET NEAREST FRIENDLY, TARGET TORPEDO, SMART TARGET, PRIMARY TARGET, AFTERBURNERS,
AFTERBURNER TOGGLE, REVERSE THRUST, JUMP DRIVE, MATCH SPEED, ACCELERATE, DECELERATE, ZERO THROTTLE,
FULL THROTTLE, ROLL SHIP CLOCKWISE, ROLL SHIP ANTI-CLOCKWISE, NOSE UP, NOSE DOWN, ROTATE CLOCKWISE,
ROTATE ANTI-CLOCKWISE, STRAFE LEFT, STRAFE RIGHT, JOYSTICK ROLL, FIRE LASERS, FULL GUNS, GUNNERY
WINDOW, GUNNERY WINDOW LOCKED, SYNCHRONISE GUNS, TOGGLE BLINDFIRE, LAUNCH MISSILE, MISSILE WINDOW,
ROTATE MISSILES CLOCKWISE, ROTATE MISSILES ANTICLOCKWISE, COMMS WINDOW, POWERBALL WINDOW, POWERBALL
WINDOW LOCKED, FULL POWER TO GUNNERY, FULL POWER TO ENGINES, FULL POWER TO SHIELDS, EQUALIZE POWER,
OBJECTIVES WINDOW, WING STATUS WINDOW, WING STATUS WINDOW LOCKED, DAMAGE WINDOW, DAMAGE WINDOW
LOCKED, RADAR RANGES, SHIELD BALANCING, COUNTERMEASURES, EJECT, CLOAK SHIP, ECM, SPECTRAL SHIELDS,
ATTACK MY TARGET, BACK OFF, HELP ME, PERMISSION TO LAND, DISPLAY KILLS, SEND COMMS MESSAGE, KEY
CONFIG.

For a joystick, use the button numbers shown by `openreliant joysticks --watch`. For a gamepad,
the numbers are always these:

| Number | Gamepad button | Number | Gamepad button |
|---|---|---|---|
| 0 | A / cross (bottom) | 16 | Right paddle 1 |
| 1 | B / circle (right) | 17 | Left paddle 1 |
| 2 | X / square (left) | 18 | Right paddle 2 |
| 3 | Y / triangle (top) | 19 | Left paddle 2 |
| 4 | Back, View or Share | 20 | Touchpad click |
| 5 | Guide (Xbox or PS button) | 21 to 25 | Other extra buttons |
| 6 | Start or Menu | 26 | Left trigger |
| 7 | Left stick click | 27 | Right trigger |
| 8 | Right stick click | 28 | Right stick up |
| 9 | Left bumper | 29 | Right stick down |
| 10 | Right bumper | 30 | Right stick left |
| 11 | D-pad up | 31 | Right stick right |
| 12 | D-pad down | | |
| 13 | D-pad left | | |
| 14 | D-pad right | | |
| 15 | Capture, mute or other extra button | | |

For example, `STRAFE LEFT=JOY BUTTON 13` and `STRAFE RIGHT=JOY BUTTON 14` strafe with the D-pad. In
that case also set `HatEnable=0`, otherwise the D-pad looks around as well.

### Choosing a controller

If several controllers are connected, `Joystick` selects the first one whose name contains the
given text (not case-sensitive). For example, `Joystick=xbox` uses an Xbox controller even when a
stick is connected.

## Common controllers

- **Xbox, PlayStation, Nintendo Switch and most other gamepads**: work out of the box with the
  gamepad controls above.
- **Sticks with a twist and a throttle**, such as the Logitech Extreme 3D Pro: work out of the box.
  Set `TwistEnable=1` if you want to roll with the twist.
- **HOTAS sets with a single USB cable**, such as the Saitek/Logitech X52: work out of the box.
  Use `openreliant joysticks --watch` to check that the right axis is used as the throttle, and set
  `ThrottleAxis` if it isn't.
- **Stick and throttle with separate USB cables**: OpenReliant only reads the stick for now
  ([issue 114](https://github.com/vdmkenny/openreliant/issues/114)). Use the keyboard for the
  throttle, or bind ACCELERATE and DECELERATE to buttons on the stick.
- **Old gameport sticks on a USB adapter**: steering and buttons work; use the keyboard for the
  throttle.
- **Gamepads listed as a joystick**: SDL, the library OpenReliant uses for controllers, doesn't
  recognize the gamepad, so its right stick is treated as a throttle. Set `ThrottleAxis=-1` and
  `TwistAxis=2`. Alternatively, add a mapping for the gamepad to a `gamecontrollerdb.txt` file in
  the game folder to get the full gamepad controls. The
  [SDL_GameControllerDB](https://github.com/mdqinc/SDL_GameControllerDB) project has mappings for
  thousands of gamepads.

If your controller needs any of these settings, or doesn't work at all, please
[open an issue](https://github.com/vdmkenny/openreliant/issues/new) and include the output of
`openreliant joysticks`, so we can make it work out of the box.

## Troubleshooting

- **The controller isn't listed.** Check that your system detects it. On Linux, you need read
  access to its device in `/dev/input`; desktop sessions normally give this to the logged-in user.
- **The ship drifts or turns by itself.** Your stick doesn't rest exactly in the center. Increase
  `DeadZone`.
- **Small movements do nothing.** Decrease `DeadZone`. The default of 10 is large for a modern
  stick.
- **The throttle works in reverse.** Set `ThrottleInvert=1`.
- **The wrong axis controls the throttle or twist.** Find the right axes with
  `openreliant joysticks --watch` and set `ThrottleAxis` and `TwistAxis`.
