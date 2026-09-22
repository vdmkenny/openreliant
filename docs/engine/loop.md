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
any display rate. `--no-smooth-motion` and `--original` move it on with the ticks, as the original
does.

Ported so far: the clocks, the pacing, and the keyboard, which the simulation step reads 25 times a
second as `read_keyboard` does rather than once a frame. Not yet: the joystick and the mouse the
step also reads, each object's own updates and `objects_update`, the countdown `game_tick` steps
once a second, and the sound streaming that shares `tick_timer`.

## Collisions

After moving the objects, `objects_update` lists each one's extent along X, its next position
plus its collision radius (`0x59C`) times the factor at `0x12C`, sorts the list, and hands each
pair whose extents overlap to `objects_collide` (`0x00466170`), up to ten passes. Two objects whose
spheres overlap are pushed apart along the line between them. **Unknown:** the rest of what
`objects_collide` does, which depends on a class in the objects' combat stats (`+0x28`).
