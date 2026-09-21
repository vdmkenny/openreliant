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

| View | Key | Camera |
|---|---|---|
| 0 | Cockpit | From the cockpit, ahead, as the cockpit mode says |
| 1, 2, 3 | Left, right, rear view | From the cockpit, turned -90, 90 and 180 degrees about the ship's down axis |
| 4, 0x1E | | Chase |
| 6 | Target | Round the player's target |
| 0xC | External | Round the player's ship |
| 0x12 | Missile | Behind a missile |
| 0x24 | Flyby | From a point the player flies past |

The view table (`0x4F72A8`) holds for each view whether cinematic bars slide in, for the cutaways
but not the external view, and whether it is from the cockpit, views 0 to 3. From the cockpit the
object's flag bit 0 is set, except in the chase mode, and cleared when the view moves off it. The
bars grow by 0.001 of the screen a tick to 0.1, top and bottom; a view without them clears them at
once.

`camera_locked` (`0x539ACC`) holds the camera for a script: `camera_set_view` refuses a switch
unless forced, and the camera keys do nothing. `frame_controls` (`0x00414060`), once a frame, maps
the camera keys to views. The cockpit key, pressed in the cockpit view, first moves
`cockpit_mode` (`0x539A9C`) on:

| Mode | Cockpit view |
|---|---|
| 0 | From the eye, no cockpit drawn |
| 1 | From the eye, the cockpit's model drawn over the view |
| 2 | The chase view |

The options' cockpit setting (`0x5D5A78`) picks the mode a mission starts in: 0 for mode 1, 1 for
mode 2 and 2 for mode 0.

## Cockpit

The camera's orientation is the ship's turned by the view's angle, and its position the ship's plus
the model's eye point, the `.SHP` header's vector at `0x08`, turned likewise, so the rear view looks
back from behind the ship. The Kamov (ship type 0x2D) looks back from 1500 behind it instead.

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
