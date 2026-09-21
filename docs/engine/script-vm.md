# The script VM at run time

How the payload runs mission scripts: threads, the interpreter loop, calls, commands, the clock,
timers and events. The bytecode, and the triggers and parts that point into it, are described with
the [mission format](../formats/dte.md#script). The structures below are defined in
[`src/lancer/vm.zig`](../../src/lancer/vm.zig), and `make ghidra-annotate` applies them to the
Ghidra project together with the names used here.

## Threads

Every block runs on a thread, a `0xB8`-byte context from the pool at `vm_thread_pool`
(`0x537590`), which holds 32. `vm_thread_start` (`0x0045B8D0`) takes a block, points the thread's
instruction pointer past the block's length halfword and its block end at `block + length`, and
runs it at once unless told to defer it. It starts none while 31 are running.

| Offset | Size | Field |
|---|---|---|
| `0x00` | 4 | Stack pointer, saved while the thread is suspended |
| `0x04` | 4 | Block end, where the block's constants start; saved likewise |
| `0x08` | 4 | Frame pointer: the running part's first argument |
| `0x0C` | 4 | Clock value to resume at; zero when not waiting |
| `0x10` | 4 | Instruction pointer; null marks a free slot |
| `0x14` | 4 | Block end at which the script debugger's step-over stops |
| `0x18` | 20 | The values of the event that started the thread, which `push_local` reads |
| `0x2C` | 128 | The stack |
| `0xAC` | 1 | **Unknown.** `0xFF` when the thread starts |
| `0xAD` | 1 | Call depth |
| `0xAE` | 1 | **Unknown.** Zero when the thread starts; cleared when its trigger fires again |
| `0xAF` | 1 | Index of the trigger that started the thread; `0xFF` for none |
| `0xB0` | 4 | The last command's result, or the last part's return value, for `push_result` |
| `0xB4` | 4 | **Unknown.** Zero when the thread starts |

`vm_thread_run` (`0x0045BA30`) leaves a thread alone until the clock passes its wake time. Otherwise
it loads the thread's stack pointer and block end into `vm_stack_top` and `vm_block_end`, makes it
`vm_thread`, and calls the interpreter. The thread then has either finished, and its slot is freed,
or yielded, and its stack pointer and block end are saved for the next run.

## The interpreter

`vm_run` (`0x0045C980`) fetches an opcode, advances the instruction pointer past it, and calls the
opcode's handler from `vm_dispatch_table` (`0x4F6350`):

```c
uint __fastcall handler(byte **ip, uint **frame, uint previous);
```

`ip` points at the thread's instruction pointer and `frame` at its frame pointer. `previous` is what
the last handler returned, 1 for the first. A handler returns `previous` to carry on, and the loop
ends when one returns zero. The thread has then finished if a `return` ran at call depth zero,
which sets `vm_finished`; otherwise it has yielded, and resumes at its instruction pointer on its
next run.

The loop also serves a script debugger. With one attached, it can stop a thread at a byte that
section 10, one flag per script byte, marks, and report the position. **Unknown:** the debugger's
protocol.

## Calls

`call_part n` calls entry `n` of the part table. Above the arguments the caller pushed, it pushes a
call record, then points the frame at the first argument and enters the part's block:

| Offset | Field |
|---|---|
| `0x00` | Argument count |
| `0x04` | Return address |
| `0x08` | The caller's frame pointer |
| `0x0C` | The caller's block end |

`return` at a call depth above zero pops the part's return value into the thread's result, then the
record, then the arguments.

The part table and the command table share one `0x74`-byte record: the part's block or the command's
implementation at `0x00`, and the argument count in the byte at `0x04`. The command catalogue also
fills the name, parameters and description that follow; the loader fills only those two fields of a
part's entry.

## Commands

`command n` lowers the stack pointer by the command's argument count, so that it points at the
first argument, and calls the implementation:

```c
uint __fastcall command(byte **ip, uint *args);
```

The arguments are popped, and the result is written where the first was and stored as the thread's
result. It is also the handler's return value, so a zero result ends the loop: `Wait` sets the
thread's wake time to the clock plus its argument and returns zero, which suspends the thread until
then.

## The clock and timers

`vm_clock` (`0x538C9C`) counts the seconds of the mission: `vm_clock_start` (`0x00457C10`) zeroes it
and starts a periodic multimedia timer at one second, whose callback (`0x00458910`) increments it
unless the script debugger holds it or the word at `0x57E04C` is set.

`CreateTimer` fills one of the 16 timers at `vm_timer_table` (`0x537470`), first destroying any
timer with the same ID:

| Offset | Size | Field |
|---|---|---|
| `0x00` | 4 | The part to start; -1 for a free entry |
| `0x04` | 2 | Period, in seconds |
| `0x06` | 2 | Firings left; zero for no limit |
| `0x08` | 2 | Countdown to the next firing |
| `0x0A` | 2 | The timer's ID |
| `0x0C` | 4 | The clock value it last counted down at |

`vm_run_timers` (`0x0045D140`) counts each timer down once per clock value. At zero it starts the
part on a new thread for the scheduler, then reloads the countdown, or after the last firing
destroys the timer.

## Events

`trigger_match` (`0x0045CEA0`) handles an event on an object: its condition, its qualifier and the
values it carries. It walks the triggers in the object's slice of the trigger list, and takes each
one that is armed, has the event's condition and qualifier, links to a block and is not held back
by a veto:

1. It copies the event's values into a free thread's locals.
2. It checks the trigger's operands against the values: those the condition marks as checked, and
   of those, the ones whose low halfword is not `0xFFFF`. A failed check skips the trigger.
3. Unless a thread the trigger started is still running, it starts one on the trigger's block.
4. It disarms the trigger as its repeat mode says.

A condition with a slot also has its last event kept for each object, in the `0x28`-byte records at
`event_values`: ShotAt's five values, then Destroyed's. `push_event_value` reads them.

`condition_raise` (`0x00453210`) raises an event on a ship's flight group and on the squads that
hold the ship. For ShotAt, Destroyed, Cloaked and Decloaked it first calls the condition's
handlers: one before, one for each member of the flight group, and one for a verdict, which can veto
the event. A vetoed event fires only the triggers with the repeat mode the condition exempts.

### Conditions

`condition_descriptors` (`0x4F6698`) describes each condition in `0x1C` bytes:

| Offset | Size | Field |
|---|---|---|
| `0x00` | 4 | Name, as in `ShotAt` |
| `0x04` | 2 | **Unknown.** Zero, but `0x400` for the internal `ExplosionShip` |
| `0x06` | 2 | The kinds of object whose triggers can have the condition: bit 0 ships, 1 flight groups, 2 squads |
| `0x08` | 4 | The values an event carries, a list ending with a null label; null for none |
| `0x0C` | 1 | Slot in each object's kept events; `0xFF` for none |
| `0x0D` | 1 | The repeat mode exempt from a veto; `0xFF` for none |
| `0x10` | 12 | Handlers: before the members, per member, and the verdict |

Every trigger in the shipped missions belongs to a kind of object its condition allows.

An event value is 12 bytes: a label pointer, a kind mask of the kind the commands' parameters use, a
byte that is `0xFF` except `0x09` for ShotAt's weapon, and a byte saying whether a trigger's operand
is checked against the value. ShotAt carries the attacker, the shield damage, the hull damage, the
victim and the weapon; Destroyed the killer and the victim. The damage values set kind bit `0x1000`,
which no command parameter uses.

Events pass ships as the addresses of their records, and the matcher turns a trigger's operands
into the same form: the [mission format](../formats/dte.md#operands) gives the encoding.
`trigger_check_operand` (`0x0045D810`) compares a number operand of the proximity conditions as an
upper bound rather than for equality, but their distance value is not marked as checked, so the
matcher never compares it. The catalogue is also generated into
[`src/formats/vm_conditions.zig`](../../src/formats/vm_conditions.zig).
