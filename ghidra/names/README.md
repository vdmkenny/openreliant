# Names tables

These tables name and type the functions and data of the game's executables in Ghidra.
[`ghidra/scripts/Annotate.java`](../scripts/Annotate.java) applies them (`make ghidra-annotate`),
after the rows `ghidragen names` writes for the code the payload reaches only through its tables,
so a row here overrides a generated one. [`docs/toolchain.md`](../../docs/toolchain.md) describes
the whole process.

| File | Program |
|---|---|
| [`LANCER.EXE.tsv`](LANCER.EXE.tsv) | The payload executable, kept by hand as functions and data are identified |
| [`LANCER.EXE.runtime.tsv`](LANCER.EXE.runtime.tsv) | The C runtime linked into the payload, the static multithreaded library of Visual C++ 6.0 (LIBCMT) |
| [`srd3d.dll.tsv`](srd3d.dll.tsv) | `srd3d.dll`, Surrender's Direct3D 7 driver |

## Format

Each file is tab-separated. The first line is the header, and every other line is a row with five
columns:

| Column | Contents |
|---|---|
| `address` | Eight lowercase hex digits |
| `kind` | `function` or `data` |
| `name` | The name, with no spaces |
| `type` | For a function, its signature without the name; for data, a type string. May be empty. |
| `comment` | May be empty |

Types are those of Ghidra and of the schema `ghidragen types` writes from
[`src/engine.zig`](../../src/engine.zig) and [`src/formats/dte.zig`](../../src/formats/dte.zig).

A row has all five columns even when the last ones are empty, and no field contains a double
quote, so that GitHub can show the file as a table. There are no blank or comment lines.
`zig build test` checks all of this, and that no address is named twice.

## Contents

The rows of `LANCER.EXE.tsv` are grouped by area, in this order: the script VM, mission loading,
triggers and objects, stat tables, the loadout screen, files, sound and fonts, live objects,
Surrender's vector and matrix helpers, the flight model, the game loop, the camera, player input,
orders, combat maneuvers, textures, meshes and drawing, and the backdrop. The rows added since
follow, in the order the work was done. The VM's opcode handlers and command implementations are
named by `ghidragen names` instead.

The names in `LANCER.EXE.runtime.tsv` are the runtime's own symbols, with the compiler's leading
underscore; a few labels and funclets with no symbol of their own have descriptive names.
[`docs/binary/runtime.md`](../../docs/binary/runtime.md) describes the runtime and how these were
identified. Its rows are grouped as floating-point start-up, conversions and character classes,
C++ exception handling, structured exception handling, files and the heap, start-up and exit,
floating-point control, paths and case, printf's floating-point conversions, the math library's
support routines, threads, locks, C++ exception frames, errno and stdio, the heap, time, signals,
directories and the command line, multibyte code pages, floating-point conversions, low-level
files, long double arithmetic, integer formatting, strings and the environment, and then the data.

`srd3d.dll` draws what the payload has transformed and lit; `SR_driver_init` fills the payload's
device table with the functions in `srd3d.dll.tsv`. Its rows are grouped as the device, the frame,
meshes, textures and state.
