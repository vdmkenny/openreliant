# Game Loop & Simulation Architecture

This document describes how StarLancer paces simulation and rendering. The engine uses a dual-rate architecture: a 100 Hz timer tick advances game clocks, and a 25 Hz simulation step advances physics, flight movement, AI orders, and collision detection.

Symbol names referenced below correspond to annotations in the Ghidra project.

---

## Timers & Ticks

- **100 Hz Game Tick**: Driven by a periodic multimedia timer (`timer_start` / `tick_timer`, `0x004827C0`). Unless paused (`paused`, `0x57E04C`), each tick increments `game_ticks` (`0x565064`) and game play time counters.
- **Mission Time**: Incremented as `mission_ticks` (`0x587CC4`); paused during in-game menus.
- **Script Timer**: A separate 1 Hz timer advances the mission script clock ([Script VM](script-vm.md)).

---

## Frame Execution (`mission_run`)

The primary game loop (`mission_run`, `0x00494040`) decouples rendering from game logic:

1. **Simulation Catchup**: For each pending 100 Hz tick since the previous frame, `game_tick` (`0x00477850`) executes.
2. **25 Hz Physics Step**: Every fourth tick, `game_tick` triggers `simulation_step` (`0x004774D0`):
   - Updates object state and evaluates flight physics ([Objects](objects.md#motion)).
   - Invokes `objects_update` (`0x00468FA0`) to move entities via `object_move` and resolve collisions.
   - Updates projectile trajectories for missiles (`missiles_move`) and laser shots.
3. **Per-Frame Rendering (`mission_frame`)**:
   - Executes AI orders via `orders_update` ([Orders](orders.md)).
   - Flushes pending mission script events.
   - Smoothly interpolates object rendering positions between the previous two simulation steps ([Objects](objects.md#drawing-between-steps)).

---

## Port Enhancements

In OpenReliant ([`src/engine/game/main.zig`](../../src/engine/game/main.zig)):
- **Monotonic Timing**: Replaces Windows multimedia timers with monotonic platform timestamps (`advanceTo`). The simulation runs the exact number of accumulated 100 Hz ticks without drift or frame-rate dependency.
- **Sub-Tick Interpolation**: `objects.stepFraction` tracks elapsed time between ticks, allowing smooth motion interpolation at high monitor refresh rates (144 Hz+). Use `--no-smooth-motion` or `--original` to force authentic 100 Hz stepped motion.

---

## Collision Detection & Response

After positions update, `objects_update` performs collision checks:

1. **Broadphase Sweep**:
   - Computes bounding sphere extents (`collision_radius` * `visibility`).
   - Sorts active objects along the X axis and tests potential overlapping pairs.
   - Filters out non-colliding entity combinations (e.g., objects flagged in `passes_through`, friendly torpedoes, or debris).
2. **Narrowphase & Hull Tests (`objects_collide`, `0x00466170`)**:
   - Simple entities (fighters, missiles) collide using bounding spheres.
   - Complex ships (capital ships, stations) test against hierarchical collision trees ([SHP Models](../formats/shp.md#tree-node-tag-0x07)), descending to individual model mesh polygons.
3. **Collision Impulse & Knock (`0x00464E80`)**:
   - Calculates contact points and relative velocities.
   - Computes collision impulse based on respective ship masses and angular response factors.
   - Applies equal and opposite velocity impulses via `object_knock`.
   - Separates overlapping objects by 1.1x their radii along the collision normal to prevent sticking.
4. **Collision Damage**:
   - Damage scales proportionally with collision impulse relative to ship mass (`collision_damage`, `0x00465CA0`).
   - Impact damages the directional shield quadrant first (fore or aft). If shields fail, residual damage penetrates into hull armor.
