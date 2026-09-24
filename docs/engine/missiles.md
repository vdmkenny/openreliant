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
