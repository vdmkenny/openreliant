# Live objects

The ships, stations, gates, missiles and markers of a running mission. Each is a `0xB98`-byte
object from `gameobj.cpp`, and each embeds the root of a hierarchy of nodes standing for the parts
of its model. The layouts are defined in [`src/lancer/game.zig`](../../src/lancer/game.zig), and
`make ghidra-annotate` applies them to the Ghidra project with the names used here.

## The object array

`game_objects` (`0x587CE0`) holds 400 object pointers, which the engine calls the GO array. A
mission ship's object is in the slot of its index among the mission's ship records, and
`player_index` (`0x5883FA`) is the slot of the player's own. `create_object` (`0x00466C10`) fills a
slot, stopping the game with a fatal error past the last slot or for a slot filled already.

| Offset | Size | Field |
|---|---|---|
| `0x000` | 4 | Type: the ship's record in `shipstats.bin`. Types above 255, markers and nav points among them, have no stats |
| `0x004` | 4 | Slot in `game_objects` |
| `0x008` | 4 | Flags. `0x02`: its components are listed. `0x400`: disabled, not processed. `0x4000`: it has a shield generator |
| `0x010` | 4 | The type's entry in `ship_combat_stats` |
| `0x014` | 4 | The type's entry in `ship_flight_stats`, or a missile's in `missile_flight_stats` |
| `0x018` | 4 | The type's model, as loaded |
| `0x01C` | 4 | Data kept for the type and shared by its objects |
| `0x020` | 4 | The renderer's object for it, or null |
| `0x028` | `0x104` | The root node of its model hierarchy |
| `0x152` | 2 | Components listed |
| `0x248` | `0x2D0` | Up to 60 components, 12 bytes each |
| `0x5D0` | 4 | Engines in its model: parts of subsystem class 5 |
| `0x5D4` | 4 | The share of its engines left: 1.0 when created, less `1 / engines` for each one destroyed |
| `0x5E8` | 4 | Afterburner fuel: `100 * afterburner_fuel` from its stats when created, or zero in one of the game's modes |
| `0x5F0` | 16 | Shields: four values, each `6 * shield_power - 1` when created |
| `0x600` | 16 | Armor: four values, each `6 * armor_class - 1` when created |
| `0x644` | 4 | Nonzero while hostile: `SetHostile` |
| `0x740` | 4 | Its pilot, a record of `pilotstats.bin` (`object_set_pilot`, `0x0049CCE0`) |
| `0x748` | 4 | The pilot's entry in `pilot_stats` |
| `0xB94` | 1 | Set once `create_object` has filled the slot |
| `0xB95` | 1 | Nonzero while invulnerable: `SetInvulnerability` |

A few types take their stats from another type when created, keeping some combat fields of their
own.

## The model hierarchy

A node (`objects.cpp`, `node_alloc` at `0x004991D0`) is `0x104` bytes:

| Offset | Size | Field |
|---|---|---|
| `0x00` | 4 | Kind: 1 for a model part's node |
| `0x04` | 4 | Flags. `0x20`: hidden. `0x100`: listed among the components. `0x2000`: its part has flag `0x1000` |
| `0x08` | 4 | Its frame, the transform the renderer uses |
| `0x14` | 12 | Position, relative to the node it hangs from |
| `0x20` | 36 | Orientation, a 3x3 matrix, relative likewise |
| `0xA4` | 4 | The model part it stands for: the part's record as loaded, which starts with the [`.SHP` part record](../formats/shp.md#part-tag-0x01) |
| `0xA8` | 4 | The object that owns it, set in the root |
| `0xE8` | 4 | A component's counterpart of the object's armor |
| `0xEC` | 4 | The node it hangs from; null for a root |
| `0xF4` | 4 | Capacity of the child list: 100 once created |
| `0xF8` | 4 | Children |
| `0x100` | 4 | The child list |

`node_owner` (`0x00499F20`) finds a node's object by climbing to its root.

A part's node holds the part's origin in its parent part. An object's root holds the object's place
in the world: `object_set_position` (`0x0049B600`) and `object_set_orientation` (`0x0049B650`) set
it, together with the root's frame and further copies at `0x768` and `0x798`, and
`mission_ships_sync` (`0x0045A5F0`) copies it into the mission ship's runtime position.

A frame is Surrender's `0xB4`-byte transform, which `frame_create` (`0x004C51C0`) allocates with a
name, such as `GOroot object` for an object's root. It holds a parent frame at `+0x10`, an
orientation at `+0x18` and a position at `+0x3C`. A part's frame hangs from its parent part's, and
the root frame of an object mounted on an attachment point from the part's.

## Motion

`object_move` (`0x00473FF0`) moves an object for one update. It calls the object's motion function,
the code at `0x640`, then sets the root's next orientation to its orientation times the object's
rotation (`0x56C`), and its next position to its position plus the object's velocity (`0x590`),
and records the length of the velocity as the speed (`0x5D8`). The root keeps that next place at
`+0x5C` and `+0x68`.

`create_object` gives every object `motion_forward` (`0x004744C0`), which runs the flight model,
`object_fly` (`0x004742E0`), with a thrust of 1; `motion_backward` runs it with -1.

| Offset | Size | Field |
|---|---|---|
| `0x56C` | 36 | Rotation: the turn applied each update, a 3x3 matrix |
| `0x590` | 12 | Velocity, added to the position each update |
| `0x5B8` | 4 | Throttle |
| `0x5BC`, `0x5C0`, `0x5C4` | 4 each | Roll, pitch and yaw inputs, between -1 and 1 |
| `0x5C8` | 4 | Lateral input |
| `0x5CC` | 1 | Afterburner |
| `0x5CD` | 1 | **Unknown.** A reverse burn |
| `0x59C` | 4 | Collision radius |
| `0x5D8` | 4 | Speed |
| `0x5DC`, `0x5E0`, `0x5E4` | 4 each | Roll, pitch and yaw rates |
| `0x640` | 4 | Motion function |
| `0x650` | 4 | The last update's throttle |

The flight model works in the ship's own frame, the
[model frame](../formats/shp.md#coordinate-frame): X lateral, Y down, Z forward. Each quantity
moves toward a target through an inertia from the ship's [flight stats](../formats/stats.md):
`new = old * inertia + target * (1 - inertia)`.

1. **Throttle.** It stays between 0 and 1, but is 2 while the afterburner burns and -1 while the
   byte at `0x5CD` is set. Either burns 4 units of afterburner fuel an update, and fuel stops at
   zero.
2. **Turning** (`object_steer`, `0x00474150`). Each input is clamped to between -1 and 1, and each
   angular rate moves toward the ship's rate for that axis times the input, through that axis's
   inertia. For callers that ask, the target is divided by `3 - 2 * |throttle|` where that exceeds
   1, so the ship turns slower at low throttle. The three rates then make the rotation.
3. **Speed.** The velocity is turned into the ship's frame. Along Z, `v * |v|` moves toward
   `u * |u| * target * target`, where `u` is the thrust times the throttle and `target` the cruise
   speed, or `max_speed` while the afterburner or the byte at `0x5CD` is set; the square root, with
   its sign, is the new forward speed. Along X, the speed moves toward a quarter of the target times
   the lateral input. Along Y it only decays. All three use the ship's `inertia`, and the velocity
   is turned back.

The cruise speed (`object_cruise_speed`, `0x00403060`) is `max_speed` times a factor at `0x738`,
1.0 when created, times the share of engines left, and, outside one mode of the game, a factor at
`0x668` that falls as the armor does. So losing engines or armor slows a ship.

## Components

The parts whose [`.SHP` flags](../formats/shp.md#part-tag-0x01) have bit `0x02` are the object's
**components**, such as a capital ship's engines, shield generators and turrets. `create_object`
gives the object a node for each part of its model, all hanging from the root in part order, and a
part's node holds the roots of the objects mounted on the part's gun and pod
[attachment points](../formats/shp.md#attachment-point-tag-0x09). When the model's header asks for
components, `object_collect_components` (`0x00468760`) lists them from the root down: for each node,
first its children that are components, then, child by child, theirs. So the model's own components
come first, in part order, and then, part by part and mount by mount, those of the mounted models.
A component's entry holds its node, the slot of the parent's child list that holds it, and at `+8`
a halfword that is nonzero while the component is invulnerable.

`sltool shp components` lists a model's components in that order, finding the mounted models beside
it, and `sltool dte triggers` and `sltool dte script` name the components missions refer to. Every
component a trigger names in the shipped missions is on its ship's list, and nearly every one a
squad member or `push_component` names. The rest point past the end of the list, mostly by one;
the missions do not always agree among themselves, as when one squad of the Kiev Morzov in
`mission19` holds its turrets as components 3 to 9 and others hold them one by one as 4 to 10.

Mission data names a component by its index in that list: a trigger's qualifier, a squad member's
component, the operand of `push_component`. Events on a component carry its index, and destroying
component `n` clears bit `n & 31` of the mission ship's word at `0x30`.

Commands act on a component through its assembly: the nodes beside it whose parts share its part's
link id, such as a turret and its barrels. The assembly can hold a damaged model too, parts whose
part flag `0x04` is set, which stay hidden (node flag `0x20`) while the component is intact.
`DisableObject` hides the intact parts and shows the damaged ones, and enabling does the reverse; on
a whole ship it sets object flag `0x400` instead. `DestroySubObject` destroys the assembly, keeping
and showing its damaged parts when its second argument asks for them. Destroying an engine lowers
the owner's share of engines left, and destroying a shield generator clears its flag `0x4000`.

`ship_damage_value` (`0x00452CB0`), the value ShotAt events carry, is the lowest of the object's
four armor values, or a component's own.
