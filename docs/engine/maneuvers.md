# Combat maneuvers

How a ship fights. The [order](orders.md) Fight (105) runs one maneuver after another against its
target: "loop the loop", "defend dodge1", "attack pursue" and seven more. Each maneuver is a script
in a small language of the developers' own, which the payload compiles line by line as it first runs
each line, and a table picks the next maneuver by where the two ships are.
[`aidefend.zig`](../../src/engine/game/aidefend.zig) and
[`aifight.zig`](../../src/engine/game/aifight.zig) define the structures,
[`aidefend/maneuvers.zig`](../../src/engine/game/aidefend/maneuvers.zig) holds the maneuvers, their
scripts and the handlers of each opcode, which `make maneuver-tables` transcribes from the
executable, and [`aidefend/script.zig`](../../src/engine/game/aidefend/script.zig) compiles the
scripts as the payload does. The build compiles every script, so a script the compiler cannot read
fails it. The names below are those `make ghidra-annotate` gives the Ghidra project; the source file
the asserts name is `aidefend.cpp`.

## The maneuvers

`maneuvers` (`0x4E1070`) holds a 16-byte `ManeuverRecord` for each maneuver:

| Offset | Size | Field |
|---|---|---|
| `0x00` | 1 | The inputs it may mirror: bit 0 yaw, bit 1 pitch, bit 2 roll. Each time it starts, a random choice among them is mirrored. |
| `0x04` | 4 | Its script |
| `0x08` | 4 | Its name |
| `0x0C` | 2 | The fewest ticks it runs |
| `0x0E` | 2 | The most |

A script is a list of 8-byte `ManeuverScriptLine` records ending with one without text: the line's
text, and a pointer to its compiled instruction, null until the line first runs. "loop the loop"
reads:

```
Cloak(on)
SetAfterburner(off)
SetPitch(1)
SetYaw(0)
SetRoll(0)
SetSpeed(0.5)
loop:
	Wait(1000)
	Goto loop
```

and "attack pursue":

```
Cloak(off)
SetAfterburner(off)
loop:
	If Goingtocrash
		Avoid(300)
	Endif
	Attack(25)
	Goto loop
```

## The language

Each line is one command: a word, then for some commands arguments in parentheses, separated by
commas. A word is letters, digits and `_ . : -`; spaces and tabs around words are skipped. Commands
compare without regard to case. A line whose first word ends in `:` is a label.

`maneuver_compile_line` (`0x00405010`) compiles a line into `maneuver_code` (`0x515DA4`) at
`maneuver_code_end`: a byte of opcode, then what the command needs. It reads arguments with
`script_read_arguments` (`0x00404F80`), four at most. Where a command takes a range, one argument
gives both ends. It stops with a fatal error on a command it does not know ("Syntax error %s"),
arguments that do not open with `(` or are not separated by commas ("Syntax error"), a `Goto` to a
label no line holds ("Invalid goto"), and an `If` or `Else` with no `Endif` ("no endif for if").

| Command | Opcode | Compiled |
|---|---|---|
| `SetYaw(a, b)`, `SetPitch`, `SetRoll`, `SetSpeed` | 0 to 3 | A range of numbers: 12 bytes |
| `Wait(a, b)` | 4 | A range of ticks: 6 bytes |
| `Goto label` | 5 | The label's line, found by comparing each whole line with the label and a colon: 2 bytes |
| `label:` | 6 | 1 byte |
| `SetAfterburner(on)`, `(off)` | 7 | Whether the argument is `on`: 2 bytes |
| `Runaway(a, b)` | 8 | A range of ticks |
| `Attack(a, b)` | 9 | A range of ticks |
| `Attackmassive()` | 10 | 6 bytes, no ticks written |
| `Outofactionsphere(a, b)` | 11 | A range of ticks |
| `Setmirror` | 12 | 1 byte |
| `If Goingtocrash` | 13 | The condition, 0 for `Goingtocrash`, and the line of the matching `Else` or `Endif`: 3 bytes. For any other condition the byte is left as it was. |
| `Else` | 14 | The line of the matching `Endif`: 2 bytes |
| `Endif` | 15 | 1 byte |
| `Avoid(a, b)` | 16 | A range of ticks |
| `Cloak(on)`, `(off)` | 17 | Whether the argument is `on`: 2 bytes |
| `AttackMediumFighter(a, b)` | 18 | A range of ticks |
| `NewAttackRun(true)`, `(false)` | 19 | Whether there is one argument and it is `true`: 2 bytes |
| `RunToShip()` | 20 | 6 bytes, no ticks written |
| `EndScript()` | 21 | 6 bytes, no ticks written |

## Running a maneuver

`maneuver_handlers` (`0x4E0CC0`) holds a start and a run routine for each opcode, either of which
may be null. `maneuver_run` (`0x004069B0`) runs the Fight order's maneuver for an update, keeping
the line it is on and whether that line waits in the order's state, a `FightState`:

1. While no line waits, it moves to the next line, compiles it if it has not been, and calls its
   opcode's start routine, which returns true for an instruction that waits.
2. It then calls the waiting line's run routine, which returns true while the instruction still
   waits.

So a script's commands run one after another in the same update until one waits, and a loop
without a waiting command in it would never return. Commands that wait keep a
timer in the state, `min + random * (max - min)` ticks after `frame_start`, which
`maneuver_start_timer` (`0x00405B20`) sets. What each does:

| Command | What it does |
|---|---|
| `SetYaw`, `SetPitch`, `SetRoll` | Sets the input to a random value in the range, times the pilot's `tier_c_values[0]`, negated when the maneuver mirrors that input. |
| `SetSpeed` | Sets the throttle to a random value in the range. |
| `Wait` | Waits its ticks. |
| `Goto`, `Else` | Go on after the line they hold (`maneuver_jump`, `0x00405B70`). |
| `If Goingtocrash` | Runs the lines after it when the ship is on course to hit its target, and otherwise goes on after its `Else` or `Endif`. Against a target without components, "on course" is what `0x00401980` finds over 100 updates with a margin of 5000, 3500 or 2000 units by the pilot's value 3 (0, 1 or 2), and never for other values; against one with components, being within 50 times the cruise speed plus both radii of the target's part. |
| `SetAfterburner(on)` | Keeps the afterburner lit through the maneuver, but only for a pilot whose `tier_c_values[0]` is 2, and only while a player's ship is within 50000 units. `off` puts it out. |
| `Cloak(on)` | Cloaks the ship after 500 ticks, if its model can cloak. `off` uncloaks it at once. |
| `Setmirror` | Picks at random which of the three inputs the `Set` commands mirror from here on, whatever the maneuver allows. |
| `Runaway` | For its ticks, flies at a point a million units away from the target. |
| `Outofactionsphere` | For its ticks, flies to the object at the action sphere's centre. |
| `Attack` | For its ticks, steers at its aim point (see [each update](#each-update)) with the pilot's `tier_c_values` as limit and ease, at full throttle. Within 12000 units of the target, both radii aside, the throttle is instead the aim point's velocity along the ship's heading over its cruise speed, which is a quarter of the target's speed that way. When the target is behind where the ship will be in 20 updates, a pilot whose value 3 is 2 lights the afterburner. The throttle stays at least 0.5. |
| `Attackmassive` | Steers at its aim point at full throttle until it is within 50 times its cruise speed, plus both radii, of the target's part. |
| `AttackMediumFighter` | For its ticks, flies at full throttle toward where the target will be, leading it by its velocity less a tenth of the ship's, over the time the ship needs to get there. Within 10000 units of a target that is not within 18 degrees of its nose, it flies straight on instead. |
| `Avoid` | For its ticks, with the target ahead, pitches hard at half throttle, one way or the other by whether the target is above or below; with the target behind, flies on at full throttle. |
| `NewAttackRun` | Picks a point on the target's part, then flies to one 50000 units out from it, or with `true` twice the target's radius for a target larger than 50000. It burns full throttle and afterburner while that point is ahead, half throttle while it is behind, and ends within 2000 units of it. `true` also clears the word at `0x620` of the ship. |
| `RunToShip` | Flies to the friendly ship chosen for it, and ends within 5000 units of it, its radius aside. |
| `EndScript` | Ends the maneuver: it sets the maneuver's end to the tick before, so Fight chooses another. |

The commands that fly to a point (`maneuver_steer_to_point`, `0x00405C60`) go at full throttle
and steer with [`ai_steer`](orders.md#steering), flags `0xB`, unless there is something to avoid,
when they steer with flags `0x3`. Once the point is within 26 degrees of the nose, the ship pitches
at full rate until it is 45 degrees off, then steers at it again, so it weaves.

## Choosing a maneuver

`fight_choose_maneuver` (`0x0040A3A0`) chooses the next maneuver into the order's data, a
`FightData`, which Fight starts on its next update. It runs when Fight starts and whenever the
maneuver's time is up.

- Against a target with components: "attack massive object", for 20000 ticks.
- For a ship with components: "attack medium fighter", for 10000 ticks.
- For a ship outside the action sphere, 220000 units around `action_sphere_center` (`0x515D78`),
  whose target is not a player's and is either within 200000 units of it or outside the sphere as
  well, with no player's ship within 100000 units: "out of action sphere", for 500 ticks.
- Otherwise, `fight_choose_by_position` (`0x0040A000`):
  - Farther from the target than `pursue_distances` (`0x4E193C`), 300000, 200000 or 100000 units by
    the pilot's value 3, times the target's speed over its top speed but at least a quarter:
    "attack pursue".
  - With the target behind the ship, one time in ten, "run to ship" toward the nearest friendly ship with
    components and combat class 2 or 3, unless the ship is already within 50000 units of one, its
    radius aside (`fight_find_ship_to_run_to`, `0x00409F00`).
  - Within 10000 units of the target: "defend runaway".
  - Otherwise a random maneuver from `maneuver_choices` (`0x4E1918`), by where the target is from
    the ship's nose (ahead within 60 degrees, behind more than 120 degrees off it, or abeam
    between), then where the ship is from the target's (ahead within 60 degrees, behind more than
    96 degrees off it, or abeam between): "attack pursue" when the ship is behind the target, or
    when the target is ahead and the ship abeam of it, and otherwise one of "defend runaway", the
    three dodges and "loop the loop".

Its length is what the choice gives, or a random number of ticks in the maneuver's range.

When Fight starts the chosen maneuver it clears its state, puts the script before its first line,
picks the inputs to mirror, and sets the tick it ends at.

## Each update

Fight's update (`order_fight`, `0x0040A5E0`) pops the order when its target is no longer valid,
chooses a new maneuver when the last one's time is up and starts one chosen, and then:

1. **Aims** (`fight_aim`, `0x00409BE0`). Every pilot's `tier_c_count` ticks it aims at the target,
   or at the target's part, with a quarter of the target's velocity as the aim point's velocity
   and some random spread, unless `0x00401280` answers yes. Each update the aim point moves by its
   velocity times `frame_duration`, and `0x004096B0` fires at it.
2. **Calls for help** (`fight_call_for_help`, `0x00409D10`). When the target is the player, the
   player hit the ship last, its `recent_damage` has reached 1.2 times its armor class, and one of
   its armor values is below 3 times its armor class, about half what it starts with, it zeroes
   `recent_damage` and pushes Fight,
   aimed at the player, on the nearest ship of its side with combat class 1 whose order is Fight
   or Mill, a Fight first.
3. **Cloaks** (`fight_update_cloak`, `0x00409EC0`) as the maneuver's `Cloak` asked.
4. Runs the maneuver.

**Unknown:** what `0x00401280` and `0x004096B0` do exactly, and what the pilot's `tier_c_values`,
`tier_c_count` and value 3 are called in the game.
