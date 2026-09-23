# The game loop

How the payload paces a mission: a timer ticks 100 times a second, the loop runs one game tick for
each tick of the timer, and objects move on every fourth tick. The names below are those
`make ghidra-annotate` gives the Ghidra project.

## Ticks

`tick_timer` (`0x004827C0`) runs 100 times a second, on a periodic multimedia timer that
`timer_start` (`0x004A70F0`) sets up. Unless the game is paused, which the word `paused`
(`0x57E04C`) says, it advances `game_ticks` (`0x565064`) and the play time: ticks, seconds,
minutes and hours at `0x565070` to `0x565076`. The play time rolls a second over after 101 ticks. `game_tick` also counts the ticks it runs in
`mission_ticks` (`0x587CC4`), which stops while the game is paused.
The [script clock](script-vm.md#the-clock-and-timers) runs on a timer of its own, once a second,
and stops for the pause too.

## The loop

`mission_run` (`0x00494040`) zeroes the clocks, then loops. Each pass runs `game_tick`
(`0x00477850`) once for each tick of `game_ticks` since the previous pass, then, unless the game is
paused, the frame's work, `mission_frame` (`0x004924B0`). So the simulation advances at a fixed
rate whatever the frame rate. The frame's work runs every object's [orders](orders.md), through
`orders_update`, and flushes the script's events, once a frame. It begins with `frame_begin`
(`0x00491E00`), which sets `frame_duration` (`0x588330`) to the ticks since `frame_start`
(`0x5883B0`) and `frame_start` to `mission_ticks`; code that runs once a frame measures time with
these.

`game_tick` runs `simulation_step` (`0x004774D0`) unless the game is paused. `simulation_step`
does its work on every fourth call, so 25 times a second: each object's own updates, then
`objects_update` (`0x00468FA0`), which moves every object with `object_move` and handles
collisions. The rates and speeds of the [flight model](objects.md#motion) are therefore per
twenty-fifth of a second, and afterburner fuel, which burns 4 units an update from 100 per second
of the ship's stat, lasts that many seconds. Each frame draws what moves between its last two
places, as far into the step as the ticks since it have gone
([Drawing between steps](objects.md#drawing-between-steps)), so motion moves on a hundred times a
second.

## Porting

[`game/main.zig`](../../src/engine/game/main.zig) holds the clocks as `Clock`, with `frameBegin`,
`frameReset`, and `nextTick` and `runTicks` for `mission_run`'s pacing, one game tick for each tick
of the timer. The functions that tick them live with their files: `hog_snd.tickTimer` for what
`tick_timer` does to them, and `gameobj.gameTick` and `gameobj.simulationStep`.

**Improvement:** the port has no periodic timer. `advanceTo` takes the platform's monotonic count of
hundredths of a second, and the ticks come from the difference between two counts rather than from
the length of a frame, so the clocks keep to that count however the frames fall and nothing
accumulates. The frame rate is therefore decoupled from the tick rate in both directions: a frame
shorter than a hundredth runs no tick, a frame that spans several runs all of them at once, and a
second of play is 100 ticks and 25 simulation steps whatever the rate the engine draws at.

**Improvement:** `objects.stepFraction` also counts the time past the last tick, which `advanceToFine`
keeps from a finer count, so that what moves moves on every frame rather than every tick, evenly at
any display rate. The effects, which move by a velocity a tick, are drawn that far past the tick
as well (`objects.pastTick`, and [Effects](effects.md#drawn-between-the-ticks)).
`--no-smooth-motion` and `--original` move it on with the ticks, as the original does.

The simulation step walks the objects ([The object array](objects.md#the-object-array)): each has
its orientation orthonormalized in its turn, then its node update, its shields' recharge and its
[guns' step](guns.md#the-step), and then the player's controls fly the player's ship, while its top order is Player
Control, `objects_update` moves every object and the [shots in flight](guns.md#shots) fly on. Each
frame, `mission_frame` frames each object between its last two steps, tests the shots against what
they may have struck, and draws it all after the camera's frame.

Ported so far: the clocks, the pacing, the keyboard and the joystick, which the simulation step
reads 25 times a second as `read_keyboard` and `read_joystick` do rather than once a frame, the
step's work on the objects, and each frame's orders and framing (`main.missionFrame`), which is
what a mission and the sandbox both run.
Not yet: the mouse, the missiles the step moves after `objects_update`, the countdown `game_tick`
steps once a second, and the sound streaming that shares `tick_timer`.

## Collisions

After moving the objects, `objects_update` lists each one that collides: its slot, its collision
radius (`0x59C`) times `visibility` (`0x12C`), and how far its sphere reaches along X. It sorts the
list by that reach, the farthest first, and walks each object against those after it while their
spheres still reach back to it, which is every object that can be near it. A pair where either
names the other in `passes_through` (`0x618`) is left alone, as is one whose spheres do not
overlap; the rest go to `objects_collide` (`0x00466170`). A pass that moves anything is followed by
another, up to ten; on the tenth the game puts "collision" on the screen.

`objects_collide` decides by the two objects' classes (`ShipCombat.class`, `+0x28`) and by whether
they list components:

| The pair | What happens |
|---|---|
| Two of one type, where either is a torpedo | Nothing |
| A torpedo that is already going off | Nothing |
| Either lists components, but not both, and neither is the limpet pod (`0xBC`) | The ship is tested against the other's collision tree, up to nine times over (`0x00465C50`) |
| Both list components | Nothing |
| Two torpedoes, two pieces of debris, or two satellites (`0x71`) | Nothing |
| Either is a mine, against a fighter | The mine goes off |
| A torpedo against anything else | It goes off |
| Anything else | The impact's damage, then both move again and are set apart |

Before that, the two shove each other (`0x00464E80`). The point their spheres touch at moves with
each of them between this step and the next, so a turning ship strikes with its wingtip's speed;
the impulse comes from how fast the two points close, over each object's mass and its
`angular_response`, doubled so the bounce keeps the speed they met at, and both take it through
`object_knock`, equal and opposite. The move that follows applies those knocks. An object held to
another, and the Ripper with something in its grip, take no shove.

Two spheres meet on the line between their centres, so a shove between them has no lever and neither
ship is set spinning. A hull's own faces do give one ([#143](https://github.com/vdmkenny/openreliant/issues/143)).

The pair is then set apart along that line: each is placed at 1.1 times its own radius from the
point midway between the two, so the step that follows does not find them overlapping again.

A ship that meets an object listing components is tested against that object's collision tree
instead ([Models](../formats/shp.md#tree-node-tag-0x07)): each part's boxes are descended to the
leaves, and the faces of a leaf the ship's sphere reaches give the nearest point. Those are the
file's own faces, which the leaf lists by index, not the merged polygons the renderer draws. The ship is then
shoved at its own centre and the hull at that point, so the hull turns about the hit and the ship
does not.

An impact also does damage, from the impulse the shove handed the pair: a fifth of it over the
lighter of the two masses, halved, on the quadrant each was struck in (`0x00465CA0`). The shield
there takes it first, and what passes through wears the armour, which sets the armour's conditions
again. A collision does not count toward what a ship has taken lately, so it never sends one after
its attacker; a shot does.

Ported so far: the sweep, the pairs it passes over, the shove, setting two objects apart, the hull
test and the damage ([`collision.zig`](../../src/engine/game/collision.zig)). A collision does no damage to a component: only a torpedo's hit and a ship destroying itself
against a hull reach `component_damage`. Not yet: the mine's explosion
([#41](https://github.com/vdmkenny/openreliant/issues/41)). The difficulty scales the damage
([Destruction](objects.md#destruction)).
