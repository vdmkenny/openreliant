# `.DTE` missions

Each of the 44 missions is one image: the ships it places, the globals it seeds, the triggers it
arms, and the script they run.

```bash
sltool dte info <mission>        # counts and sizes
sltool dte sections <mission>    # the 27-entry directory
sltool dte ships <mission>       # placed ships and nav points
sltool dte triggers <mission>    # triggers, with the object whose slice holds each
sltool dte strings <mission>     # the string pool
sltool dte parts <mission>       # the script's named routines
sltool dte script <mission>      # every trigger block and part, disassembled
make check-missions              # parse all 44
```

## Container

A mission inside a `.HOG` is RefPack compressed; one loose in `missions\` is stored expanded. The
engine tells them apart by the first two bytes, so either is legal anywhere. A retail install
carries two loose missions, `mission18.dte` and `mission25.dte`, which begin `08 33` where their
archive copies begin `10 FB`. `sltool hog` expands members as it extracts.

## Directory

The image opens with **27 entries of 8 bytes**:

| Offset | Type | Field |
|---|---|---|
| 0 | u16 | Records in use, except where noted below |
| 2 | u8 | Unused |
| 3 | u8 | Which of the section's fields the loader turns into live pointers |
| 4 | u32 | Offset of the section, or `0xFFFF` when unused |

Capacity is fixed: a section's offset is the same in every mission built from the same template, and
the count says how much of the reserved room is filled. 36 of the 44 missions are exactly 850,919
bytes for that reason.

| # | Section | Stride | Contents |
|---|---|---|---|
| 0 | strings | | String pool |
| 1 | operands_a | 2 | Operand resolution |
| 2 | globals | `0x0C` | Named values the script reads and writes |
| 3 | ships | `0x4C` | Placed ships, stations and nav points |
| 4 | objectives | `0x14` | |
| 5 | triggers | `0x30` | |
| 6 | script | | Bytecode. **The count is in halfwords** |
| 7 | ship_triggers | 8 | Each object's slice of the triggers |
| 8 | parts | `0x1C` | One descriptor per named script routine |
| 10 | script_flags | 1 | One flag per script byte, marking where the VM may yield |
| 13 | squads | `0x0C` | |
| 15 | nav_geometry | `0x10` | |
| 16 | sub_objects | `0x44` | |
| 17 | parts_b | `0x1C` | Part descriptors for section 18 |
| 18 | script_b | | A second bytecode section |
| 22 | operands_b | 2 | |

Sections 17 to 21 and 25 are empty in all 44 missions. In every mission `script_flags` holds twice
the count of section 6: one entry per script byte.

## String pool

A run of NUL-terminated names, **referenced by byte offset into the pool, not by index**, which is
why a `u16` suffices: the pool reserves 65,535 bytes, and `mission1` fills 17,207 of them with 9,088
strings. Byte offsets resolve all 8,265 ship names across the 44 missions, for example
`Player_Ship`, `(A1)Naginata`, `(WL)Viper's Coyote`, `Convoy Nav Point`.

## Ships

Stride `0x4C`, one per placed object, nav points included.

| Offset | Type | Field |
|---|---|---|
| `0x00` | u32 | Flight group |
| `0x04` | u16 | Name, as a string pool offset |
| `0x08` | f32 x3 | Position, copied from `0x1C` when the mission loads |
| `0x15` | u8 | Side. 255 marks the player's own record |
| `0x17` | u8 | Flags; bit 0 disables the record |
| `0x18` | u16 | Role. Ships stay below `0x100`; nav points and markers use 999 and `0x3E3` to `0x3E8` |
| `0x1C` | f32 x3 | Position as authored |
| `0x2E`, `0x3A`, `0x4A` | i16 | Yaw, pitch, roll, in whole degrees |
| `0x30` | u32 | Live object handle, `0xFFFFFFFF` until the mission arms |

Each angle sits two bytes after its runtime copy, at `0x2C`, `0x38` and `0x48`. All 8,265 records
hold angles within [-360, 360]. Positions are absolute, on the order of 10^7.

## Triggers

Stride `0x30`. A trigger runs a block of script when an event it watches happens to its subject.

| Offset | Field |
|---|---|
| `0x00` | Condition |
| `0x01` | Repeat mode |
| `0x02` | Link: the block to run, as a halfword offset into the script; `0xFFFF` for none |
| `0x14` | Armed, set for every trigger when the mission starts |
| `0x15` | Qualifier; `0xFF` for ordinary events |
| `0x16` | Zero runs the block's thread at once, inside the event; otherwise the scheduler does |
| `0x19` | Firings left, for repeat mode 2 |
| `0x1C` | Operands, four bytes each, which the condition checks against the event's |

A trigger holds no subject. Section 7 gives each object, by the ID an event carries, a slice of the
trigger list: a count at `+1` and the index of the first trigger at `+2`. When an event happens to
an object, `FUN_0045CEA0` walks its slice and fires each trigger that is armed, has the event's
condition and qualifier, and whose operands pass. Firing starts a thread at `script + link * 2`.

No trigger is in two slices, and 320 of the 2,446 are in none, so they can never fire. Section 7 has
more entries than section 3 in every mission, so its IDs cover more than the ship records.

Repeat mode `0` disarms the trigger when it fires (1,833 triggers), `1` never disarms it (612), and
`2` disarms it when the counter at `0x19` runs out (1). For four conditions, ShotAt, Destroyed,
Cloaked and Decloaked, a handler of the condition's can veto an event; a vetoed event still fires
the triggers whose repeat mode equals the condition's descriptor byte `+0x0D`, which is 1 for the
last three.

### Conditions

The engine's descriptor table at `0x4F6698` lists 35 conditions, named in the payload as `TT_*`
constants; the last two are internal. Each descriptor is `0x1C` bytes: a name pointer, a slot and a
discriminator byte at `+0x0C` and `+0x0D`, and three handler pointers from `+0x10`, set only for
ShotAt, Destroyed, Cloaked and Decloaked. The table lies just past the VM's dispatch table.

| Condition | Triggers |
|---|---|
| `destroyed` | 990 |
| `shot_at` | 453 |
| `ship_reached` | 242 |
| `launched` | 203 |
| `proximity_general` | 197 |
| `jumped_in` | 132 |
| `jumped_through_hoop` | 80 |
| `player_ready_to_jump` | 35 |
| `ripper_dropped_object`, `object_scooped` | 20, 19 |
| the remaining twelve used | 3 to 9 each |

2,168 triggers carry qualifier `0xFF`, which three of the four call sites that raise events pass. **Unknown:** what the other qualifiers, `0` in 207 triggers and `1` to `7` in the rest,
select.

## Script

Section 6 is the mission's bytecode: `count * 2` bytes, 7,552 in `mission1`. The interpreter is a
dispatch loop:

```
handler = table[code[ip]]      // 86 entries at 0x004F6350
ip += 1
continue while handler() != 0
```

### Instruction set

**71 opcodes: `0x02` to `0x07` and `0x14` to `0x55`, less `0x50`.** The other entries of the
86-entry table are null. The condition descriptor table follows it, and its handler pointers look
like further entries.

Five opcodes run the same handler as another and are the same operation: `0x24` and `0x23`, `0x2B`
and `0x2A`, `0x25` and `0x43`, `0x32` and `0x2E`, `0x55` and `0x47`.

Every opcode's size and effect on the instruction pointer is read from its handler. The dispatcher
calls a handler with `ECX` pointing at the cell holding the instruction pointer, already advanced
past the opcode, and execution resumes wherever the handler leaves that cell. `src/tools/vmgen`
reads the dispatch table from the binary, parses each handler from Ghidra's exported disassembly,
and symbolically executes every path through it, tracking that cell. Paths must agree, or it reports
the handler instead of guessing. Its output is
[`src/formats/vm_opcodes.zig`](../../src/formats/vm_opcodes.zig):

```bash
make ghidra-run SCRIPT=DefineVmHandlers.java   # define the handlers as functions
make ghidra-export-game
make vm-opcodes
```

`DefineVmHandlers.java` is needed because nothing calls a handler directly, so auto-analysis leaves
most of them undefined.

| Form | Opcodes | Next instruction |
|---|---|---|
| `sequential` | 61 | After the operands |
| `branch` | `0x23`, `0x24`, `0x42` | The operands are a displacement |
| `inline_data` | `0x2A`, `0x2B` | After the run the operand byte measures |
| `transfer` | `0x22`, `0x25`, `0x43`, `0x4A`, `0x51` | Not known statically |

68 opcodes are a fixed size: 38 take no operands, 22 one byte, 7 two bytes, and `0x4B` three. The
other three carry their own length:

- **`0x2A` speech** (and `0x2B`) takes a length byte that counts itself, pushes a pointer to the
  bytes after it, and steps over them. They are a NUL-terminated file name, a `.wav` of speech or a
  `.ut` cutscene: `mission81` opens by cueing `new_sim02.wav`.
- **`0x51` random_branch** takes a count, a big-endian default target, then that many four-byte
  arms of big-endian target, threshold and one unidentified byte: `3 + 4n` bytes. It rolls a number
  below 100 and takes the first arm whose threshold exceeds it, or the default. Its targets count
  from the opcode. This is the one encoding read by hand: its length depends on a byte the analysis
  cannot follow.

The analysis also records whether any path leaves the instruction pointer just past the operands.
None does for `0x42` jump, so it never falls through. The transfers are classified by name, and a
compile-time check rejects any transfer in the table without a classification:

| Transfer | Opcodes | Next |
|---|---|---|
| Call | `0x22` call_part, `0x4A` call_part_b | Into a part, then the following instruction |
| Return | `0x43` return, `0x25` | Out of the part, or out of the thread |
| Random branch | `0x51` | One of its arms |

The analysis cannot classify these itself: a call's only sequential path is its missing-part
early-out, and return's path that leaves the pointer alone is the one that ends the thread, which it
signals through its return value.

### Control flow

- **`0x22` call_part** takes a part index into the runtime part table (stride `0x74`: block pointer
  at `+0`, argument count at `+4`), pushes the argument count, return address, frame base and block
  end, sets the frame base to `stack - (4n + 16)`, and enters the block.
- **`0x43` return** (and `0x25`) unwinds that, or ends the thread when the call depth is zero.
- **`0x4D` spawn_part** moves the part's arguments from this thread's stack to a new thread's, starts
  the new thread on the part, and carries on.
- **`0x4A` call_part_b** and **`0x4E` spawn_part_b** do the same through the second part table,
  which serves section 18.
- **`0x23` branch_if_zero** (and `0x24`) pops a value and branches if it is zero; **`0x42` jump**
  always branches. The displacement is **big-endian**, the only big-endian field in the format, and
  counts from its own position.
- **`0x21` command** takes an index into the Executor catalogue, stride `0x74`: implementation
  pointer at `+0`, argument count at `+4`.
- **`0x28` push_constant** pushes constant `n` of the running block (see [Routines](#routines)).
- A thread starts with its block end in `[0x5373F0]`, and at most 32 run at once.

### Parts

Section 8 holds one 28-byte descriptor per **part**, a named routine. The loader expands it into the
256-entry runtime part table.

| Offset | Size | Field |
|---|---|---|
| `0x00` | 2 | Name, as a string pool offset |
| `0x0A` | 2 | Start, in halfwords from the start of the script; `0xFFFF` for none |
| `0x0D` | 1 | Argument count |
| `0x10` | 2 | Extent, in halfwords |
| `0x19` | 1 | Passed by the loader to the routine that fills the runtime entry |

The loader sets `block = script + start * 2`, which fixes the halfword unit. In every mission the
parts are in address order and contiguous, each one's `start + extent` being the next one's `start`,
and the last ends at the end of section 6.

Missions carry their authors' names for them. `mission1` has 32:

```
  #  offset  bytes  args  block  name
  0    1740    192     0    168  (F)launchfunction
  1    1932    160     0    144  (F)Jumping to CONVOY
  2    2092    252     0    220  (F)Arrival at CONVOY
  ...
 31    7524     28     0     20  <F>Objective window
```

Across the 44 missions, 1,625 parts take no arguments, four take two and one takes one.

### Blocks

A block is a `u16` length, which **counts its own two bytes**, then instructions: the engine starts
a thread at `block + 2` with its limit at `block + length`. The instructions end with a `return`,
padded with up to three bytes to a four-byte boundary.

### Routines

The script section is a sequence of **routines**, each a block followed by its **constant table**:
dwords that `push_constant n` reads, starting at the block's end. First come the blocks triggers
run, then the parts:

- A part's extent covers its block and its constants.
- A trigger block's constants run to the next routine. `mission1`'s first part is at byte 1,740,
  after 28 trigger blocks starting at bytes 0, 36, 72 and so on.

In every mission this tiles the section exactly: 2,080 trigger blocks, one for each trigger that can
fire and has a link, and 1,623 parts, 3,703 routines in all. Of the 2,126 triggers that can fire,
46 have no link. Each constant table is exactly as long as the highest
index its block pushes, rounded up to 8 bytes; the filler dword that rounding adds is not read.

```
sltool dte script <mission>    # every routine, with its constants
```

`sltool dte script` follows control flow from each block's entry rather than sweeping, because
`jump`, `return` and `random_branch` never fall through, and shows the value behind each
`push_constant`. **Every routine disassembles completely**, except 128 bytes listed under
[Open](#open). The first block of `mission1`, which its first trigger runs, compares global 0
against its constant 1 and calls one of two parts:

```
0 to 36: trigger 0
       2  22 01       call_part
       4  21 17       command
       6  27 00       read_global
       8  28 00       push_constant   = 1
      10  02          compare_ne
      11  24 00 07    branch_if_zero_alt   -> 19 if zero
      14  22 15       call_part
      16  42 00 04    jump   -> 21
      19  22 18       call_part
      21  21 17       command
      23  32 01       ai
      25  43          return
  constants: 1 220332040
```

The links of the 297 triggers no slice holds are never followed, and 275 of them do not point at a
block.

### Open

- Four 32-byte regions that nothing reaches, two in one part of `mission15` and one each in
  `mission18` and `mission23`. Each follows a random_branch whose two arms split 50/50 and target
  the bytes after the gap: `51 02 00 43` in three cases, `51 02 00 45` in the fourth.
- What the qualifier byte selects, and what the object IDs in section 7 index.

## Prior art

The container, directory, record strides and condition list are from
[Starlancer-OSS `docs/dte-format.md`](https://github.com/LordBlacksun/Starlancer-OSS/blob/main/docs/dte-format.md)
and its scripting reference, which build on Captain Foster's Starlancer ME work. Everything above
was re-checked against the 44 shipped missions. The byte-offset string pool, the condition
distribution, and everything about the script beyond the dispatch loop are additions, read from the
payload.
