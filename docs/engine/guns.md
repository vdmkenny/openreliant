# Guns

How a ship is fitted with guns, how they are grouped, what a simulation step does with them, and
the shots they fire. The gun types' figures and where they come from are in
[`formats/stats.md`](../formats/stats.md#guns).

## The guns a model holds

`object_fit_guns` (`0x00479800`) walks the object's model when it is created, after its
[components](objects.md#components) are listed, once to count its guns and once to fill them in,
and allocates `gun_count` records of `0x60` bytes at `+0x134` and a word for each gun at
`+0x138`. `object_collect_guns` (`0x00479640`) walks the root's parts in order:

- A part of a turret's class (3, 9, 10 or 18, `part_is_turret`, `0x00479610`) whose
  [turret kind](../formats/shp.md#part-tag-0x01) is 1, 2 or 3 fits that [turret](#turrets), and
  what it carries is not walked.
- A part that shares its link id with a part of a turret's class, whatever that part's kind, is
  passed over with what it carries: its muzzles are the turret's. A turret's class with any other
  kind is passed over likewise, so the Boridin's Ion Cannon (class 18, kind 0) and the six guns
  mounted on it give no gun.
- Any other part gives a fixed gun for each of its
  [attachment points](../formats/shp.md#attachment-point-tag-0x09) of kind 3, a muzzle, of the gun
  type the attachment names at `+0x64`, and the guns of each model its attachments
  [mount](objects.md#what-an-attachment-point-holds), walked in turn. A muzzle that names type 0
  is a warning and fires type 1 instead.

**Unverified:** that a part's node holds what hangs from it in the order of its attachments, which
orders the guns of the models mounted on it among its own.

A gun's record holds its turret kind at `+0x00`, -1 once its turret is destroyed; the node it
fires from at `+0x04`; its type's record in `gun_stats` at `+0x08`; the tick its trigger is held
until at `+0x0C`; which side of its group it is at `+0x14`; and the tick it may next fire at
`+0x18`. A turret keeps more in the rest ([Turrets](#turrets)). The word at `+0x138` counts the
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
script's Fire command holds it for 20 or 100. With FULL GUNS every gun fires but an aimed turret's,
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
  `gun_sound_periods` of its type. A heard shot plays its gun type's 3D sound, which follows it
  ([Sound](sound.md#where-the-sounds-come-from)).

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
- With the shield down the shot reaches the hull (`bullet_hull_hit`, `0x00479940`): the last of
  the object's part nodes whose box the segment crosses decides that it hit, and the quadrant's
  armour takes the type's second damage. It throws [sparks](effects.md#sparks) from where it
  struck.
- A ship with its spectral shields on takes nothing at all. The gun type they are tuned to is
  handed to the check and ignored, so every shot is turned.

Either way the shot is spent and the frame that follows lets it go. A shot spent on a shield,
whatever became of it, makes the shield [flare](effects.md#shields) where it struck, unless the
ship is cloaked.

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
| Turret Flak | The first part of the shell model, `shell.shp`, which `guns_load_shell` (`0x00479140`) takes as each mission starts, once the objects are reset, counting its ship type, `0xB1`, as used |
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

**Improvement:** the port lets every shot cast its light (`ShotLights.every_shot`), so that
sustained fire lights the hulls it passes; `--original` and `--few-shot-lights` keep the game's two
([Renderer](../port/renderer.md#improvements)).

## Turrets

A turret part of kind 1, 2 or 3 makes a turret of its assembly: the shown parts of its model that
share its link id, each in the slot its part names at `+0xF8`. The turret's fit fills the rest of
the gun's record, marks the node of the part in slot 0, its base, with node flag `0x400`, and
keeps the model whose parts it turns, the object's own or one mounted on it, at `+0x34` (`+0x30`
for kind 2). The muzzle is the last of the assembly's; a turret's slot numbers index that model's
parts.

| Kind | Fit | What the record keeps |
|---|---|---|
| 1, aimed | `turret_fit_aimed` (`0x00479160`) | The parts in slots 0 to 4 at `+0x38` to `+0x48`, slot 1 the base's where no part names it; a target at `+0x18` (none, index -1, at `+0x1C`); the tick it next looks for one at `+0x4C`; the yaw and pitch still to turn at `+0x50` and `+0x54`; and, where a part of the assembly is one of the object's components and the object's model has [firing arcs](../formats/shp.md#firing-arc-tag-0x10), that component's arc at `+0x58`, the last found |
| 2, spinning | `turret_fit_spin` (`0x00479470`) | The parts in slots 0 to 4 at `+0x1C` to `+0x2C`: the barrels that spin, the gun, and two flaps |
| 3, missile | `turret_fit_missile` (`0x004793A0`) | The parts in slots 0 to 4 at `+0x38`: the base and the launcher; a target at `+0x18`; a timer at `+0x4C`; the missiles left at `+0x58`, none at first; its state at `+0x5C`. It has no muzzle and no gun type |

An aimed turret fires by its parts' `fire` tracks: each track's event of kind 0 fires a shot from
each muzzle of its part (`clip_event_muzzles`, `0x0047C7B0`, through `bullet_fire`), heard, of the
type the muzzle holds. Nothing holds such a shot back: not the ship's charge or rounds, the gun's
refire or condition, a jump, nor the guns being disabled.

### Each frame

`orders_update` runs `object_step_turrets` (`0x0047C950`) for each object after its orders, where
its guns are not disabled. Unless the object is exploding or its current order is Dock, each of its
guns runs its turret's step, by kind, from the table at `0x00500FA0`: nothing for a fixed gun and
for a destroyed turret's (-1).

**Aimed, `turret_aimed_step` (`0x0047D3D0`).** With a target it tracks it (below), then turns: its
base about its X axis by the yaw still to turn, its part in slot 1 and the one in slot 2 about their
Y by the pitch, each at most 0.02 a tick either way and within its limits (`node_turn`), each placed
by its new angles (`node_place`). A turret that drops its target as it tracks still turns by what it
had to turn the frame before. Every 100 to 199 ticks, where it has no target, it looks for one.

`turret_aimed_track` (`0x0047CFA0`): a target no longer valid (`order_target_valid`) is dropped.
Otherwise the turret leads it from its base with its gun (`ai_lead_aim_with_gun`), by a share of
the lead from 0.5 to 0.8 at random where the target's ECM is on, and works out the yaw and pitch
toward that (`turret_aim_angles`); where it can't lead it or aim there, it drops it. It keeps what
it still has to turn at `+0x50` and `+0x54`, each the short way round. Where the muzzle's forward
axis, from where the base stands, both at their next places, passes within twice the target's
radius of the aim point, ahead (`turret_in_line`, `0x0047CF10`), it holds its trigger for a tick and
plays the `fire` track, in the track's own mode at a speed of 2, on each of its parts playing
none. The tracks' events fire its muzzles.

`turret_aim_angles` (`0x0047CB10`) takes the aim point from the base as the model stands drawn, in
the frame of the model's root and then of the base's part: the yaw is `atan2(y, -z)`, and the pitch
`-atan2(x, -z')`, where `z'` is `z` turned by the yaw. They fail outside the base's yaw limits,
where they are not equal, and outside the pitching part's pitch limits, which have no such
exception; a Huge Gun aimed up to 20 degrees past a pitch limit aims at the limit. Where the turret
has a firing arc, the direction from the pitching part, in the root's frame, picks a row by its
angle about Y (32 to a turn) and a column by its angle from Y (16, wrapping twice round the half
turn), and four neighbouring bits must be set. Not ported: the Stalag's turrets fire anywhere while
the byte at `0x005883F8` is set. **Improvement:** the port turns radians, degrees and turns by the
exact values, where the game has 57.2958, 0.0174533, 3.14159 and 6.28319.

`turret_pick_target` (`0x0047D1F0`) takes the first object, in slot order, it can lead from its
base and aim at: of a type below `0x100`, not its own object, of neither its side nor the neutral
one; for a Huge Gun only a ship that lists components. An object that lists no components, or any
for a Huge Gun, is aimed at whole; any other only by a turret whose own object lists components and
is not a Kurgan, an Antanov, a Nanny or a Prowler, at the first of its components the turret can
reach. It doesn't ask whether the object is valid, so an exploding, cloaked or untargetable one
early in the slots is picked and dropped in turn. In a multiplayer game it passes over the player
who last hurt its object (`+0x10`), which the port leaves out.

The Predator's tail gun, a turret of one part, faces back, while its part's frame puts its aim of
no yaw and no pitch ahead: its muzzle never points at what it aims at, and it never fires.

**Spinning, `turret_spin_step` (`0x0047C9B0`).** Its barrels loop their `fire` track, from a
standstill at first. While its trigger is held, through the tick it is held until, they spin up by
0.1 a tick to at most 4, its gun's track loops at their speed and its flaps open at a speed of 4;
otherwise they spin down by 0.02 a tick, its gun's track stops at its start, and its flaps shut.
The gun fires by its trigger in the step, however fast it spins.

**Missile, `turret_missile_step` (`0x0047D560`).** By its state:

| State | What it does |
|---|---|
| 0, searching | Out of missiles, it goes to 2. Once its wait is over it picks the object nearest ahead of its launcher, within the Screamer's lock range and within 0.7 of the distance up or down, that is targetable, of another side, neutral or not, lists no components, and is neither a stand-in, exploding nor disabled, and goes to 1 |
| 1, tracking | Out of missiles, it goes to 2. A target no longer valid, beyond half the lock range or outside the cone up or down is dropped: back to 0, to look again in 20 ticks. Otherwise it turns its base 0.1 toward a target standing more than 0.1 of the distance to either side, a frame whatever the frame's length, and with the target within 0.7 ahead and its wait over, launches a Screamer at it one time in five ([`missile_launch_turret`](missiles.md#a-missile-turrets)), counting a missile spent when the roll lets it launch, and waits 2000 ticks, 1000 in mission 28 |
| 2 | After 100 ticks, plays its launcher's `reload` track forward at 4, and goes to 3 |
| 3 | After 800 ticks, plays it back at -4 from where it is, and goes to 4 |
| 4 | After 300 ticks, holds six missiles, and goes back to 0 |

It starts in state 0 with no missiles, so it reloads first. A target within the lock range but
beyond half of it is found and dropped in turn.

Groups leave out kinds 1 and 3, and FULL GUNS kind 1 ([The trigger](#the-trigger)). The game reads
through a missing part where an assembly lacks one, a slot of -1 or past 4 into the words beside
the slots, and a missile turret's missing muzzle under FULL GUNS; the port fits no gun for an
assembly that lacks its base, its muzzle or, for a missile turret, its launcher, passes over such a
slot, and passes over a gun with no muzzle at the trigger (**Fix**).

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

Not ported: the Huge Guns' trails of particles, the sparks an impact makes and a flak shell's
burst, which is only heard ([#41](https://github.com/vdmkenny/openreliant/issues/41)); the muzzle flashes
([#63](https://github.com/vdmkenny/openreliant/issues/63)); the parts of an object whose components
are listed, so shots pass through a capital ship
([#153](https://github.com/vdmkenny/openreliant/issues/153)); the Nova Cannon's charge
([#150](https://github.com/vdmkenny/openreliant/issues/150)); and the gunnery keys that
choose a group or fire them all ([#92](https://github.com/vdmkenny/openreliant/issues/92)).
