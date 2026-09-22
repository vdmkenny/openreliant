# Controls

How the payload reads the player's keyboard, joystick and mouse, and turns them into the inputs of
the [flight model](objects.md#motion). The names below are those `make ghidra-annotate` gives the
Ghidra project; [`src/engine/input.zig`](../../src/engine/input.zig) defines the structures.

## Devices

`input_init` (`0x004BCD90`) creates DirectInput 7 and three devices:

- the keyboard, shared with other programs and read only while the game is in the foreground;
- the mouse, held exclusively while the game is in the foreground;
- a joystick. `input_init` first enumerates the attached joysticks that have force feedback,
  and `joystick_found` (`0x004BD190`) opens each it is handed. With none, `input_init` enumerates
  any attached joystick and clears `force_feedback` (`0x50E1A4`); otherwise, while that flag is
  set, `load_force_effects` (`0x004BD800`) loads the effects from `forces\*.frc`.

For the joystick, `joystick_object_found` (`0x004BD050`) sets the range of each axis the game uses
and records that the device has it in `joystick_axes` (`0x5DDC4C`), a `JoystickAxes` with a flag
for each axis in the order of `DIJOYSTATE`:

| Axis | Range | Flag |
|---|---|---|
| X | -1000 to 1000 | `x` |
| Y | -1000 to 1000 | `y` |
| Z | 0 to 1000 | `z` |
| Rz, the twist | -1000 to 1000 | `rz` |
| First slider | 0 to 1000 | `slider` |

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
or -1. [`src/engine/input/controls.zig`](../../src/engine/input/controls.zig) lists the actions,
numbered as the game numbers them, with the bindings the game starts with; `make control-tables`
transcribes it from the executable.

`load_key_config` (`0x0042C800`) reads the input settings and the bindings from the `KeyConfig`
and `JoyConfig` sections of `starlancer.ini` in the game's directory. The settings are in
`KeyConfig`:

| Entry | Default | Meaning |
|---|---|---|
| `ForceFeedback` | 1 | Stored at `0x51DA4C`. **Unknown:** its use. |
| `JoystickInvert` | 1 | `joystick_invert` (`0x51D610`). While it is 0, pitch is reversed, from the stick, the keys and the mouse. |
| `HatEnable` | 1 | `hat_enabled` (`0x52029C`). While it is set, the hat looks around ([The hat](#the-hat)). |
| `TwistEnable` | 0 | `twist_enabled` (`0x595D88`). While it is set, the joystick's twist rolls the ship. |
| `Controller` | 0 | `control_mode` (`0x57E064`), the device the player steers with: 0 the joystick, 1 the keyboard, 2 the mouse. With no joystick, 0 becomes 1. |

Each action also has an entry in each section, named after the action. In `KeyConfig` the value is
a scan code in decimal, optionally after `SHIFT `, `CONTROL ` or `ALT ` for a modifier, or
`JOY BUTTON ` and a button number; in `JoyConfig` it is `JOY BUTTON ` and a button number. Button
numbers start at 0. A missing entry keeps the default binding: `load_key_config` formats the current
binding the way it writes it, and passes that as the default to `GetPrivateProfileStringA` for both
sections.

That has two bugs, which only show when the file is edited by hand, since the game always writes
both sections:

- When the `KeyConfig` entry has a modifier, the check for `JOY BUTTON ` in the `JoyConfig` value
  starts after the modifier's length, so an action bound to a key with a modifier can never also
  have a joystick button.
- The `JoyConfig` default is the binding as it was before the `KeyConfig` entry was read, so a
  `JOY BUTTON` in `KeyConfig` is overwritten by the old button when `JoyConfig` has no entry.

**Improvement:** the port fixes both: it checks the `JoyConfig` value from its start, and uses the
button from `KeyConfig` as the `JoyConfig` default.

## Whether an action is active

`control_active` (`0x00412630`) takes an action and a flag, `once`. Without `once` an action counts
for as long as its button or key is down; with it, only once for each press.

1. **The joystick button**, if the action has one and it is down. With `once` it counts only while
   the button is not latched, and latches it; `read_joystick` clears the latch in
   `button_latched` (`0x5DDC98`) once the button is up.
2. **The key.** The keys 1 to 8, scan codes 2 to 9, never count while the word at `0x501EE8` is
   3: that is the phase of the display's window 11, the communications menu, open, whose number
   keys call the units in range ([`hud.md`](hud.md#the-windows)). Otherwise, without `once`, a key
   bound with no modifier counts while it is down and neither Shift nor Ctrl is; a key with a
   modifier counts while it and either key of the modifier are down. With `once`,
   `control_active` asks `key_pressed`.

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

## The hat

`frame_controls` reads the joystick's first hat while `hat_enabled` is set and the joystick has a
hat. Held straight forward, left, right or back, the hat switches to the cockpit's front, left,
right or rear view, every frame while it is held; diagonals do nothing. `hat_glancing`
(`0x51CF8C`) records that the hat is in use, so that the view returns to the front once it is
released. Camera keys pressed in the same frame take priority.

## Steering

`player_controls` (`0x00413410`) is the update of the order numbered 100, `Player Control`, which
the player's ship follows in flight (see [orders](orders.md)). It runs whenever the ship's orders
run: once a frame, from `orders_update`, and once each simulation step, from `simulation_step`,
before the objects move. The devices are read only at each step, so the runs in between see the
same state, and what `player_controls` steps each time it runs changes at a rate that depends on
the frame rate. It sets the ship's roll, pitch, yaw and lateral inputs and its throttle. Axis
values are scaled by 0.001, so the stick's travel spans -1 to 1.

- **Joystick** (`control_mode` 0). X yaws and Y pitches. The keys ROLL SHIP CLOCKWISE and ROLL SHIP
  ANTI-CLOCKWISE roll at 1 and -1, and while JOYSTICK ROLL is held, X rolls instead of yawing.
  With `twist_enabled` and a twist axis, X, Y and the twist yaw, pitch and roll. The throttle
  axis, Z or else the first slider, sets the throttle to `1 - value * 0.001`, so 0 is full
  throttle and 1000 none. Without either, the keys set it (see below).
- **Keyboard** (1). Each run while ROTATE CLOCKWISE or ROTATE ANTI-CLOCKWISE is held steps yaw by
  -0.3 or 0.3, and NOSE UP or NOSE DOWN steps pitch by 0.3 or -0.3; with neither key of a pair
  held, that input is zero. The flight model clamps each input to between -1 and 1, so a held key
  reaches full deflection on the fourth run. The roll keys roll as with the joystick. While the
  word at `0x539A34` is 6 or 12, yaw and pitch stay zero.
- **Mouse** (2). The mouse's movement gathers into a stick position, each axis held to within 800
  counts of the centre. As a fraction `v` of 800, each axis gives 0 while `|v|` is under 0.3,
  and `1.3 * v - 0.3` above it or `1.3 * v + 0.3` below it. X yaws and Y pitches, reversed; the
  roll keys roll. The left button fires the lasers, and the right launches a missile once for
  each press.

In each mode, half the yaw input is added to the roll input, so the ship banks into turns, and
`joystick_invert` sets the sign of pitch. STRAFE LEFT and STRAFE RIGHT set the lateral input to -1
and 1. While the word at `0x754` of the player's object is 9, all four inputs are reversed.
**Unknown:** what that value means.

While SHIELD BALANCING or POWERBALL WINDOW is held, or the flag at `0x51CF04` is set, the stick
doesn't steer: the four inputs are zeroed, the throttle isn't read, and the stick's position goes
to [the shield balance](#the-shield-balance) or [the power distribution](#the-power-distribution)
instead, in that order of priority. The joystick's X and Y are the stick; with the keyboard,
ROTATE CLOCKWISE and ROTATE ANTI-CLOCKWISE count as -1 and 1 across and NOSE UP and NOSE DOWN as
-1 and 1 down; the mouse gives its movement times 64 over 800. `0x51CF04`'s routine
(`0x00413200`) turns two angles at `0x51CF30` and `0x51CF00` by the stick, and `frame_controls`
clears the flag on every frame OBJECTIVES WINDOW isn't pressed. **Unknown:** what sets the flag,
and what the angles turn.

## Throttle

With the keyboard or the mouse, or a joystick without a throttle axis, `player_controls` calls
`player_throttle_keys` (`0x004132C0`). It steps `throttle_setting` (`0x51CF7C`) and the ship's
throttle by 0.02 each run while ACCELERATE or DECELERATE is held, fifty runs from none to full,
and ZERO THROTTLE and FULL THROTTLE, once for each press, set them to 0 or 1 and stop MATCH
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
order next runs unless set again. After the update it clears both when the ship has no afterburner
fuel, both and the throttle while its engines are disabled (`DisableEngines`), and `reverse_thrust`
unless the ship has the `can_reverse` flag.

While the player asks for either, a warning sounds when fewer than 20 seconds of fuel are left and another when
it is out, each at most once every 1000 ticks, ten seconds; `fuel_warning_tick` (`0x5799C0`) holds
the tick before which neither sounds again.

`player_controls` also reads FIRE LASERS, LAUNCH MISSILE, CLOAK SHIP, JUMP DRIVE, EJECT and
COUNTERMEASURES, all but FIRE LASERS once for each press. While the byte at `0x529FB8` is set, it
reads none of them, nor MATCH SPEED, AFTERBURNER TOGGLE, the throttle keys or the keys that turn
the ship. **Unknown:** what sets that byte.

## The power distribution

The player shares the ship's power between its shields, guns and engines by moving a point on a
disc of radius 64, the power ball (`GameObject.power_setting`, `+0x728`). Each system has an
anchor on the ball, a third of a turn from the next: the shields at (0, 1), the guns at
(0.866, -0.5) and the engines at (-0.866, -0.5). `power_distribute` (`0x00412560`) works out each
system's share: `power_reach` (`0x004124E0`) measures the distance from the point to the edge of
the disc going away from the system's anchor, which is 128 at the anchor, 64 in the middle and 0
opposite, and a share is that distance over the three together. A share `s` gives a factor of
`(1.75 - 0.75 * s) * s + 0.5`: 1 for an even third, 1.5 for all of the power and 0.5 for none.

| Offset | Factor | What it scales |
|---|---|---|
| `0x734` | Guns | How fast the guns recharge (`0x004770E0`) |
| `0x738` | Engines | The cruise speed ([Motion](objects.md#motion)) |
| `0x73C` | Shields | How fast the shields recharge ([Shields](objects.md#shields)) |

`create_object` puts the point at (1, 1) and the three factors at 1.

- FULL POWER TO GUNNERY, FULL POWER TO ENGINES, FULL POWER TO SHIELDS and EQUALIZE POWER, while
  held and the radio's window is shut, put the point at (54.17, -30.32), (-55.79, -27.94),
  (0.699, 61.98) and (1, 1), work out the factors and open the power window. EQUALIZE POWER's
  point is a little off the middle, toward the shields, so its factors aren't all 1.
- While POWERBALL WINDOW is held (`powerball_held`, `0x51CEF8`), `power_move` (`0x00413180`)
  moves the point against the stick by the frame's ticks times its deflection each time
  `player_controls` runs, brings it back to the edge of the disc if it leaves it, and works out
  the factors again.

The display shows the point and the shares in its [power window](hud.md#the-power-distribution).

## The shield balance

While SHIELD BALANCING is held (`0x51CEFC`), `shield_balance` (`0x00412D40`) shifts shields fore or
aft by the stick's Y. Each time `player_controls` runs with Y past half-way, a quarter of the
ship's shield power moves: from the fore shield to the aft one while Y is above 0.5, and back
while it is below -0.5, as long as the shield it comes from has any left. The quarter comes out
of that side's reserve first (`0x51CF78` for the fore shield, `0x51CF34` for the aft one), then
out of the shield. The shield it goes to holds at most five times the shield power, and what goes
beyond that is added to its reserve, which holds as much again. A reserve keeps the other side's
shield from [recharging](objects.md#shields) to full.

## Porting

The bindings and `starlancer.ini` hold DirectInput scan codes, which follow the IBM PC's set 1
scan codes, with the extended keys at `0x80` and up. The port maps SDL's scan codes to them
([`platform/keyboard.zig`](../../src/platform/keyboard.zig)).

[`input.zig`](../../src/engine/input.zig) ports the input code: `key_pressed` and
`read_keyboard`'s latches (`Keyboard`), the joystick (`Joystick`: `joystick_found`,
`joystick_object_found` and `read_joystick`), and `control_active` with both keys and buttons
(`Devices.active`). The joystick is read through `JoystickDevice`, an interface with the calls the
game makes on its DirectInput device: capabilities, axis ranges, dead zone and polling.
[`platform/joystick.zig`](../../src/platform/joystick.zig) implements it for SDL's joysticks and
gamepads ([Platform](../port/platform.md#joysticks-and-gamepads)). `Devices` holds what the game
keeps in globals: the device states, the bindings and the settings.

`playerControls` and `playerThrottleKeys` port the joystick and keyboard parts of the two
routines above. `Player` holds `throttle_setting`, `matching_speed`, `afterburner_toggled`, the
two held flags and the shield reserves. The engine runs them where `simulation_step` does, once
per step, before the objects move. The game also runs `player_controls` once a frame from
`orders_update`, which isn't ported yet ([#32](https://github.com/vdmkenny/openreliant/issues/32)),
so for now the keyboard steers, the stick moves the power and SHIELD BALANCING shifts the shields
more slowly than in the game.

[`input/power.zig`](../../src/engine/input/power.zig) ports the power distribution and the shield
balance: `reach`, `shares`, `distribute`, `choose` for the power keys, `move` and
`balanceShields`.
`Camera.frameControls` ports the hat. `load_key_config` is ported in
[`game/interface.zig`](../../src/engine/game/interface.zig), with the fixes above;
[`profile.zig`](../../src/engine/profile.zig) reads the file as `GetPrivateProfileIntA` and
`GetPrivateProfileStringA` do.

**Improvement:** the port reads `starlancer.ini` again whenever a controller is connected or
disconnected, since the settings and bindings depend on the controller. A gamepad gets its own
default bindings and has `TwistEnable` on by default. `DeadZone` in `JoyConfig` sets the dead zone,
which the original fixes at a tenth. A joystick that is disconnected is closed and reads as
centered, where the original tries to acquire it again.

Not yet ported: the mouse ([issue 115](https://github.com/vdmkenny/openreliant/issues/115)), force
feedback ([issue 83](https://github.com/vdmkenny/openreliant/issues/83)), matching a target's
speed, the weapons and other actions `player_controls` reads, and the special cases for the byte
at `0x529FB8`, the word at `0x754` of the player's object and the flags at `0x51CEF8`, `0x51CEFC`
and `0x51CF04`. `object_orders` clears the two burns before each order update and, after it, when
the ship is out of fuel or its engines are disabled; only the fuel check is ported, in
`playerControls` itself, since nothing runs orders yet.
