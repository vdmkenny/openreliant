# Guns

How a ship is fitted with guns, how they are grouped, what a simulation step does with them, and
the shots they fire. The gun types' figures and where they come from are in
[`formats/stats.md`](../formats/stats.md#guns).

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

A ship that is jumping fires nothing, though its guns still recharge. Every shot that does go off
is a bullet, below.

## Shots

A gun that fires makes a shot: `bullet_fire` (`0x0047C5F0`) takes the first free of the 200 records
at `0x00563148`, `0xC4` bytes each, and `bullet_place` (`0x0047BDB0`) fills it in. The shot leaves
the muzzle node where the step is taking it, flying along that node's nose at the gun type's speed,
and lives for the type's ticks, which is what gives the gun its range. A ship aiming blind aims at
its target instead of its nose, and gun type 12 scatters.

A few gun types have rules of their own. Two Turret Flak shots in five are Turret Lasers shots
instead (`bullet_fire`), and a Turret Flak shot lives a random share of its life, from a fifth of
it to all of it, and scatters up to 0.06 radians either way about each axis. The two Huge Guns reach
1200 and 3000 farther than the objects they strike stand, and their shots always go through the
shields, even where they are down.

The shot is then given the objects it may reach: each object whose radius, widened by how far it
could move meanwhile, its path comes within over its whole life, up to 20 of them. An object whose
components are listed is listed component by component instead. Nothing else is ever tested, so a
ship that flies into a shot's path after it was fired is not hit.

`bullets_move` (`0x0047A4E0`) moves every shot on by its velocity each simulation step, after the
objects move. Once a frame `bullets_frame` (`0x0047A510`) draws them, tests them and lets the spent
ones go.

`bullet_hit` (`0x00479B40`) tests what the shot crossed between its last place and its place now
against the objects it was given, and drops any it has flown past. An object is struck where the
segment first crosses the sphere of its radius:

- With a shield up in that quadrant the shot spends itself there: `object_damage` takes the gun
  type's first damage, and the share that passes through to the armour is its second over its
  first. For the player's ship the [shield reserves](controls.md#the-shield-balance) take the hit
  first.
- With the shield down the shot reaches the hull (`bullet_hull_hit`, `0x00479940`): the first of
  the object's part nodes whose box the segment crosses decides that it hit, and the quadrant's
  armour takes the type's second damage.
- A ship with its spectral shields on takes nothing at all. The gun type they are tuned to is
  handed to the check and ignored, so every shot is turned.

Either way the shot is spent and the frame that follows lets it go.

### How a shot is drawn

`guns_init` (`0x00478990`) builds the meshes the shots are drawn with once at start-up, twice over:
a set for the player's side and one for the rest, the same but for the Turret Lasers' rings. Most
are bolts: two quads crossed along the flight from the muzzle on, one upright and one flat, and far
off the upright one alone, on the texture `gunflare\lasers` added to what stands behind them. Eight
builders make them, differing only in the bolt's size, how far it is drawn, and the rings the
Turret Lasers' bolt has across it.

`bullet_build` (`0x0047D9A0`) gives each new shot up to eight pieces by its gun type: mesh objects,
sprite sets, lights, and bare frames the rest hang off. A mesh takes its own texture coordinates:
its gun type's span across the texture (`0x00500FB0`, `0x00500FEC`, 32 texels out of 256 for most
types), and the top half of it for any side but hostile, the bottom half for hostile, which is what
gives a friendly shot and an enemy's their different colours. The Pulse Cannon's and the Collapser
Guns' flares have a texture for the player's side and one for the rest. Each frame `bullets_frame`
does its type's own work on the pieces, then places them between the shot's last two places.

| Gun type | Drawn with |
|---|---|
| Laser Cannon | A bolt 60 across and 1200 long |
| Pulse Cannon | A flare, and a smaller one that wheels round it from a random start |
| Messon Blaster | Three thin bolts of different lengths, each at a random turn about the flight |
| Proton Cannon | A bolt 100 across and 1400 long that fades, to blue for a friendly shot |
| Gattling Lasers | Three Laser Cannon bolts about the flight, spinning |
| Tachyon Cannon | A star of three blades and a square ahead of it, spinning and fading |
| Neutron Particle Gun | A bolt 160 across and 1500 long, dim, turned at random each frame |
| Collapser Guns | Two flares either side of the flight, spinning and fading |
| Gattling Plasma Cannon | Four bolts of different lengths at random about the flight |
| Vulcan Battery | Four short bolts in two pairs that wheel about the flight in opposite ways |
| Nova Cannon | A bolt 360 across and 10000 long |
| Turret Flak | The first part of the shell model, `shell.shp` |
| Turret Lasers | A bolt 400 across and 2400 long, with two diamonds across it |
| Allied and Coalition Huge Guns | Three squares crossed in the three planes, tumbling and fading, a glow, a light of their own and a trail of particles |

The Nova Cannon's bolt is turned an eighth of a turn about the flight as it is built, and then
given the muzzle's turn in place of it, so it is drawn unturned.

On a hardware renderer (`sr + 0x1AC`) a shot also casts a point light from where it is drawn: blue
(0, 0.5, 1), or orange (1, 0.5, 0) for a hostile ship's shot unless the player fired it, reaching
1000 at full strength. Only the latest two of the player's shots cast one (`0x0056317C`), and the
latest two of everyone else's (`0x00563168`): a new shot's light puts out the light of the oldest
of its two. A shot flies past that reach within a step, so its light shows on the hull that fired
it for the frames just after it leaves the muzzle.

## The port

[`guns.zig`](../../src/engine/game/guns.zig) holds the fitting (`fit`), the groups (`buildGroups`),
the trigger (`fire`), the step (`step`), the shots (`shoot`, `moveBullets`, `bulletsFrame`) and how
they are drawn (`Looks`, `dress`, `animate`, `drawBullets`). The shapes come from one comptime
table of recipes, which stands for the game's eleven shape builders and the generators they call.
The port builds each shape once, and the Turret Lasers' two sets apart, since that is all the
game's two sets differ in. `simulationStep` runs the step and moves the shots;
`missionFrame` runs their frame pass; `drawFrame` adds them to the scene after the objects; and
`playerControls` pulls the trigger from FIRE LASERS. `gun_stats` and the shots in flight live in
`create.Objects`, and the executable's own half of each gun record is
[`guns/stats.zig`](../../src/engine/game/guns/stats.zig), which `make gun-tables` derives from the
payload.

Not ported: the Huge Guns' trails of particles, and the sparks and sounds an impact makes
([#41](https://github.com/vdmkenny/openreliant/issues/41),
[#47](https://github.com/vdmkenny/openreliant/issues/47)); the muzzle flashes
([#63](https://github.com/vdmkenny/openreliant/issues/63)); the parts of an object whose components
are listed, so shots pass through a capital ship
([#153](https://github.com/vdmkenny/openreliant/issues/153)); the Nova Cannon's charge
([#150](https://github.com/vdmkenny/openreliant/issues/150)); turrets, their aiming and the guns
they carry ([#71](https://github.com/vdmkenny/openreliant/issues/71)); and the gunnery keys that
choose a group or fire them all ([#92](https://github.com/vdmkenny/openreliant/issues/92)).
