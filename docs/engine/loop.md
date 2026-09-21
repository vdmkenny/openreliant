# The game loop

How the payload paces a mission: a timer ticks 100 times a second, the loop runs one game tick for
each tick of the timer, and objects move on every fourth tick. The names below are those
`make ghidra-annotate` gives the Ghidra project.

## Ticks

`tick_timer` (`0x004827C0`) runs 100 times a second, on a periodic multimedia timer that
`timer_start` (`0x004A70F0`) sets up. Unless the game is paused, which the word `paused`
(`0x57E04C`) says, it advances `game_ticks` (`0x565064`) and the play time: ticks, seconds,
minutes and hours at `0x565070` to `0x565076`. The play time rolls a second over after 101 ticks.
The [script clock](script-vm.md#the-clock-and-timers) runs on a timer of its own, once a second,
and stops for the pause too.

## The loop

`mission_run` (`0x00494040`) zeroes the clocks, then loops. Each pass runs the frame's other work,
then `game_tick` (`0x00477850`) once for each tick of `game_ticks` since the previous pass. So the
game state advances at a fixed rate whatever the frame rate.

`game_tick` runs `simulation_step` (`0x004774D0`) unless the game is paused. `simulation_step`
does its work on every fourth call, so 25 times a second: each object's own updates, then
`objects_update` (`0x00468FA0`), which moves every object with `object_move` and handles
collisions. The rates and speeds of the [flight model](objects.md#motion) are therefore per
twenty-fifth of a second, and afterburner fuel, which burns 4 units an update from 100 per second
of the ship's stat, lasts that many seconds.

## Collisions

After moving the objects, `objects_update` lists each one's extent along X, its next position
plus its collision radius (`0x59C`) times the factor at `0x12C`, sorts the list, and hands each
pair whose extents overlap to `objects_collide` (`0x00466170`), up to ten passes. Two objects whose
spheres overlap are pushed apart along the line between them. **Unknown:** the rest of what
`objects_collide` does, which depends on a class in the objects' combat stats (`+0x28`).
