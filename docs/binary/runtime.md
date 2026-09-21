# The C runtime

The payload links Visual C++ 6.0's static multithreaded C runtime, `LIBCMT`.

| Part | Range |
|---|---|
| Code | `0x004CF23A` to `0x004DB99A`, between the `srmemory.dll` import thunks and the game's unwind funclets |
| Initialized data | `0x00514AA8` to the end of `.data`'s file contents |
| Zero-filled data | `0x006235B0` to the end of `.data` |

[`ghidra/names/LANCER.EXE.runtime.tsv`](../../ghidra/names/LANCER.EXE.runtime.tsv) names every
function and global of it. Names are the linker's symbols, with the C compiler's leading underscore
(`_sprintf` is `sprintf`, `__lock` is `_lock`); labels and funclets without a symbol have descriptive
names (`acos_start`, `CallCatchBlock_finally`). Functions the game calls carry C signatures;
[`src/engine/libcmt.zig`](../../src/engine/libcmt.zig) defines `FILE`.

## Build

From the Rich header: the game's C++ objects are from compiler build 8447; the C objects and the
other C++ objects, the runtime's among them, are from build 8168, Visual C++ 6.0's first release;
the assembly is from MASM 6.13.

## Contents

**Start-up and exit.** `_WinMainCRTStartup` (`0x004D1210`), the entry point, creates the heap, the
per-thread data and the file table, reads the command line and environment, runs the initializers
and calls `WinMain` (`0x004A8B10`). `__cinit` runs the C initializers (`___xi_a` to `___xi_z`) and
the C++ ones (`___xc_a` to `___xc_z`, the game's static constructors). `_doexit` runs the `atexit`
functions, last first, then the terminators, then `ExitProcess`.

**Threads.** Each thread has a `_tiddata` block in a TLS slot, made by `__getptd` on first use:
`errno` at `+0x08`, the `rand` seed at `+0x14`. Locks are critical sections numbered in
`__locktable`, made by `__lock` on first use; the streams of `__iob` use locks `0x1C` on.

**Heap.** `malloc` rounds up to 16 bytes. Requests up to `___sbh_threshold` (1016) come from the
small-block heap: 1 MB regions, committed in 32 KB groups. Larger ones come from the Win32 heap
`__crtheap`. `operator new` is `malloc` with the new handler; `operator delete` is `free`.

**Streams.** A `FILE` is 32 bytes. `__iob` holds the first twenty: stdin, stdout, stderr, then
`fopen`'s. `___piob` points at every stream. `fread`, `fwrite`, `fseek` and the like lock the stream
and call an `_lk` twin. A file handle indexes the table at `___pioinfo`: blocks of 32 entries of
`0x24` bytes (Win32 handle, flags, lock). `__output` formats for the `printf` family; `sprintf` runs
it on a stack stream over the caller's buffer.

**Numbers.** `rand`: the seed times 214013 plus 2531011, returning bits 16 to 30. `__ftol`, the
compiler's float-to-int cast, truncates. `floor` and the intrinsics `__CIpow`, `__CIacos` and
`__CIasin` (x87 stack arguments) are the math library's. `__fpmath` tests for the Pentium FDIV flaw
and sets 53-bit precision.

**C++ exceptions.** Functions with objects to unwind register `___CxxFrameHandler`; functions with
`__try` register `__except_handler3`. `terminate` calls the thread's handler, if set, then `abort`.

**Code pages.** No `setlocale` is linked: the locale is the C locale. `___initmbctable` loads the
system ANSI code page into `__mbctype`, which the path and command-line functions use.

Identical functions share one copy: `fgetc` and `getc`, `fputc` and `putc`, `_itoa` and `_ltoa`,
`_CallMemberFunction0` and `_CallMemberFunction1`. The table names the first.

## Identification

Ghidra's Function ID "Visual Studio 1998" libraries are Visual C++ 4.2's. Only assembly routines
unchanged since then match (`_strlen`, `_memset`, `__aulldiv`). The rest is identified by behaviour,
callees and neighbours: an object's functions are contiguous.
