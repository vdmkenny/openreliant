# `.DTE` missions

The 44 missions, each one a complete description of what the engine places, scripts and watches
for. A mission names its ships, seeds its globals, arms its triggers and carries the bytecode they
run.

```bash
sltool dte info <mission>        # ships, triggers, globals, script size
sltool dte sections <mission>    # the 27-section directory
sltool dte ships <mission>       # every placed ship and nav point
sltool dte triggers <mission>    # the scripted triggers
sltool dte strings <mission>     # the string pool
make check-missions              # parse all 44
```

## Container

A mission inside a `.HOG` is RefPack compressed. A mission sitting loose in `missions\` is stored
expanded, and the engine decides by reading the member's first two bytes, so an uncompressed member
is legal anywhere. The two loose missions a retail install carries, `mission18.dte` and
`mission25.dte`, begin `08 33` where their archive copies begin `10 FB`.

`sltool hog` expands members as it extracts, so `sltool dte` always sees the expanded image.

## Directory

The image opens with **27 entries of 8 bytes**:

| Offset | Type | Field |
|---|---|---|
| 0 | u16 | Records in use |
| 2 | u8 | Unused |
| 3 | u8 | Which of the section's fields the loader turns into live pointers |
| 4 | u32 | Offset of the section, or `0xFFFF` when the mission does not use it |

The layout is **fixed capacity**: a section's offset is the same in every mission built from the
same template, and the count says how much of the reserved room is filled. 36 of the 44 missions
are byte-for-byte the same size, 850,919 bytes, for that reason.

| # | Section | Stride | Contents |
|---|---|---|---|
| 0 | strings | - | The string pool |
| 1 | operands_a | 2 | Operand resolution |
| 2 | globals | `0x0C` | Named values the script reads and writes |
| 3 | ships | `0x4C` | Every placed ship, station and nav point |
| 4 | objectives | `0x14` | |
| 5 | triggers | `0x30` | |
| 6 | script | - | Bytecode; the VM's instruction pointer is an offset into it |
| 7 | ship_triggers | 8 | Per-ship index into the trigger list |
| 8 | objects | `0x1C` | |
| 10 | script_flags | 1 | One flag per bytecode byte, marking where the VM may yield |
| 13 | squads | `0x0C` | |
| 15 | nav_geometry | `0x10` | |
| 16 | sub_objects | `0x44` | |
| 22 | operands_b | 2 | |

Sections 17 to 21 are empty in all 44 missions.

## String pool

A run of NUL-terminated names. **A name is referenced by its byte offset into the pool, not by an
index**, which is what makes `u16` enough: the pool is reserved 65,535 bytes and `mission1` fills
17,207 of them with 9,088 strings.

Getting this wrong is quiet rather than loud, because sequential indexing still lands on real
strings: it resolved 17% of ship names to something non-empty. Byte offsets resolve **8,265 of
8,265**, across all 44 missions, and produce the names the game shows: `Player_Ship`,
`(A1)Naginata`, `(WL)Viper's Coyote`, `The Reliant`, `Convoy Nav Point`.

## Ship records

Stride `0x4C`. One per placed object, ships and nav points alike.

| Offset | Type | Field |
|---|---|---|
| `0x00` | u32 | Flight group |
| `0x04` | u16 | Name, as a byte offset into the string pool |
| `0x08` | f32 x3 | Position, mirrored from `0x1C` when the mission loads |
| `0x15` | u8 | Side. 255 marks the player's own record |
| `0x17` | u8 | Flags; bit 0 disables the record |
| `0x18` | u16 | Role. Ordinary ships stay below `0x100`, while nav points and markers use 999 and `0x3E3` to `0x3E8`, so reading this as a byte truncates about two records in five |
| `0x1C` | f32 x3 | Position as authored |
| `0x2E`, `0x3A`, `0x4A` | i16 | Yaw, pitch, roll, in whole degrees |
| `0x30` | u32 | Live object handle, `0xFFFFFFFF` until the mission arms |

The three angles are at non-contiguous offsets, each four bytes ahead of its runtime mirror at
`0x2C`, `0x38` and `0x48`. All 8,265 records across the corpus hold angles within [-360, 360], and
a flight group's wingmen share a heading: `mission1` opens with the player and every escort at yaw
90.

Positions are large, on the order of 10^7, and are absolute rather than relative to anything in the
mission.

## Triggers

Stride `0x30`. A trigger watches a condition on a subject and spawns a script action.

| Offset | Field |
|---|---|
| `0x00` | Subject ship or flight group |
| `0x01` | Repeat mode |
| `0x02` | Linked action or script index, `0xFFFF` for none |
| `0x14` | Armed flag |
| `0x15` | Condition |
| `0x16` | Action, which spawns the script thread |
| `0x19` | Repeat counter |
| `0x1C` | Operands, four bytes each |

### Conditions

33 scriptable conditions, `0x00` to `0x20`. The engine's own name table lists them in order, and
the payload carries all 33 strings. `0xFF` means no condition.

Of the 2,446 trigger records in the shipped missions, **278 carry a condition and 2,168 carry
`0xFF`**, so most slots are reserved rather than used. Every value seen falls inside the scriptable
range or is the `0xFF` sentinel, which is itself evidence the field is read correctly: a
misidentified byte would scatter across the whole range.

| Condition | Uses |
|---|---|
| `shot_at` | 207 |
| `launched` | 14 |
| `destroyed`, `camera_reached` | 11 each |
| `ship_reached` | 6 |
| `proximity_close`, `object_scooped` | 5 each |
| `proximity_general` | 4 |
| the remaining ten | 1 or 2 each |

The long tail is concentrated: `mission10` carries eight consecutive triggers on one subject whose
conditions step through `0x06` to `0x0D` in order, which reads as an enumeration rather than
gameplay.

**Unknown:** repeat mode `1`, which occurs 612 times. Modes `0` (one-shot, 1,833 uses) and `2`
(counted, 1 use) are documented; `1` is not.

## Script bytecode

Section 6 holds one bytecode stream for the whole mission; `mission1` carries 3,776 bytes of it.
The interpreter is a plain dispatch loop, read from the payload:

```
handler = table[code[ip]]      // a 256-entry table of function pointers
ip += 1
continue while handler() != 0
```

Section 10 is a flag array indexed by the same instruction pointer, marking the bytes at which the
VM may suspend and resume on a later frame, which is how a long script runs without blocking the
frame.

**The instruction set is opcodes `0x02` to `0x55`, minus `0x08` to `0x13` and `0x50`: 71 in all.**
The handler table holds 86 entries; the 15 gaps are null. Past entry `0x55` the data is a different
structure, which holds a few values that look like code addresses but are not handlers.

Five opcodes share a handler with another, so the two are one operation: `0x24` with `0x23`, `0x2B`
with `0x2A`, `0x25` with `0x43`, `0x32` with `0x2E`, and `0x55` with `0x47`.

### Deriving the instruction set

The opcode set, each instruction's size and where execution goes next are all read out of the
payload rather than guessed from the mission files.

The dispatcher reads an opcode byte at `P`, sets the instruction pointer to `P + 1`, and calls the
handler with `ECX` pointing at the cell that holds it. Whatever the handler leaves in that cell is
where execution resumes, so the shape of an instruction is exactly what its handler does to `[ECX]`.

`src/tools/vmgen` does this mechanically: it reads the dispatch table out of the binary, parses
each handler out of Ghidra's exported disassembly, and symbolically executes every path through it,
tracking the instruction pointer. The paths must agree, so a handler it cannot pin down is reported
rather than guessed at. The result is [`src/formats/vm_opcodes.zig`](../../src/formats/vm_opcodes.zig),
regenerated with `make vm-opcodes` after `make ghidra-export-game`.

`ghidra/scripts/DefineVmHandlers.java` defines a function at every table entry first, because
nothing calls the handlers directly and auto-analysis leaves them undefined.

Four shapes come out of it:

| Form | Opcodes | Next instruction pointer |
|---|---|---|
| `sequential` | 63 | After the operands |
| `branch` | `0x23`, `0x24`, `0x42` | The operands are a displacement |
| `inline_data` | `0x2A`, `0x2B` | After the run the operand byte measures |
| `transfer` | `0x22`, `0x25`, `0x43`, `0x4A`, `0x51` | Not statically known |

The analysis also records whether any path through a handler leaves the instruction pointer just
past the operands. That settles the sequential and branch opcodes, and `0x42` jump is the one
branch without such a path. It cannot settle the five transfers, which the decoder classifies by
name instead, and a compile-time check refuses any transfer in the table that it has not
classified:

| Transfer | Opcodes | Next |
|---|---|---|
| Call | `0x22` call_part, `0x4A` call_part_b | Into a part, then back to the following instruction |
| Return | `0x43` return, `0x25` | Out of the part, or out of the thread |
| Random branch | `0x51` | One of its arms |

For a call, the only sequential path the analysis sees is the one taken when the part is missing;
the return that brings execution back runs in another handler. For `return`, the path that leaves
the instruction pointer alone is the one that ends the thread, which the handler signals through its
return value rather than through the instruction pointer.

Operand counts: 41 opcodes take none, 24 take one byte, 5 take two and `0x4B` takes three.

The three that are not a fixed size each carry their own length, so an instruction's size is always
known without tracking any state:

- **`0x2A` speech** (and `0x2B`) reads its operand byte as the length of the whole operand run,
  itself included, then pushes a pointer to the bytes after it and steps over them. What follows is
  a NUL-terminated file name: a `.wav` of speech, or a `.ut` cutscene. `mission81` opens by cueing
  `new_sim02.wav` this way.
- **`0x51` random_branch** is a count byte, a big-endian default target, then that many four-byte
  arms of target and threshold. It picks an arm by rolling against the thresholds. Its size is
  `3 + 4n`, the one encoding read by hand rather than derived, because its length depends on a byte
  the instruction-pointer analysis cannot follow.
- **`0x22` call_part** is a fixed three bytes, but transfers control.

### Control flow

- **`0x22` call_part** reads a one-byte part index, looks the part up in a table of stride `0x74`
  whose entry holds the block pointer at `+0` and the argument count at `+4`, pushes the argument
  count, the return address, the caller's frame base and the caller's block end, sets the frame
  base to `stack - (4n + 16)`, and enters the block. It is a subroutine call, which is why blocks
  are reached by address rather than laid end to end.
- **`0x43` return** (and `0x25`) unwinds all of that. When the call depth is already zero the
  thread is finished instead.
- **`0x4D` spawn_part** reads a part index, moves the part's arguments off this thread's stack
  onto a fresh thread's, and starts that thread on the part's block. The spawning thread carries
  on, which is why the analysis finds it sequential.
- **`0x4A` call_part_b** and **`0x4E` spawn_part_b** do the same through the second part table,
  the one serving section 18.
- **`0x23` branch_if_zero** (and `0x24`) pops a value and branches when it is zero. **`0x42` jump**
  branches unconditionally. Both take a **big-endian** 16-bit displacement, counted from the
  displacement's own position rather than from the end of the instruction. This is the one place in
  the format that is not little-endian.

`0x21` command reads a one-byte index into the Executor catalogue, also stride `0x74`, whose entry
carries the command's argument count at `+4` and its implementation pointer at `+0`.

### Parts

Section 8 is not a list of objects: it holds one 28-byte descriptor per **part**, a named script
routine, and the loader expands it into the 256-entry table of `0x74`-byte records that `call_part`
and `spawn_part` index. Section 17 does the same for section 18, a second bytecode section that is
empty in every shipped mission.

| Offset | Size | Field |
|---|---|---|
| `0x00` | 2 | Name, as a byte offset into the string pool |
| `0x0A` | 2 | Start of the part, in halfwords; `0xFFFF` for a part with no block |
| `0x0D` | 1 | Arguments, which reserve `4n + 16` bytes of the callee's frame |
| `0x10` | 2 | Extent of the part, in halfwords |
| `0x19` | 1 | Read by the loader and passed on to the routine that fills the runtime record |

The loader computes `record.block = script + offset * 2` and `record.arguments = arguments`, which
is where the halfword unit is fixed. **Section 6's count is in halfwords too**, so the script is
`count * 2` bytes; the parts tile it, each one's `offset + length` being the next one's `offset`.

Missions ship with their authors' own names for these. `mission1` has 32:

```
  #  offset  bytes  args  block  name
  0    1740    192     0    168  (F)launchfunction
  1    1932    160     0    144  (F)Jumping to CONVOY
  2    2092    252     0    220  (F)Arrival at CONVOY
  3    2344    280     0    256  (F)Nav 2 Comms and CAM
  ...
 31    7524     28     0     20  <F>Objective window
```

Nearly every part takes no arguments: across the 44 missions, 1,625 take none, four take two and
one takes one.

### Blocks

A block is a `u16` length followed by instructions. **The length counts its own two bytes**: the
engine starts a thread with its instruction pointer at `block + 2` and its limit at
`block + length`, both of which `call_part` and the thread creator compute the same way.

A part's extent covers its entry block and anything that block branches to, so it is at least the
entry block's own length. The instructions end with a `return`, after which up to three bytes pad
the block out to a four-byte boundary.

Disassembly follows control flow from the entry rather than sweeping linearly, because of the three
opcodes that never fall through:

```
sltool dte parts <mission>     # the named routines
sltool dte script <mission>    # disassemble them
```

**Every part in all 44 missions disassembles completely**, bar 128 bytes noted below. The block at
the very start of `mission1`'s script, the one its first trigger runs, is an if-else:

```
   2  22 01       call_part
   4  21 17       command
   6  27 00       read_global
   8  28 00       wait
  10  02          compare_ne
  11  24 00 07    branch_if_zero_alt   -> 19 if zero
  14  22 15       call_part
  16  42 00 04    jump   -> 21
  19  22 18       call_part
  21  21 17       command
  23  32 01       ai
  25  43          return
```

Every branch target lands on an instruction boundary, which is the check that the widths are right.

### Trigger blocks

The parts do not start at the beginning of the section: `mission1`'s first part is at byte 1,740.
The script before the first part holds the blocks that triggers run. A trigger's `link` is a
halfword offset to its block, like a part's: `mission1`'s first three triggers link to 0, 18 and 36,
the blocks at bytes 0, 36 and 72. Of the 2,377 triggers across the 44 missions whose link is set,
2,102 land on a block that disassembles completely.

**Open:** the other 275 links, and the short runs between trigger blocks. In `mission1` those are 8 or 16
bytes, start with a small little-endian dword such as `01 00 00 00` or `09 00 00 00`, and are not
blocks; some links land on them, and others land inside a block. `sltool dte script` lists the
parts only.

**Open:** four 32-byte regions that nothing reaches, two in one part of `mission15` and one each in
`mission18` and `mission23`. Each directly follows a two-arm random_branch, `51 02 00 43` in three
cases and `51 02 00 45` in the fourth, whose arms split 50/50 and target bytes past the gap. They are
the only bytes of any part that are neither reached nor alignment padding.

## Prior art

The container, directory, record strides and the condition list come from the independent analysis
in
[Starlancer-OSS `docs/dte-format.md`](https://github.com/LordBlacksun/Starlancer-OSS/blob/main/docs/dte-format.md)
and its scripting reference, traced to the engine's loader and matcher, which in turn reconciles
with Captain Foster's Starlancer ME black-box work. Everything above was re-derived against the 44
shipped missions. The string pool being addressed by byte offset, and the trigger condition
distribution, are additions.
