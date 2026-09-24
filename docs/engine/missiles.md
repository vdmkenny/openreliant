# Missiles

`missiles.cpp` keeps the missiles in flight, their trails and their stats; the launchers, the lock
and the loadout live in the files that call it. The port is
[`game/missiles.zig`](../../src/engine/game/missiles.zig).

**Unverified:** the file's extent. The assertions name its path from `0x00494CB0` to
`0x00496B0E`; the strings and the data its code uses (`missilestats.bin`, `MissileTrail BMO`,
`Missilebursttrail mesh`) place `stats_load_missiles` (`0x00494BC0`) and everything to
`0x00498443`, `order_torpedo` among it, in it too.

## Types

A missile's type is the id of the missile hardpoint (attachment kind 0) that holds it, the type of
its object, and its index into every missile table.

| Type | Name | Hardpoint holds | Missiles | Guidance |
|---|---|---|---|---|
| 0 | Screamer | `01_screamer_pod.shp`, of `01_screamer.shp` | 20 | Straight when a player fires it outside multiplayer; else homing |
| 1 | Raptor | `02_raptor_pod.shp`, of `02_raptor.shp` | 3 | Homing |
| 2 | Havoc | `03_havoc.shp` | 1 | Homing, ends within 10000 of its target; shockwave kind 5 |
| 3 | Jack Hammer | `04_jackhammer.shp` | 1 | Homing |
| 4 | Bandit | `05_bandit.shp` | 1 | Homing |
| 5 | Vagabond | `06_vagabond.shp` | 1 | Homing, on a cloaked target too |
| 6 | Solomon | `07_solomon_pod.shp`, of `07_solomon.shp` | 4 | Picks its own target |
| 7 | Imp | `08_imp.shp` | 1 | Homing, ends within 10000 of its target; shockwave kind 6 |
| 8 | Hawk | `09_hawk_pod.shp`, of `09_hawk.shp` | 4 | Homing |
| 9 | Torpedo | | | None: only the torpedoes' trail and sound |
| 10 | Fuel pod | `fuel_pod.shp` | 1 | Let fall: 5000 more afterburner fuel while it hangs |

## Stats

`missile_stats` (`0x005037A0`) holds `0x28` bytes a type, and `missile_flight_stats`
(`0x005035E8`) a flight model a type. The executable holds its own words for each, and
`stats_load_missiles` (`0x00494BC0`) reads up to 11 records of `missilestats.bin`
([Stats](../formats/stats.md#missiles)) over them, keeping in whole numbers what `__ftol` cuts
down:

| Offset | Field | From |
|---|---|---|
| `0x00` | 30 for every type; nothing reads it | Executable |
| `0x04` | The launch's 3D sound: 15 (`MISSILE01`) to 23 for types 0 to 8, 24 for 9, none for 10 | Executable |
| `0x08` | Flight time, in ticks | `0x48 * 100` |
| `0x0C` | Shield damage | `0x4C` |
| `0x10` | Hull damage | `0x50` |
| `0x14` | Component damage | `0x60` |
| `0x18` | The guidance order once the launch is over: type + 2 for 0 to 8, 0 for 9, 11 for 10 | Executable |
| `0x1C` | Lock time, in ticks | `0x54` |
| `0x20` | Decoy chance, in percent | `0x58` |
| `0x24` | Lock range | `0x5C` |

Before loading, a record holds a flight time of 1000 ticks (12000 for 9 and 10), damages of 290,
180 and 180, a lock of 200 ticks, a decoy chance of 50 and a lock range of 50000. The flight model
takes the speed, and the turn rate for all three rates; the rest is the executable's: an inertia of
0.84 and rate inertias of 0.71, for a speed of 300 and turn rates of 0.14 before loading (50 and
0.05 for type 9, and all zero for type 10).

## The loadout

A ship carries its missiles in racks, one for each of its missile hardpoints: 20 records of `0x0C`
bytes at `GameObject + 0x158`, `rack_count` of them (`+0x150`).

| Offset | Field |
|---|---|
| `0x00` | Missile type, i16; below 0 for none |
| `0x04` | Where the node of the part that carries the hardpoint lists the hung pod or missile |
| `0x08` | Missiles left |

`create_object` fits them after the guns:

1. The tier: 5 is 4, and outside 0 to 4 is 0. A fighter (types 0 to 11) asked for 0 takes
   `campaign_tier` (`0x00562DF0`), and then any 4 is 0. A mission's ship record asks with its byte
   `0x3D`: 0 and 255 for the campaign's tier, 4 and 5 for tier 0. The campaign's tier is 0 for a
   new pilot and rises to 1, 2 and 3 after the 11th, 19th and 21st missions
   (`mission_end_record`).
2. The types (`object_loadout_by_tier`, `0x0045E500`): each missile hardpoint of the parts that
   hang from the root, in turn, takes the missile its attachment names for the tier: its id for
   tier 0, and the low half of the four words after it for tiers 1 to 4. A player's ship takes the
   racks the player chose on the loadout screen instead (`0x00588400`, `0x54` bytes a player),
   unless the briefing is skipped.
3. The fitting (`object_fit_missiles`, `0x0045E1A0`): on each hardpoint, in turn, hangs what its
   rack holds, the pod or the missile (`attachment_models`), and fills the rack with the pod's
   capacity, or 1. A rack of no missile ends the loadout: its count is 0 and every hardpoint after
   it reads the same rack.
4. 5000 more of the afterburner's fuel for each fuel pod, and 29 countermeasures.

A re-arm (`order_dock`, `cmd_ReplenishWeapons`) lets go of what hangs and fits the racks again, by
the tier at `GameObject + 0x648`, which nothing writes.

The port fits a player's ship by the tier, as the game does when the briefing is skipped; the
loadout screen is not ported (#44). The hardpoints of a part that hangs from another part are never
reached, as in `Jap_Sai.SHP` and `Chin_Han.SHP`. **Unverified:** that the root lists its parts in
the order the model does, which is the order the port walks.

## Flight

`missiles` (`0x005887F0`) holds 200 records of `0x28` bytes, and `0x005887F4` the newest live one;
each links to the one launched before it and after it.

| Offset | Field |
|---|---|
| `0x00` | The tick its launch or jettison began, which its flight time counts from; -1 while free |
| `0x04` | Its object, from `object_alloc`, which no slot of `game_objects` holds: nothing else collides with it, targets it or shows it on the radar. Its type is the missile's |
| `0x08` | Its launcher's slot |
| `0x0C` | The countermeasure it chases, or -1 |
| `0x10` | Its trail |
| `0x14` | Its type's stats |
| `0x18`, `0x1C` | In a network game, the player who launched it and the id it goes by there |
| `0x20`, `0x24` | The missiles launched before it and after it |

Its object keeps a stack of one order (`0x684`), whose target (`+0x04`) and component (`+0x06`) it
flies at, and whose order is one of the table at `0x00503D20`, each with an `init` and an `update`.

### The launch

`missile_launch` (`0x00496290`) takes a rack, a target and its component. It does nothing for a
ship whose missiles are disabled, or with no record free.

- A pod with missiles left builds a missile of its own from the pod's second model, where the pod
  hangs; anything else, a rail's missile, a fuel pod or an empty pod, is itself let go of.
- The missile takes three places from where that hung: the launcher's place, its next place and
  its drawn frame, so it is drawn on from where it was. Its root is marked committed and unframed.
  It takes the launcher's velocity and side.
- Its launch sound (`stats + 0x04`) plays at its next place, facing the way it moves, on a sure
  voice for the player's missile. The voice follows it no further, and ends with its length.
- One fewer is left in the rack. A pod's missile flies the pod launch and a rail's the rail launch,
  each with its trail; a fuel pod and an empty pod are jettisoned. Then it takes its target.
- A pod whose last missile this was is launched too, at nothing, and so jettisoned.

`missile_order_set` (`0x00496AA0`) runs the new order's `init`, sets it, then runs its `update`.

### Orders

| Order | Update | What it does |
|---|---|---|
| 0 | `0x00496B20` pod launch | Throttle 2, no steering; after 50 ticks, the type's order |
| 1 | `0x00496B60` rail launch | No steering. For 25 ticks, throttle 0 and a drop along its Y axis of 0.005 of its top speed a tick; for 25 more the same back up; then throttle 1; after 100 ticks, the type's order |
| 2 | `0x00497F10` Screamer | Flies straight (`0x00496C60`: throttle 1, no steering) when a player launched it outside a multiplayer game; otherwise homes |
| 3, 5 to 7, 10 | `0x004983B0` | Homes (`missile_home`) |
| 4, 9 | `0x00497F30` proximity | Havoc and Imp: ends within 10000 of the target's root, else homes |
| 8 | `0x00497F80` Solomon | Picks a target while it has none to aim at, then homes |
| 11 | `0x00498410` jettison | Throttle 0, no steering; ends 100 ticks on. Its `init` (`0x004983C0`) adds 50 along its Y axis to its velocity |

The launches' `init` (`0x00496B10`) and the jettison's keep the tick they began at.

### Homing

`missile_home` (`0x00496C90`) steers at the target while it is one to aim at
(`order_target_valid`), a cloaked one too for a Vagabond:

1. The aim is the target's node (`ai_target_node`), led along the target's nose by the distance to
   it times the target's speed over the missile's top speed. A decoyed missile aims at the
   countermeasure instead, and ends with it within 1000.
2. Beyond 1,000,000, the target is lost.
3. The throttle is the cosine of the angle off the aim, at least 0.
4. With the aim ahead, pitch and yaw take the angles off it, in radians less four times the rates,
   times 5.72958, within 1 either way: fully over ten degrees off. With the aim behind, no pitch
   and full yaw toward its side. No roll.
5. With the target lost, a missile whose trail has the Solomon's look flies straight; any other
   ends.

**Improvement:** the port works the gain out as 18 over pi.

The Solomon's choice (`0x00497F80`) is among the objects of other sides to the missile's that are
ones to aim at: of those that list no components, the nearest whose direction lies within 0.7 of
the missile's nose, else the nearest at all, by their drawn places; with none, likewise among the
components of those that list them, by where their nodes are drawn, or the object itself where
none of its components is one to aim at. With nothing, it flies straight.

### Each step and each frame

`missiles_move` (`0x00495720`), after `objects_update` each step: each missile takes its next
place, eases its pitch and yaw rates toward its inputs times its turn rates by its rate inertias,
turns by them, and moves. Its velocity is damped by its inertia, save in its launches and its
jettison, and pushed along its nose by the rest of it times its throttle and top speed. It never
rolls, and nothing knocks it.

`missiles_update` (`0x004960F0`), once a frame after the objects are framed, runs each missile's
order. Within its flight time, it tests the missile for contact, and with none, frames it and draws
it, its engine glows by its throttle. A missile with a target and no decoy lights that target's
missile warning (`missile_homing`), but not a player's Screamer outside a multiplayer game. Past
its flight time, it ends. In a multiplayer game it also drops the target of a player's missile
whose lock is broken, and ends one whose launcher is gone.

### Contact

`missile_collide` (`0x00495CF0`) tests the segment from the missile's drawn place to its next place
against every object of type below 256 that collides, but its launcher, of any side:

- An object that lists components: its parts (`missile_hit_components`, `0x00495AC0`), by their
  collision trees at their next places (`object_hit_test` with `missile_hull_test`, `0x004959A0`):
  within the boxes the segment meets, each face the segment starts in front of, no further off
  than it is long, is tested, and the last face crossed counts. But for a Havoc or an Imp, the part
  struck takes the type's component damage.
- Any other: whether the segment passes within its radius. A Havoc or an Imp just ends there.
  Otherwise, where it first meets the sphere, the quadrant (`0x00463CA0`):
  - With the quadrant's shield below 0, or `invulnerable` at 4: `missile_hit_hull` (`0x00495BB0`).
    The parts that hang from the root are tested by the boxes of their meshes; where the segment
    meets one, the quadrant's armour takes the type's hull damage and the hit sounds.
  - Otherwise, with a shield damage above 0: the shield takes it, with the hull damage over the
    shield damage as the share that passes through (`object_damage`), five times over in a
    multiplayer mission. The player's ship takes it only on the fore quadrant, and only as the hit
    empties a [shield reserve](controls.md#the-shield-balance): the fore's while it holds anything, else
    the aft's. With neither holding anything, or on any other quadrant, the player's shields take
    nothing. **Unverified** in play.
  - The shield flares at the point unless the object is cloaked.

The missile's velocity is zeroed and it ends. A Screamer's damage counts as kind 5, any other's as
kind 1.

`missile_hit_hull` walks on past the first part met with the segment cut short to where it entered
that part, but in the part's own frame, so no part after it is truly tested.

**Fix:** where the segment meets no part's box, `missile_hit_hull` still reports contact without
ending the missile, so it is not drawn that frame and flies on. The port reports none, and draws it.

### The end

`missile_end` (`0x00495870`) ends the voice its object holds, where it holds one; sets off a
Havoc's shockwave (kind 5) or an Imp's (kind 6) where it is drawn, 50000 across over 500 ticks,
sparing its launcher's side ([Effects](effects.md#shockwaves)); and its blast
(`missile_explode`, `0x0046E370`): 50 sparkles, living one to three seconds, and a lit fireball
from the sheet, three times its radius across over a second, both drifting at a quarter of its
velocity, and `EXPLOSION01` among the explosions. Its trail fades out from there, and its object and
record are freed.

`missiles_reset` (`0x00494D80`) frees every missile as a mission ends.

The port keeps the missiles with the objects (`create.Objects.missiles`). Not yet ported: the
trails, the countermeasures, the lock and what launches them.
