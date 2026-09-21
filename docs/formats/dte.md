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

**Opcodes `0x02` to `0x07` and `0x14` to `0x55` exist**, 72 in all. That is read from the handler
table itself, which the payload stores with exactly those entries filled and every other entry
null. Of the named ones, `0x21` calls an Executor command, `0x32` sets an AI behaviour, `0x22` and
`0x4D` mark and branch to script parts, `0x27` and `0x40` read and write a global, `0x2C` and
`0x2D` reference an object and a flight group, and `0x43` ends a line.

Frequency in `mission1` agrees: after operand bytes, the commonest are `0x21` command (386),
`0x28` wait (282), `0x2C` object (264) and `0x32` AI (182).

### Open: operand lengths and block addressing

The stream cannot be disassembled linearly, and this project does not pretend otherwise.

A thread starts at a block whose leading `u16` gives its length, and triggers name blocks by action
index, so blocks are entered by address rather than laid end to end. Walking the section from its
start reads that leading length as an opcode and desynchronises from there: 40% of the resulting
instructions land on opcodes the handler table leaves null, which is the signature of a decoder
that has lost alignment rather than of unusual data.

The first block of `mission1` does decode cleanly, ending exactly on its `0x43` marker, once `0x42`
is given two operand bytes rather than one. So the lengths are recoverable. Getting them right
means reading the 72 handlers to see how far each advances the instruction pointer, rather than
inferring them from patterns in the data, and until that is done `sltool dte script` reports what
the section contains instead of claiming to decode it.

## Prior art

The container, directory, record strides and the condition list come from the independent analysis
in
[Starlancer-OSS `docs/dte-format.md`](https://github.com/LordBlacksun/Starlancer-OSS/blob/main/docs/dte-format.md)
and its scripting reference, traced to the engine's loader and matcher, which in turn reconciles
with Captain Foster's Starlancer ME black-box work. Everything above was re-derived against the 44
shipped missions. The string pool being addressed by byte offset, and the trigger condition
distribution, are additions.
