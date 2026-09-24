# Camera Subsystem

This document describes StarLancer's camera perspectives, projection calculations, and viewing modes. Camera updates are implemented in `camera.cpp` (`src/engine/game/camera.zig`), with projection math handled by Surrender's `srAPI.cpp` (`src/engine/surrender/surrenderlib/srapi.zig`).

---

## Projection Math

`sr_set_projection` (`0x004C3A60`) takes a normalized viewport bounding box and horizontal/vertical projection scaling factors. A 3D point `(x, y, z)` in camera space projects onto the screen at:

```text
screen_x = width  / 2 + (x / z) * (width  - 0.1) * scale_x
screen_y = height / 2 + (y / z) * (height - 0.1) * scale_y
```

In the original game:
- Most views use fixed scale factors of `scale_x = 0.6` and `scale_y = 0.8`. On a 4:3 display (640x480), this produces square pixels with a field of view of roughly 80° horizontal by 64° vertical. On widescreen monitors, this stretched the image horizontally.
- Cinematic view `0x20` uses `scale_x = 0.35` and `scale_y = 0.467` (~110° FOV).

### Modern Widescreen Adaptation
OpenReliant maintains `scale_y = 0.8` and calculates `scale_x` dynamically based on the current window aspect ratio:

```text
scale_x = 0.8 * (height - 0.1) / (width - 0.1)
```

This guarantees square pixels and expands the horizontal field of view cleanly on modern 16:9, 16:10, and ultrawide displays.

---

## Camera Views

Camera state is stored in `camera_view` (`0x539A34`), and the observed target entity is tracked in `camera_object` (`0x539A8C`). `camera_set_view` (`0x0045F1B0`) switches views, while `camera_frame` (`0x0045FC90`) executes per-frame positioning updates.

| View ID | Key | Mode Name | Description |
|---|---|---|---|
| `0` | 1 | Cockpit View | Forward perspective from the pilot's eye position. |
| `1`, `2`, `3` | 2, 3, 4 | Left / Right / Rear | Cockpit perspective rotated -90°, +90°, or 180° around the ship's vertical axis. |
| `4`, `0x1E` | *(setting)* | Chase Camera | Third-person camera trailing behind the player ship. |
| `6` | 6 | Target Camera | Orbiting camera centered on the player's current lock-on target. |
| `0x0C` | 7 | External Camera | Orbiting camera centered on the player's own ship. |
| `0x12` | 8 | Missile Camera | Tracks trailing behind an in-flight missile ([Missiles](missiles.md#the-missile-camera)). |
| `0x24` | 5 | Flyby Camera | Stationary world-space camera that watches the player fly past. |
| `8`, `0x1B` | *(auto)* | Destruction Views | Orbiting death camera following the ship or debris upon ejection. |

Views above 7 are scripted cinematic views used during launch sequences, hyperspace jumps, docking, and mission cutscenes.

### Cockpit Sub-Modes
Pressing the cockpit view key (1) while in cockpit view cycles `cockpit_mode` (`0x539A9C`):
- **Mode 0**: First-person HUD view without 3D cockpit interior geometry.
- **Mode 1**: First-person HUD view with 3D cockpit interior geometry and pilot controls visible.
- **Mode 2**: External chase view.

---

## Cockpit Inertia & Hit Shake

In cockpit view, `camera_frame` applies dynamic inertial sway to the cockpit model:
- **Rotational Sway**: Pitch, yaw, and roll rates introduce proportional counter-rotation to the cockpit model to simulate g-forces.
- **Acceleration Slide**: Increasing throttle shifts the cockpit model slightly backward along Z.
- **Weapon Recoil**: Firing primary lasers applies a recoil kick offset along Z that decays smoothly over subsequent frames.
- **Hit Shake**: Weapon impacts increment `hit_shake` (`0x00588724`), decaying at 0.02 units per tick. While active, it adds high-frequency rotational jitter to the cockpit frame and world camera.

---

## Chase Camera Dynamics

The chase camera (`camera_chase`, `0x0045ED60`) positions the camera at a ship-specific offset `(0, height, distance)`:

| Ship Class | Height (`h`) | Base Distance (Zero Throttle) |
|---|---|---|
| Grendel | -650 | 1800 |
| Wolverine | -850 | 2000 |
| Reaper | -800 | 2400 |
| Kamov | -1000 | 3400 |
| Default / Other | -750 | 1800 |

- **Throttle Lead**: Distance increases dynamically with throttle setting: `-(400 * throttle + base_distance)`.
- **Lag & Spring**: Camera orientation smoothly lags ship pitch, yaw, and roll rates, catching up exponentially over time to create a sense of momentum.

---

## Orbit Controls (Target & External Views)

In Target View (6) and External View (7), players can orbit around the target using the arrow keys:
- **Left / Right**: Rotates camera yaw.
- **Up / Down**: Adjusts camera pitch (clamped to ±89.5° to prevent gimbal lock).
- **Shift + Up / Down**: Zooms camera distance in or out.
- Distance clamps between 1.8x and 3.8x (external) or 5.8x (target) the object's bounding radius.
