# Controls

How the payload reads the player's keyboard, joystick and mouse, and turns them into the inputs of
the [flight model](objects.md#motion). The names below are those `make ghidra-annotate` gives the
Ghidra project; [`src/lancer/input.zig`](../../src/lancer/input.zig) defines the structures.

## Devices

`input_init` (`0x004BCD90`) creates DirectInput 7 and three devices:

- the keyboard, shared with other programs and read only while the game is in the foreground;
- the mouse, held exclusively while the game is in the foreground;
- a joystick. `input_init` first enumerates the attached joysticks that have force feedback,
  and `joystick_found` (`0x004BD190`) opens each it is handed. With none, `input_init` enumerates
  any attached joystick and clears `force_feedback` (`0x50E1A4`); otherwise, while that flag is
  set, `load_force_effects` (`0x004BD800`) loads the effects from `forces\*.frc`.

For the joystick, `joystick_object_found` (`0x004BD050`) sets the range of each axis the game uses
and records that the device has it:

| Axis | Range | Flag |
|---|---|---|
| X | -1000 to 1000 | `joystick_has_x` (`0x5DDC4C`) |
| Y | -1000 to 1000 | `joystick_has_y` (`0x5DDC4D`) |
| Z | 0 to 1000 | `joystick_has_z` (`0x5DDC4E`) |
| Rz, the twist | -1000 to 1000 | `joystick_has_rz` (`0x5DDC51`) |
| First slider | 0 to 1000 | `joystick_has_slider` (`0x5DDC52`) |

A dead zone of a tenth of the range applies to the whole device. `joystick_buttons` (`0x5DDC54`)
holds the button count and `joystick_name` (`0x5DDB48`) the product name.

`input_acquire` (`0x004BD780`) acquires the three devices, or unacquires them while the word at
`0x5DDD28` is set, and `input_shutdown` (`0x004BD3F0`) releases them.

## Reading

`simulation_step` reads the three devices at the start of each step, so 25 times a second (see
[the game loop](loop.md)):

| Function | Into | State |
|---|---|---|
| `read_keyboard` (`0x004BD490`) | `keyboard` (`0x595C68`) | 256 bytes by DirectInput scan code (`DIK_*`), nonzero while the key is down |
| `read_joystick` (`0x004BD300`) | `joystick` (`0x588340`) | `JoystickState`, DirectInput's `DIJOYSTATE` |
| `read_mouse` (`0x004BD3A0`) | `mouse` (`0x588398`) | `MouseState`, DirectInput's `DIMOUSESTATE2`: the movement since the previous read, and eight buttons |

The front-end screens read the keyboard themselves.

## Bindings

`control_bindings` (`0x4E2380`) holds a `ControlBinding` for each action: a scan code, a modifier
(none, Shift, Ctrl or Alt, either key of the pair), the name the game shows, and a joystick button
or -1. [`src/formats/controls.zig`](../../src/formats/controls.zig) lists the actions, numbered as
the game numbers them, with the bindings the game starts with; `make control-tables` transcribes
it from the executable.

`load_key_config` (`0x0042C800`) reads the input settings and the bindings from the `KeyConfig`
and `JoyConfig` sections of `starlancer.ini` in the game's directory. The settings are in
`KeyConfig`:

| Entry | Default | Meaning |
|---|---|---|
| `ForceFeedback` | 1 | Stored at `0x51DA4C`. **Unknown:** its use. |
| `JoystickInvert` | 1 | `joystick_invert` (`0x51D610`). While it is 0, pitch is reversed, from the stick, the keys and the mouse. |
| `HatEnable` | 1 | Stored at `0x52029C`. **Unknown:** its use. |
| `TwistEnable` | 0 | `twist_enabled` (`0x595D88`). While it is set, the joystick's twist rolls the ship. |
| `Controller` | 0 | `control_mode` (`0x57E064`), the device the player steers with: 0 the joystick, 1 the keyboard, 2 the mouse. With no joystick, 0 becomes 1. |

Each action also has an entry in each section, named as the action. In `KeyConfig` the value is a
scan code in decimal, after `SHIFT `, `CONTROL ` or `ALT ` for a modifier, or `JOY BUTTON ` and a
button number; in `JoyConfig` it is `JOY BUTTON ` and a button number. A missing entry leaves the
binding the game starts with.

## Whether an action is active

`control_active` (`0x00412630`) takes an action and a flag, `once`. Without `once` an action counts
for as long as its button or key is down; with it, only once for each press.

1. **The joystick button**, if the action has one and it is down. With `once` it counts only while
   the button is not latched, and latches it; `read_joystick` clears the latch in
   `button_latched` (`0x5DDC98`) once the button is up.
2. **The key.** The keys 1 to 8, scan codes 2 to 9, never count while the word at `0x501EE8` is
   3. **Unverified:** that word is the state of the HUD instrument numbered 11, whose open request
   `OpenInstrument` sets at `0x501F0C`. Otherwise, without `once`, a key bound with no modifier
   counts while it is down and neither Shift nor Ctrl is; a key with a modifier counts while it
   and either key of the modifier are down. With `once`, `control_active` asks `key_pressed`.

`key_pressed` (`0x004BD570`) takes a scan code, a modifier and `once`, and is what the front-end
screens use too. It keeps a latch for each key, `key_latched` (`0x5D54EC`), and one for each
modifier, `shift_latched`, `control_latched` and `alt_latched`. `read_keyboard` clears a key's
latch once the key is up, and a modifier's once both its keys are up.

- **With `once`**, the key counts while it is down and not latched, and, with no modifier, while
  no Shift, Ctrl or Alt key is down, or with one, while either key of the modifier is down. Then
  it latches the key and the modifier.
- **Without `once`**, the key counts while it is down and, with no modifier, while no modifier is
  latched, or with one, while either key of the modifier is down. Then it clears the key's latch
  and the modifier's.

## Steering

`player_controls` (`0x00413410`) is the update of the order numbered 100, `Player Control`, which
the player's ship follows in flight. `object_orders` (`0x0040C5F0`) runs an object's current
order; while the player's is `Player Control`, `simulation_step` runs it before the objects
move. `player_controls` sets
the ship's roll, pitch, yaw and lateral inputs and its throttle. Axis values are scaled by 0.001,
so the stick's travel spans -1 to 1.

- **Joystick** (`control_mode` 0). X yaws and Y pitches. The keys ROLL SHIP CLOCKWISE and ROLL SHIP
  ANTI-CLOCKWISE roll at 1 and -1, and while JOYSTICK ROLL is held, X rolls instead of yawing.
  With `twist_enabled` and a twist axis, X, Y and the twist yaw, pitch and roll. The throttle
  axis, Z or else the first slider, sets the throttle to `1 - value * 0.001`, so 0 is full
  throttle and 1000 none. Without either, the keys set it (see below).
- **Keyboard** (1). Each update that ROTATE CLOCKWISE or ROTATE ANTI-CLOCKWISE is held steps yaw by
  -0.3 or 0.3, and NOSE UP or NOSE DOWN steps pitch by 0.3 or -0.3; with neither key of a pair
  held, that input is zero. The flight model clamps each input to between -1 and 1, so a held key
  reaches full deflection on its fourth update. The roll keys roll as with the joystick. While the
  word at `0x539A34` is 6 or 12, yaw and pitch stay zero.
- **Mouse** (2). The mouse's movement gathers into a stick position, each axis held to within 800
  counts of the centre. As a fraction `v` of 800, each axis gives 0 while `|v|` is under 0.3,
  and `1.3 * v - 0.3` above it or `1.3 * v + 0.3` below it. X yaws and Y pitches, reversed; the
  roll keys roll. The left button fires the lasers, and the right launches a missile once for
  each press.

In each mode, half the yaw input is added to the roll input, so the ship banks into turns, and
`joystick_invert` sets the sign of pitch. STRAFE LEFT and STRAFE RIGHT set the lateral input to -1
and 1. While the word at `0x754` of the player's object is 9, all four inputs are reversed.
**Unknown:** what that value means, and what the flags at `0x51CEF8`, `0x51CEFC` and `0x51CF04`
are: while any is set, the stick position goes to other routines (`0x00412D40`, `0x00413180`,
`0x00413200`) instead of the inputs.

## Throttle

With the keyboard or the mouse, or a joystick without a throttle axis, `player_controls` calls
`player_throttle_keys` (`0x004132C0`). It steps `throttle_setting` (`0x51CF7C`) and the ship's
throttle by 0.02 each update that ACCELERATE or DECELERATE is held, so two seconds from none to
full, and ZERO THROTTLE and FULL THROTTLE, once for each press, set them to 0 or 1 and stop MATCH
SPEED. Then it sets the ship's throttle to `throttle_setting`; its check of `afterburner` first
always passes there, since `object_orders` has cleared the flag. `player_controls` keeps the
throttle between 0 and 1, and at most 0.5 while the word at `0x754` of the player's object is 7.

MATCH SPEED, once for each press, flips `matching_speed` (`0x579984`). While it is set,
`match_target_speed` (`0x00412C10`) sets the throttle to the target's speed over the player's
cruise speed, at most 1, while the target is within 330000 units; beyond that it puts back the
throttle from before, `throttle_before_match` (`0x566794`), and stops matching.

## Afterburner and reverse thrust

AFTERBURNERS, while held, and AFTERBURNER TOGGLE, which flips `afterburner_toggled` (`0x51CEFE`)
once for each press, set the ship's `afterburner`. REVERSE THRUST, while held, sets its
`reverse_thrust`. `object_orders` clears both before each order update, so each lasts until the
next update unless set again. After the update it clears both when the ship has no afterburner
fuel, both and the throttle while the ship's flags have `0x20000`, and `reverse_thrust` when they
lack `0x80`.

While the player asks for either, a warning sounds when fewer than 20 seconds of fuel are left and another when
it is out, each at most once every 1000 ticks, ten seconds; `fuel_warning_tick` (`0x5799C0`) holds
the tick before which neither sounds again.

`player_controls` also reads FIRE LASERS, LAUNCH MISSILE, CLOAK SHIP, JUMP DRIVE, EJECT and
COUNTERMEASURES, all but FIRE LASERS once for each press. While the byte at `0x529FB8` is set, it
reads none of them, nor MATCH SPEED, AFTERBURNER TOGGLE, the throttle keys or the keys that turn
the ship. **Unknown:** what sets that byte.

## Porting

The bindings and `starlancer.ini` hold DirectInput scan codes, which follow the IBM PC's set 1
scan codes, with the extended keys at `0x80` and up. A port that reads input some other way maps
its key codes to them, gives the joystick's axes in the ranges above, and gives the mouse's
movement since the previous step.
