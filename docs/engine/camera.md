# Camera

The views the game shows and where each puts the camera: `camera.cpp`, with the projection from
Surrender's `srAPI.cpp`. [`src/engine/game/camera.zig`](../../src/engine/game/camera.zig) and
[`srapi.zig`](../../src/engine/surrender/surrenderlib/srapi.zig) state the same rules.

## Projection

`sr_set_projection` (`0x004C3A60`) takes a viewport, its edges as fractions of the screen, and a
factor across and one down. A point at `(x, y, z)` in the camera's frame falls on the screen at

```
(width / 2 + x / z * (width - 0.1) * across, height / 2 + y / z * (height - 0.1) * down)
```

whatever the viewport; the viewport only bounds what is drawn. Every view but one uses the factors
0.6 and 0.8: the screen spans 5/6 of a view unit either side of the middle across and 5/8 up and
down, about 80 by 64 degrees, with square pixels on a 4:3 screen and stretched ones on any other.
View 0x20 uses 0.35 and 0.467, about 110 degrees across.

The game runs in the display modes the device lists, which it keeps in `dmodes.bin`, and starts at
640x480.

The port keeps the factor down and chooses the factor across that keeps pixels square,
`0.8 * (height - 0.1) / (width - 0.1)`: on a 4:3 screen the game's 0.6, on a wider one a wider view.

## Views

`camera_view` (`0x539A34`) holds the view and `camera_object` (`0x539A8C`) the object it shows.
`camera_set_view` (`0x0045F1B0`) switches view and places the camera at once; `camera_frame`
(`0x0045FC90`) places it once a frame. Views from 7 on are the game's cutaways, of launches,
landings, jumps and deaths among others.

| View | Key | Camera | Named |
|---|---|---|---|
| 0 | Cockpit | From the cockpit, ahead, as the cockpit mode says | Cockpit View |
| 1, 2, 3 | Left, right, rear view | From the cockpit, turned -90, 90 and 180 degrees about the ship's down axis | Left View, Right View, Rear View |
| 4, 0x1E | | Chase | a space |
| 6 | Target | Round the player's target | Target Camera |
| 0xC | External | Round the player's ship | External Camera |
| 8 | | Behind the object, turning with it about its own `Y` at 0.005 a tick and pulling away from 3000 at 10 a tick, as the player's ship is destroyed | a space |
| 0x12 | Missile | Behind a missile | Missile Camera |
| 0x1A | | From where the camera was, watching the object | a space |
| 0x1B | | From where the camera was, watching where the player's ship burst (`explode_marker`), which drifts on at a quarter of its velocity a frame | a space |
| 0x24 | Flyby | From a point the player flies past | a space |

The view table (`camera_view_table`, `0x4F72A8`) holds four bytes a view, for views 0 to `0x2B`:
the language string that names the view, whether cinematic bars slide in, and whether it is from
the cockpit. [`camera/views.zig`](../../src/engine/game/camera/views.zig) transcribes it; `make
view-tables` derives it again. The bars slide in for views 7 to `0x27` and `0x2B`, but not the
external view; views 0 to 3 are from the cockpit. The names are strings 170 to 182 of
`language.dll`; string 174, Chase Camera, is none of them, the chase views and most cutaways taking
181, a single space. From the cockpit the object's flag bit 0 is set, except in the chase mode, and
cleared when the view moves off it. The bars grow by 0.001 of the screen a tick to 0.1, top and
bottom; a view without them clears them at once.

`camera_locked` (`0x539ACC`) holds the camera for a script: `camera_set_view` refuses a switch
unless forced, and the camera keys do nothing. `frame_controls` (`0x00414060`), once a frame, maps
the camera keys to views. The cockpit key, pressed in the cockpit view, first moves
`cockpit_mode` (`0x539A9C`) on:

| Mode | Cockpit view |
|---|---|
| 0 | From the eye, no cockpit drawn |
| 1 | From the eye, the cockpit's model drawn over the view |
| 2 | The chase view |

The options' cockpit setting (`cockpit_mode_setting`, `0x5D5A78`), which the game keeps in its
ini as `[Device] View` and reads as 0 when the ini has none, picks the mode a mission's launch ends
in: 0 for mode 1, 1 for mode 2 and any other for mode 0. The launch (`launch_run`, `0x0041B240`)
shows one of three cutaways, views `0x20` to `0x22`, and at its last step sets the mode and
switches from the cutaway to view 0. Resuming from the pause (`game_pause`, `0x00491E20`) switches
to view 0 again when the setting changed while paused.

The port starts a ship in view 0 in the mode `--view` sets, 0 by default, as a launch ends. A ship
too large for the chase mode's distance starts in the external view instead: the port flies ships
the game never gives the player.

## Cockpit

The camera's orientation is the ship's turned by the view's angle, and its position the ship's plus
the model's eye point, the `.SHP` header's vector at `0x08`, turned likewise, so the rear view looks
back from behind the ship. The Kamov (ship type 0x2D) looks back from 1500 behind it instead.

In view 0 outside the chase mode, `camera_frame` also moves the cockpit's model
([`rendering.md`](rendering.md#the-cockpit)), whose root hangs from the camera's frame. With each
of the ship's rates of turn taken over its flight model's full rate, and its speed over its cruise
speed, each held between -1 and 1:

- The root turns by the pitch rate times -0.1, the yaw rate times -0.15 and the roll rate times
  -0.1, so the cockpit sways against a turn, and stands at 50 times the speed along `Z` less the
  cockpit model's own eye point, so that the eye is at the camera and the cockpit slides back as
  the ship speeds up.
- The hands, the model's second part, turn by the pitch rate times 0.15 in pitch and the roll and
  yaw rates together times 0.2 in roll, about their part's mount point; they stand at their
  part's position less the object's centre, less 30 along `Z` times the guns' kick
  (`0x005636E0`), which the player's guns set to 1 as they fire (`0x0047BE3A`) and which loses a
  twentieth each frame.

Each frame, `camera_frame` first caps `hit_shake` (`0x00588724`) at 2, takes a tenth of it as the
shake, and lowers `hit_shake` by 0.02 a tick. The root then jitters in yaw and roll by a random
amount of up to half the shake either way, from two `rand` numbers drawn every frame, the first for
the roll. While the shake is above zero, the camera also turns by a random amount of up to half of
0.03 times the remaining `hit_shake`, in the world's frame. Hits raise `hit_shake`, and so does
`object_move` while the player's ship flies faster than its cruise speed (see
[Motion](objects.md#motion)).

## Chase

`camera_chase` (`0x0045ED60`) puts the camera at `(0, h, d)` in the ship's frame, turned:

| Ship type | `h` | Distance at no throttle |
|---|---|---|
| 2, Grendel | -650 | 1800 |
| 8, Wolverine | -850 | 2000 |
| 9, Reaper | -800 | 2400 |
| 0x2D, Kamov | -1000 | 3400 |
| Others | -750 | 1800 |

`d` moves a tenth of the way to `-(400t + distance)` each frame, with `t` the throttle, 1.5 on the
afterburner; switching to the view starts it at 1500, ahead of the ship. The camera swings against
the ship's rates of turn, in radians per update: toward `-5.7` times the pitch rate, within a
sixteenth of a turn and then halved when negative and one and a half times when positive, `-5`
times the yaw rate and `-3` times the roll rate, within a tenth of a turn, each 5% of the way a
frame, the roll adding 5% of the yaw's target too. The offset is turned by the ship's orientation,
then the pitch about `X`, then the yaw about `Y`; the camera's orientation is the ship's turned by
the roll about `Z`. Objects whose type is 0x100 or more have no chase view and fall back to the
cockpit.

## Orbits

The target and external views put the camera at `(0, 0, d)` turned by the yaw about `Y` and then the
pitch about `X`, in the world's axes, from the object, and look at it. `d` is kept between 1.8
radii of the object and 5.8 for the target or 3.8 for the player's ship; switching to either view
zeroes the yaw, the pitch, their speeds and `d`.

`frame_controls` steers them from the arrow keys, fixed, whatever the bindings, in ticks of a
hundredth of a second:

- Left and right change the yaw's speed by 0.1 degrees a tick, within 5 degrees a tick; then it
  slows by 0.05 toward 0. The yaw moves by the speed and wraps into 0 to 360.
- Shift with up or down moves the camera in or out by 60 a tick.
- Up and down change the pitch's speed likewise, which slows likewise and then keeps within 5. The
  pitch keeps within 89.5 degrees either way, and stops there.

The target view needs the player to have a target; without one it switches to the cockpit.

## Flyby

The flyby view starts a radius below the player's ship and four ahead, in its frame, and stays
there, looking at the ship, until the ship is more than 23000 away; then it moves there again. It
keeps at least a radius from the ship.

An object's radius is its farthest vertex from its origin, over its parts' finest levels
(`object_bounds`, `0x00476680`).

This page leaves out the cockpit's model and its motion, the shake from hits (`hit_shake`,
`0x588724`) and the cutaways.
