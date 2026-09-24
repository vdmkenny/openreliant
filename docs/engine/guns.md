# Weapons & Gunnery Subsystem

This document details how StarLancer fits weapons onto ship models, manages weapon groups, processes firing logic during simulation steps, and simulates projectile physics.

Static weapon statistics are documented in [`formats/stats.md`](../formats/stats.md#guns).

---

## Hardpoint Weapon Mounting

When an entity is initialized (`object_fit_guns`, `0x00479800`), the engine scans its 3D model hierarchy to identify weapon hardpoints:

1. **Turret Parts**: Model parts with turret classes (classes 3, 9, 10, or 18) and turret types 1, 2, or 3 initialize as articulated or spinning turrets ([Turrets](#turrets)).
2. **Fixed Hardpoints**: All other model nodes scan for attachment points of kind 3 (muzzle). Each muzzle point instantiates a fixed gun corresponding to the weapon type ID stored in the attachment record.
3. **Gun Record Allocation**: Each mounted gun allocates a `0x60`-byte record tracking its firing state, muzzle node pointer, weapon stats reference, trigger timers, weapon group index, and next available refire tick.

---

## Weapon Grouping

Weapon grouping is calculated automatically per ship class (`gun_groups_build`, `0x004667F0`):
- Guns of matching weapon types are paired symmetrically across the ship's lateral centerline.
- Left-side guns lead each group.
- Unpaired centerline weapons form single-gun groups.
- Articulated turrets and missile launchers are excluded from standard gun groups.
- By default, ships start in synchronized fire mode (`gun_mode = 0`), firing all primary groups concurrently unless configured for alternating fire.

---

## Trigger & Firing Logic

When the fire command is received (`object_fire_guns`, `0x0047B1F0`):
- `FIRE LASERS` sets the gun's active trigger deadline to `frame_start + 1` tick (continuous fire requires holding the key across frames).
- `FULL GUNS` triggers all mounted primary weapon groups simultaneously.
- Disabled ships or ships in the middle of hyperspace transitions cannot fire weapons.

### Per-Step Gun Simulation (`guns_step`, `0x004770E0`)

`guns_step` runs during every 25 Hz simulation step:
1. **Energy Recharge**: The weapon capacitor (`+0x140`) recharges based on `gun_energy`, allocated power distribution (`+0x734`), and gun subsystem health condition (`+0x66C`).
2. **Capacitor Checks**: Before firing, total energy requirements for all active weapons are summed. If capacitor charge cannot cover all firing weapons, the volley does not fire.
3. **Subsystem Damage & Misfires**: When gun subsystem health drops below 90%, weapons have a proportional chance of misfiring.
4. **Alternating Fire**: When alternate fire is enabled, paired guns alternate firing on subsequent simulation cycles.

---

## Projectile Simulation & Collision

When a gun fires, `bullet_fire` (`0x0047C5F0`) allocates an active projectile from a global pool of 200 projectile slots:
- Projectiles spawn at the muzzle node position and travel forward along the muzzle orientation vector at the weapon's defined velocity.
- Range is determined by projectile lifetime in ticks.
- `bullets_move` (`0x0047A4E0`) advances projectile positions every simulation step.
- `bullet_hit` (`0x00479B40`) tests ray-cast segments between the projectile's previous and current positions against candidate targets.

### Impact Resolution
1. **Shield Impacts**: If shields are active in the struck quadrant, the projectile expends its energy against shield hit points, causing shield surface flares ([Effects](effects.md#shields)). Excess damage bleeds through to armor according to weapon armor-piercing ratings.
2. **Armor & Hull Impacts**: If shields are down, the projectile strikes the hull, throwing sparks and inflicting direct damage to quadrant armor.
3. **Component Damage**: On capital ships and stations with component hierarchies, the projectile ray is tested against individual component bounding boxes and collision meshes, damaging targeted subsystems directly.
4. **Spectral Shields**: Ships with active spectral shields deflect matching laser types completely without taking damage.

---

## Projectile Visual Rendering

Projectiles are rendered as billboards, cross-quads, or animated particle assemblies:

| Weapon Type | Visual Representation |
|---|---|
| **Laser Cannon** | Crossed textured quad bolt (60x1200 units). |
| **Pulse Cannon** | Glowing flare orb with orbiting plasma satellite flares. |
| **Meson Blaster** | Three staggered thin bolts offset at random rotational angles. |
| **Proton Cannon** | Large elongated bolt (100x1400 units) with blue falloff. |
| **Gatling Lasers** | Three spinning laser bolts rotating around the trajectory axis. |
| **Tachyon Cannon** | Rotating three-bladed star projectile with leading particle cap. |
| **Neutron Particle Gun** | Wide, semi-transparent bolt (160x1500 units) with randomized per-frame rotation. |
| **Collapser Guns** | Dual spinning energy flares flanking the central trajectory. |
| **Gatling Plasma Cannon** | Four staggered plasma bolts randomized along the flight vector. |
| **Vulcan Battery** | Four short kinetic tracer rounds counter-rotating in pairs. |
| **Nova Cannon** | Massive energy beam (360x10000 units). |
| **Turret Flak** | 3D flak shell model (`shell.shp`) with proximity detonation. |
| **Turret Lasers** | Heavy bolt (400x2400 units) flanked by diamond energy rings. |
| **Capital Huge Guns** | 3D tumbling energy projectile with trailing smoke and particle glow. |

### Dynamic Projectile Illumination
Projectiles emit dynamic point lights (blue for Allied forces, orange for Coalition forces). In the original engine, dynamic lights were restricted to the two most recent shots from the player and enemies. OpenReliant's modern renderer supports dynamic lighting on all active projectiles simultaneously (toggleable via `--few-shot-lights` or `--original`).

---

## Turret Subsystems

Turrets operate in three distinct configurations:

### 1. Aimed Turrets (`turret_aimed_step`, `0x0047D3D0`)
- Articulated turrets feature separate yaw bases and pitch barrels.
- Turrets search for hostile targets within range, calculate lead-aim intercepts using target velocity vectors, and track targets smoothly within mechanical angular limits.
- If the target has active ECM, lead-aim calculations introduce randomized inaccuracy (50%–80% lead factor).
- Once the target falls within the turret's firing cone, the turret triggers its firing animation tracks.

### 2. Spinning Gatling Turrets (`turret_spin_step`, `0x0047C9B0`)
- Barrels spin up when the trigger is active (accelerating by 0.1 rad/tick up to maximum speed).
- Protective heat flaps open during firing and close when spin speed decays.

### 3. Missile Turrets (`turret_missile_step`, `0x0047D560`)
- Automated surface-to-air missile launchers found on capital ships and stations.
- Cycle through states: Searching for targets, Tracking and launching Screamer missiles, and Reloading from magazine racks.

---

## OpenReliant Engine Fixes

- **Rear Fighter Turrets**: In the retail game, fighter tail turrets (such as the Predator's rear gun) had inverted orientation frames, causing them to aim forward into their own hulls and never fire. OpenReliant corrects the reference frame so tail guns track and engage pursuers properly.
- **Turret Target Acquisition**: Fixed a bug where destroyed, cloaked, or untargetable objects remained stuck in turret targeting queues, preventing turrets from acquiring valid targets.
- **Precise Angle Calculations**: Angle conversions use exact mathematical constants rather than truncated single-precision approximations from the original binary.
