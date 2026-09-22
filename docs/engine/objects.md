# Live objects

The ships, stations, gates, missiles and markers of a running mission. Each is a `0xB98`-byte object
from `gameobj.cpp`, and each embeds the root of a hierarchy of nodes standing for the parts of its
model. The layouts are defined in [`gameobj.zig`](../../src/engine/game/gameobj.zig),
[`objects.zig`](../../src/engine/game/objects.zig), [`create.zig`](../../src/engine/game/create.zig)
and [`srapiext.zig`](../../src/engine/surrender/surrenderlib/srapiext.zig), and `make
ghidra-annotate` applies them to the Ghidra project with the names used here.

## The object array

`game_objects` (`0x587CE0`) holds 400 object pointers, which the engine calls the GO array. A
mission ship's object is in the slot of its index among the mission's ship records, and
`player_index` (`0x5883FA`) is the slot of the player's own. `create_object` (`0x00466C10`) fills a
slot, stopping the game with a fatal error past the last slot or for a slot filled already.

| Offset | Size | Field |
|---|---|---|
| `0x000` | 4 | Type: the ship's record in `shipstats.bin`. Types above 255, markers and nav points among them, have no stats |
| `0x004` | 4 | Slot in `game_objects` |
| `0x008` | 4 | [Flags](#flags) |
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
| `0x680` to `0x697` | | Its [orders](orders.md): the stack and what the current order keeps, the damage it has taken lately and its last attacker |
| `0x740` | 4 | Its pilot, a record of `pilotstats.bin` (`object_set_pilot`, `0x0049CCE0`) |
| `0x748` | 4 | The pilot's entry in `pilot_stats` |
| `0xB8C`, `0xB90` | 8 | Orders from other players waiting for their frame, in a multiplayer game |
| `0xB94` | 1 | Set once `create_object` has filled the slot |
| `0xB95` | 1 | Nonzero while invulnerable: `SetInvulnerability` |

A few types take their stats from another type when created, keeping some combat fields of their
own.

## Flags

The word at `0x008` is a `GameObject.Flags`. Many of its bits are what the script's `Disable`
commands and their like set; the names in quotes are the developers' labels for their arguments.

| Bit | Name | Meaning |
|---|---|---|
| `0x2` | `components` | Its components are listed, as its model's header asks. The collision code treats such objects apart. |
| `0x4` | `no_collisions` | The collision sweep of `objects_update` leaves it out. |
| `0x8` | `unpowered` | `object_move` runs no motion function for it, so it drifts; knocks still move it. Set while it is disrupted and once it is wrecked, and with `0x10` during gate jumps and warps and by `object_reset`. |
| `0x10` | `frozen` | `object_move` isn't run for it. |
| `0x20` | `stand_in` | Set on objects of types above 255, such as the type-1001 stand-in an empty slot holds. The per-object loops skip them. |
| `0x40` | `exploding` | Set as it starts to explode (`object_destroyed`). It takes no more orders. |
| `0x80` | `can_reverse` | Reverse thrust works only while it is set. |
| `0x100` | `cloaked` | Set by `object_cloak` (`0x00463640`), which posts the Cloaked event. |
| `0x200` | `targetable` | `SetTargetable` for the whole object, which sets it only when the word at `+0x24` of its combat stats is nonzero. |
| `0x400` | `disabled` | Not processed: `DisableObject`, "Stops entities from being processed", and `DisableObjectAtNextJump` at the next jump. |
| `0x800` | `ejected` | Set once its pilot ejects. It takes no more orders, and destroying it now makes it explode. |
| `0x2000` | `lights_disabled` | `DisableLights`. |
| `0x4000` | `shield_generator` | It has a shield generator, which destroying the part clears. |
| `0x8000` | `guns_disabled` | `DisableGuns`. `orders_update` skips `0x0047C950` for it. |
| `0x10000` | `missiles_disabled` | `DisableMissiles`. |
| `0x20000` | `engines_disabled` | `DisableEngines`. `object_orders` holds its throttle at zero and stops both burns. |
| `0x40000` | `eject_disabled` | `DisableEject`. The player cannot eject. |
| `0x80000` | `do_not_disturb` | `DoNotDisturb`, "dont disturb", which the command describes as keeping comms from disturbing it. It does not retaliate either. |
| `0x100000` | `no_avoidance` | `SetShipAvoidance` with "Disable Avoidance code": the avoidance code passes it over. |
| `0x200000` | `jumping` | Set during the jump orders. It cannot fire, and the avoidance code passes it over. |
| `0x400000` | `attached` | Set while the Dock and Ripper orders hold it to another object; their ends clear it. |
| `0x10000000` | | **Unknown.** Set by `0x00474B40` as it sends a ship off, the player's into Friendly Fire and others into Jump Out, and cleared by Friendly Fire. It takes no orders while it is set. |
| `0x20000000` | `unlisted` | `DisableListing`, "stop listing". |

**Unknown:** the other bits.

## The model hierarchy

A node (`objects.cpp`, `node_alloc` at `0x004991D0`) is `0x104` bytes:

| Offset | Size | Field |
|---|---|---|
| `0x00` | 4 | Kind: 1 for a model part's node |
| `0x04` | 4 | Flags, a `Node.Flags`: `0x20` hidden; `0x40` a component's holder once `component_damage` (`0x004645C0`) takes the component's armor below zero; `0x100` listed among the components; `0x2000` targetable, for the parts whose part flag `0x1000` says so, and changed by `SetTargetable`. Cycling subtargets (`0x00414F90`) stops only at components that are targetable and have neither `0x10` nor `0x20` |
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

A part's node holds no turn: `node_add_part` (`0x00499430`) copies the part's position and leaves
the node's orientation the identity it was allocated with. It hides a part whose part flag `0x04`
marks it damaged. `create_object` hangs every part's node from the root (`object_add_part`,
`0x004760C0`, which takes the object's centre at `0x524` off the position), then
`object_link_parts` (`0x00476130`) hangs each from its parent part's node, keeping it where it is,
and moves the object's origin to its parts' centre of mass (`object_recentre`, `0x004769F0`).

A part keeps its origin in the model whatever it hangs from, so hanging it somewhere else has to
work that origin out again in the new frame, which `node_place` (`0x0049A140`) does: the part's
origin less the origin of its parent's part, or less the object's centre for one hung from the
root, plus whatever the animation has moved it by, turned about the part's mount point by the
part's angles and the animation's. `object_link_part` runs it through `node_animate`
(`0x00499F40`) at time zero, which reads the part's animation track, and copies the place it
leaves into the node and its frame. With no animation the sums cancel and every part stands where
it stood.

The centre of mass:

- `node_mass_add` (`0x004764A0`) sums over the shown part nodes, a node's children first, the
  density times the part's first moment about the root: its origin there times its volume, plus its
  own first moment. Over the sum of density times volume, that is the centre.
- The centre is added to the object's centre at `0x524` and, turned, to its position, and
  `object_bounds` (`0x00476680`) takes it off the position of each part hung from the root.
- `object_bounds` then finds the object's bounding box and radius, its farthest vertex from the
  origin, over the vertices of every part node's current level, and sums its moment of inertia.

An object's root holds the object's place in the world: `object_set_position` (`0x0049B600`) and
`object_set_orientation` (`0x0049B650`) set it, together with the root's frame and further copies
at `0x768` and `0x798`, and `mission_ships_sync` (`0x0045A5F0`) copies it into the mission ship's
runtime position.

A frame is Surrender's `0xB4`-byte transform, which `frame_create` (`0x004C51C0`) allocates with a
name, such as `GOroot object` for an object's root. It holds a parent frame at `+0x10`, an
orientation at `+0x18` and a position at `+0x3C`. A part's frame hangs from its parent part's, and
the root frame of an object mounted on an attachment point from the part's.

## What an attachment point holds

`node_mount` (`0x00499A10`) mounts what a part's attachment points carry, by the attachment's kind:
an engine glow for kind 2 and a light for kind 4, which are nodes of the part's own, and for a gun
or a pod an object of its own, whose model `attachment_models` names by the attachment's kind and
id, twenty ids to a kind.

A mounted object is built the way any other is: a node for each part of its model, then
`object_link_parts`, which also moves its origin to its own centre of mass. Its root then hangs
from the node of the part that carries the attachment, and stands where the attachment does: the
attachment's position, plus that centre turned by the attachment's orientation, so its geometry
stands where its own model puts it. Its orientation is the attachment's.

A capital ship carries its turrets this way, where a fighter carries its own as a model part of
subsystem class 3 with its own yaw and pitch limits.

## Motion

`object_move` (`0x00473FF0`) moves an object for one update. It calls the object's motion function,
the code at `0x640`, then sets the root's next orientation to its orientation times the object's
rotation (`0x56C`), and its next position to its position plus the object's velocity (`0x590`),
and records the length of the velocity as the speed (`0x5D8`). The root keeps that next place at
`+0x5C` and `+0x68`.

Before that, it checks the flags:

- A `frozen` object isn't moved at all.
- If the object has taken knocks since its last move, they are applied in place of the motion
  function (see [Knocks](#knocks)). An `unpowered` object has no motion function run either.
- A `jumping` object that isn't knocked or `unpowered` stays where it is.

After the move, it sets bit 0 of the network flags (`0x00C`) if the object is moving and bit 1 if
any of its angular rates is nonzero. The multiplayer code (`0x004BB2D0`) then sends the object's
position and orientation. Bit 2 is set while the Scoop Up order runs, and the multiplayer code
skips such objects.

For the player's ship, `object_move` raises the camera's shake (`hit_shake`) to at least
`0.2 * (speed / cruise speed - 1)`, so the view shakes when the ship flies faster than its cruise
speed, as it does under afterburner. It also stores the change in the player's speed at
`0x00562CE4`, which nothing reads.

`object_move` also sets bit 0 of the root's node flags, marking the next place as pending. At the
start of the next simulation step, before the objects move, `simulation_step` runs
`node_tree_update` (`0x00476C90`) for every live object. It commits the pending next place by
copying the 0x48 bytes from `+0x5C` over those from `+0x14` (the next position and orientation
over the current ones), clears bit 0 and sets bits 1 and 2. It does the same for each animating
part, whose animation it also advances. So an object moves on from the place the previous step
worked out, and between steps its `position` is one step behind `next_position`, which the rest
of the game reads as the object's place.

Each step, before the node updates, `simulation_step` also orthonormalizes the root's next
orientation (`0x004C2690`) of one object, the one `simulation_turn` (`0x00562FFC`) names. The turn
moves on by one each step and goes round the live objects, so rounding never builds up in any
object's orientation. The same object's orientation at `0x7A4`, which a multiplayer game draws
other players' ships by, is orthonormalized too.

`create_object` gives every object `motion_forward` (`0x004744C0`), which runs the flight model,
`object_fly` (`0x004742E0`), with a thrust of 1; `motion_backward` runs it with -1. The orders
select the others (see [The orders' motion functions](#the-orders-motion-functions)).

| Offset | Size | Field |
|---|---|---|
| `0x00C` | 4 | Network flags |
| `0x51C` | 4 | Knocks since the last move |
| `0x520` | 4 | Mass: the sum of the parts' masses (`object_recentre`) |
| `0x524` | 12 | How far `object_recentre` moved the origin to the centre of mass |
| `0x530` | 12 | Impulse: the sum of the knocks' forces |
| `0x53C` | 12 | Angular impulse: the sum of the knocks' force × lever |
| `0x548` | 36 | The inverse of the inertia tensor |
| `0x56C` | 36 | Rotation: the turn applied each update, a 3x3 matrix |
| `0x590` | 12 | Velocity, added to the position each update |
| `0x5B8` | 4 | Throttle |
| `0x5BC`, `0x5C0`, `0x5C4` | 4 each | Roll, pitch and yaw inputs, between -1 and 1 |
| `0x5C8` | 4 | Lateral input |
| `0x5CC` | 1 | Afterburner |
| `0x5CD` | 1 | Reverse thrust |
| `0x59C` | 4 | Collision radius |
| `0x5D8` | 4 | Speed |
| `0x5DC`, `0x5E0`, `0x5E4` | 4 each | Roll, pitch and yaw rates |
| `0x640` | 4 | Motion function |
| `0x650` | 4 | The last update's throttle |
| `0x668` | 4 | `armor_speed_factor`: scales the cruise speed as the armor falls |
| `0x738` | 4 | `speed_factor`: scales the cruise speed; 1.0 when created |

For the player's ship, the [controls](controls.md) set the inputs, the throttle and the two burns;
for the others, the routines of their [orders](orders.md).

The flight model works in the ship's own frame, the
[model frame](../formats/shp.md#coordinate-frame): X lateral, Y down, Z forward. Each quantity
moves toward a target through an inertia from the ship's [flight stats](../formats/stats.md):
`new = old * inertia + target * (1 - inertia)`.

1. **Throttle.** It stays between 0 and 1, but is 2 while the afterburner burns and -1 under
   reverse thrust. Either burns 4 units of afterburner fuel an update, and fuel stops at zero.
2. **Turning** (`object_steer`, `0x00474150`). Each input is clamped to between -1 and 1, and each
   angular rate moves toward the ship's rate for that axis times the input, through that axis's
   inertia. For callers that ask, the target is divided by `3 - 2 * |throttle|` where that exceeds
   1, so the ship turns slower at low throttle. The three rates then make the rotation.
3. **Speed.** The velocity is turned into the ship's frame. Along Z, `v * |v|` moves toward
   `u * |u| * target * target`, where `u` is the thrust times the throttle and `target` the cruise
   speed, or `max_speed` under afterburner or reverse thrust; the square root, with its sign, is
   the new forward speed. Along X, the speed moves toward a quarter of the target times the lateral
   input. Along Y it only decays. All three use the ship's `inertia`, and the velocity is turned
   back.

The cruise speed (`object_cruise_speed`, `0x00403060`) is `max_speed` times `speed_factor`
(`0x738`), 1.0 when created, times the share of engines left, and, unless the camera is in view 13
or the object is invulnerable, times `armor_speed_factor` (`0x668`), which falls as the armor does.
So losing engines or armor slows a ship.

### Knocks

Collisions and explosions push objects with `object_knock` (`0x004763C0`), which takes a force and
the world point it acts at. It adds the force to the impulse (`0x530`), adds force × lever to the
angular impulse (`0x53C`), where the lever runs from the object's position to the point, and counts
the knock (`0x51C`). The engine takes the cross product in that order, which gives the opposite of
the torque. `object_knock_local` (`0x00476430`) does the same with the force in the object's own
frame and the lever given directly; the Disrupted order pushes a ship with it, with no lever.

The next `object_move` applies the knocks with `object_apply_knocks` (`0x00476270`) instead of
running the motion function:

1. The impulse times `1 / mass` is added to the velocity.
2. If the angular impulse isn't zero, it is converted to the object's frame and multiplied by the
   inverse inertia tensor (`0x548`), which `object_recentre` builds from the parts
   (`object_bounds`) and inverts (`0x004AD9F0`). The rotation is turned by the negative of the
   result, to first order, and orthonormalized (`0x004C2690`), and the angular rates are set to
   its angles (`0x004C2740`). So the object keeps spinning until its steering takes over again.
3. The count and both impulses are cleared.

`0x004C2740` takes its angles from `sr_atan2` (`0x004C3200`), which looks them up in a table of the
arctangents of 0 to 1 in steps of 1/4096 (`0x005DE344`), by the smaller of `y / x` and `x / y`
rounded to the nearest step.

**Improvement:** the port computes the angles instead, which is more precise by up to half a step.

### The orders' motion functions

The orders select eight more motion functions, which read the order's state (`0x68C`). They aren't
ported yet ([#30](https://github.com/vdmkenny/openreliant/issues/30)).

| Address | Selected by | What it does |
|---|---|---|
| `0x004744E0` | Launch orders, the Ripper | Steers, then moves the velocity through the flight stats' `inertia` toward the throttle times `max_speed`, along the object's Y axis. Models of kind 1 use fixed flight stats (`0x004F9E70`). |
| `0x00474570` | The Ripper, launch and landing orders | The same along the Z axis, and keeps the throttle as the last update's. A flight model without the throttle rules or the burns. |
| `0x00474610` | Eject | Slows the velocity to 0.97 of itself each update. |
| `0x00474640` | Jump Out | Places the object between the two points of the order's state, each coordinate eased by the time since the jump started. No rotation. |
| `0x004746D0` | Jump In | Flies along the nose at 2400, or 600 for an object without components, less 0.003 of that per unit of time since the jump started, but never slower than the cruise speed. No rotation. |
| `0x00474770` | Follow Curve, Dock | Steers toward the point the order's state gives and moves toward it, no faster than the order's speed limit. |
| `0x00474930` | Follow Curve | The same, flying tail first. |
| `0x00474B00` | Jump In | Slows the velocity to 0.99 of itself each update. |

### Porting

[`gameobj.zig`](../../src/engine/game/gameobj.zig) holds the model: `cruiseSpeed`, `steer`, `fly`,
`move`, `knock`, `knockLocal` and `applyKnocks`. The port passes the flight stats and the camera
view in, where the game reaches them through the object's own pointer and a global, because
`GameObject` keeps the binary's 32-bit pointers for its layout. For the same reason `move` takes
the camera's shake as a pointer, set only for the player's ship, where the game compares the slot
with the player's and writes the global. `Motion` is an `enum` of the two routines
`create_object` installs, in place of the function pointer at `0x640`, and the rule each quantity
settles by is one `settle` helper rather than the six copies the binary holds.

`objects.updateTree` ports `node_tree_update` for the root, and the driver runs it where
`simulation_step` does, at the start of each step, after `main.orthonormalizeTurn` on the object
whose turn it is (`Clock.nextTurn`).

Not yet ported: the orders' motion functions
([#30](https://github.com/vdmkenny/openreliant/issues/30)), the inertia tensor that
`object_recentre` inverts into `0x548` ([#87](https://github.com/vdmkenny/openreliant/issues/87)),
so knocks don't turn objects in the port yet, and the parts' animation in `node_tree_update`
([#119](https://github.com/vdmkenny/openreliant/issues/119)).

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
a whole ship it sets the object's `disabled` flag instead. `DestroySubObject` destroys the assembly, keeping
and showing its damaged parts when its second argument asks for them. Destroying an engine lowers
the owner's share of engines left, and destroying a shield generator clears its `shield_generator`
flag.

`ship_damage_value` (`0x00452CB0`), the value ShotAt events carry, is the lowest of the object's
four armor values, or a component's own.
