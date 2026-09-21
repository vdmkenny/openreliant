# The C runtime

The payload links its C runtime statically: the multithreaded library of Visual C++ 6.0, `LIBCMT`.
Its code runs from `0x004CF23A`, after the `srmemory.dll` import thunks, to `0x004DB99A`, before the
unwind funclets of the game's own functions. Its data closes both parts of `.data`: the initialized
part from `0x00514AA8`, and the zero-filled part from `0x006235B0` to the section's end.

[`ghidra/names/LANCER.EXE.runtime.tsv`](../../ghidra/names/LANCER.EXE.runtime.tsv) names every
function in that range and the runtime's global data, and `make ghidra-annotate` applies it with
the other tables. The names are the runtime's own symbols as the linker saw them, with the C
compiler's leading underscore: `_sprintf` is `sprintf`, `__lock` is `_lock`. The few labels and
funclets without a symbol of their own have descriptive names (`acos_start`,
`CallCatchBlock_finally`). The public functions the game calls carry their C signatures, and
[`src/lancer/runtime.zig`](../../src/lancer/runtime.zig) defines `FILE` for them.

## The build

The payload's Rich header records the tools that built its objects. Most are C++ from build 8447
of the compiler: the game's own sources. The C objects and the rest of the C++ ones are from build
8168, Visual C++ 6.0 as first released, and the runtime is among them, with assembly from MASM
6.13. So the game was compiled with a later build of the compiler than its runtime library.

## What it holds

**Start-up and exit.** The entry point, `_WinMainCRTStartup` (`0x004D1210`), creates the heap, the
per-thread data and the file table, reads the command line and environment, runs the initializers
and calls `WinMain` (`0x004A8B10`). `__cinit` runs two tables of function pointers: the C
initializers from `___xi_a` to `___xi_z` and the C++ ones from `___xc_a` to `___xc_z`, which are the
game's static constructors. `_doexit` runs the `atexit` functions, last first, then the
pre-terminators and terminators, then `ExitProcess`.

**Threads.** Each thread has a `_tiddata` block in a TLS slot, allocated by `__getptd` on first use:
`errno` at `+0x08`, the `rand` seed at `+0x14`. The runtime's locks are critical sections numbered
in `__locktable`, each created on first use by `__lock`; the streams of `__iob` use the locks from
`0x1C` on.

**The heap.** `malloc` rounds a request up to a multiple of 16 bytes and serves it from the
small-block heap if it is at most `___sbh_threshold`, 1016 bytes, and otherwise from the Win32 heap
`__crtheap`. The small-block heap reserves regions of 1 MB and commits them in groups of 32 KB.
`free` asks the small-block heap first whether one of its regions holds the block. `operator new` is
`malloc` calling the new handler on failure; `operator delete` is `free`.

**Streams and files.** A `FILE` is 32 bytes; `__iob` holds the first twenty, of which stdin, stdout
and stderr are the first three, and `___piob` points at every stream. Each stream has a lock;
`fread`, `fwrite`, `fseek` and their kin take it and call an `_lk` twin that does the work. Below
the streams, a file handle is an index into the table `___pioinfo` points at: blocks of 32 entries
of `0x24` bytes, each a Win32 handle, flags and a lock. `__output` is the formatting engine behind
`printf`, `sprintf`, `vsprintf` and `fprintf`; `sprintf` runs it on a stream on the stack whose
buffer is the caller's.

**Numbers.** `rand` is the Microsoft linear congruential generator: the seed times 214013 plus
2531011, returning bits 16 to 30 of the new seed. `__ftol`, which the compiler calls for every cast
from floating point to integer, truncates: it sets the x87 rounding control to chop around the
store. `floor` and the intrinsic forms of `pow`, `acos` and `asin` (`__CIpow`, `__CIacos`,
`__CIasin`, which take their arguments on the x87 stack) come from the math library. `__fpmath`
tests the processor for the Pentium FDIV flaw at start-up and sets the x87 to 53-bit precision.

**C++ exceptions.** A function with objects to unwind registers `___CxxFrameHandler`, and one with
`__try` blocks registers `__except_handler3`. `___InternalCxxFrameHandler` and the frame support
around it (`FindHandler`, `CatchIt`, `BuildCatchObject`, `CallCatchBlock`) find and run catch
blocks; `terminate` calls the thread's terminate handler, if one is set, then `abort`.

**Code pages.** No `setlocale` is linked, so the locale stays the C locale. The multibyte tables
(`__mbctype`) follow the system's ANSI code page, which `___initmbctable` loads at start-up, and the
path and command-line functions consult them.

Some functions are two C functions whose code is identical, of which the image holds one copy:
`fgetc` and `getc`, `fputc` and `putc`, `_itoa` and `_ltoa`, and `_CallMemberFunction0` and
`_CallMemberFunction1`. The table names each after the first.

## Identifying it

Ghidra's Function ID databases name only part of the runtime. Their "Visual Studio 1998" libraries
are Visual C++ 4.2's, whose C code differs from this release's, so what matches is mostly the
assembly routines that did not change between versions: `_strlen`, `_memset`, `__aulldiv` and the
like. The rest is identified from each function's behaviour, the functions it calls and those
beside it: the linker lays out each object file's functions together, in the order it pulled the
object files in, so a function's neighbours are usually the rest of its source file.

The runtime's calls into `kernel32` are fixed by what each of its functions does, which makes them
the ground truth for the import redirection described in
[`safedisc.md`](safedisc.md#4-call-sites-are-redirected).
