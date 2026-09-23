# Guns

How a ship is fitted with guns, how they are grouped, and what a simulation step does with them.
The gun types' figures and where they come from are in
[`formats/stats.md`](../formats/stats.md#guns); the shot a gun fires is
[#151](https://github.com/vdmkenny/openreliant/issues/151).

## The guns a model holds

`object_fit_guns` (`0x00479800`) walks the object's model when it is created, once to count its
guns and once to fill them in, and allocates `gun_count` records of `0x60` bytes at `+0x134` and a
word for each gun at `+0x138`. A gun comes from an
[attachment point](../formats/shp.md#attachment-point-tag-0x09) of kind 3, a muzzle, and fires the
gun type the attachment names at `+0x64`. A muzzle that names type 0 is a warning and fires type 1
instead. A turret part takes a gun of its own by its turret kind, which is not ported
([#71](https://github.com/vdmkenny/openreliant/issues/71)).

A gun's record holds its turret kind at `+0x00`, the node it fires from at `+0x04`, its type's
record in `gun_stats` at `+0x08`, the tick its trigger is held until at `+0x0C`, which side of its
group it is at `+0x14`, and the tick it may next fire at `+0x18`. The word at `+0x138` counts the
steps it has been firing, which times the sound of its shots.

## Groups

`gun_groups_build` (`0x004667F0`) works a ship type's gun groups out from the first object of the
type created, and keeps them in the type's table at `0x00545900`, `0x78` bytes a type: 20 groups of
6, each two halfword gun indices and a halfword the game never writes. It pairs each gun with the
gun of its own type nearest its mirror image across the ship, closest pair first, and the gun
further to the left leads its group. A gun with nothing to mirror makes a group of its own. Turrets
of kind 1 and 3 are left out, and a type with no model gets no groups.

`create_object` then marks each gun with its side, 0 for the gun that leads its group and 1 for the
other, and starts the ship on `gun_mode`: group 0, synchronised, and firing every group at once
unless the type has exactly one.

## The trigger

`object_fire_guns` (`0x0047B1F0`) holds the trigger of the guns that are to fire, setting each
gun's `+0x0C` to `frame_start` plus the ticks it is given. FIRE LASERS holds it for one tick, so
the player's guns fire this frame and stop unless the key is held into the next; the mission
script's Fire command holds it for 20 or 100. With FULL GUNS every gun fires but a turret's,
otherwise the two guns of the chosen group do. A muzzle of gun type 11, the Nova Cannon, is passed
over either way: it charges up instead
([#150](https://github.com/vdmkenny/openreliant/issues/150)). A ship whose guns are disabled fires
none.

## The step

`guns_step` (`0x004770E0`) runs for every object each simulation step, after its shields recharge.
An object whose components are listed steps no guns of its own.

The guns' charge (`+0x140`) grows by the type's `gun_energy` times the guns' share of the power
(`+0x734`) and their condition (`+0x66C`), over `ShipCombat._unknown_14` seconds of steps, and
stops at `gun_energy`. A ship charging up a gun does not recharge while its charge is not zero.

Then each gun whose trigger is held fires, once its refire interval has passed:

- The guns about to fire are added up first, and each is held against the charge the step began
  with, so a ship that cannot pay for all of them fires none rather than some. A shot of a gun
  whose type draws energy takes `Gun.shot_energy` from the charge; one whose type fires rounds
  takes one of the object's rounds (`+0x13C`), which the gunnery window shows.
- A ship whose gun condition is below 0.9 misfires: a shot goes off only as often as the condition
  and a tenth allow.
- While the ship fires one group of guns and not in step, the group's two guns fire in turn: a gun
  fires only when its side is the ship's turn (`+0x14C`), which passes to the other side after the
  pass.
- The interval begins again whether or not the shot went off, and a ship aiming blind takes 135
  ticks for every 100.
- The player's shots are all heard; another ship's are heard one step in every
  `gun_sound_periods` of its type.

A ship that is jumping fires nothing, though its guns still recharge.

## The port

[`guns.zig`](../../src/engine/game/guns.zig) holds the fitting (`fit`), the groups (`buildGroups`),
the trigger (`fire`) and the step (`step`), which `simulationStep` runs for every object and
`playerControls` triggers from FIRE LASERS. `gun_stats` lives in `create.Objects.gun_stats`, and
the executable's own half of each record is
[`guns/stats.zig`](../../src/engine/game/guns/stats.zig), which `make gun-tables` derives from the
payload.

Not ported: the shot itself, so firing costs the ship its charge or a round and nothing leaves the
muzzle ([#151](https://github.com/vdmkenny/openreliant/issues/151)); the Nova Cannon's charge
([#150](https://github.com/vdmkenny/openreliant/issues/150)); turrets, their aiming and the guns
they carry ([#71](https://github.com/vdmkenny/openreliant/issues/71)); and the gunnery keys that
choose a group or fire them all ([#92](https://github.com/vdmkenny/openreliant/issues/92)).
