# The C Runtime (LIBCMT)

The StarLancer executable statically links the Visual C++ 6.0 multithreaded C runtime library (`LIBCMT`).

---

## Memory Layout

| Segment | Virtual Address Range | Description |
|---|---|---|
| **Code** | `0x004CF23A` – `0x004DB99A` | Runtime routines positioned between `srmemory.dll` import thunks and C++ exception unwind funclets. |
| **Initialized Data** | `0x00514AA8` – end of `.data` | Static runtime data structures, locks, and file tables. |
| **BSS (Zero-filled)** | `0x006235B0` – end of `.data` | Uninitialized runtime state. |

Symbol names in [`ghidra/names/LANCER.EXE.runtime.tsv`](../../ghidra/names/LANCER.EXE.runtime.tsv) follow standard MSVC runtime conventions (e.g., `_sprintf` for `sprintf`, `__lock` for internal critical section locks). Unnamed helper funclets and structured exception labels are assigned descriptive identifiers.

---

## Compiler Toolchain Signatures

Analysis of the executable's MSVC Rich Header reveals:
- **Game C++ Objects**: Compiled with MSVC compiler build 8447 (Visual C++ 6.0 Service Pack 3).
- **Runtime Objects**: Compiled with MSVC compiler build 8168 (Visual C++ 6.0 RTM).
- **Assembly Routines**: Assembled with MASM 6.13.

---

## Key Subsystems

### Startup & Shutdown
- `_WinMainCRTStartup` (`0x004D1210`) initializes heap allocators, TLS storage, and file tables, parses command-line arguments, runs static C/C++ constructors via `__cinit`, and invokes `WinMain` (`0x004A8B10`).
- `_doexit` evaluates `atexit` callbacks in LIFO order and calls `ExitProcess`.

### Memory Allocation
- **Small-Block Heap (SBH)**: Allocations up to 1,016 bytes (`___sbh_threshold`) are serviced from 1 MB memory arenas segmented into 32 KB groups.
- **Large Allocations**: Requests exceeding the threshold delegate directly to the Win32 process heap (`__crtheap`).
- Default allocation alignment is 16 bytes.

### Threading & Concurrency
- Thread Local Storage (TLS) holds per-thread `_tiddata` records (`errno`, pseudo-random generator state).
- Thread synchronization relies on Win32 `CRITICAL_SECTION` objects indexed in `__locktable`.

### File I/O Streams
- File streams are tracked in `__iob` (standard I/O handles plus open `FILE` streams).
- High-level I/O calls (`fread`, `fwrite`, `fseek`) acquire stream-level locks before calling low-level `_lk` routines.

### Math & Float Casting
- Float-to-integer conversion uses `__ftol`, performing truncating casts on the x87 FPU.
- Transcendental functions (`__CIpow`, `__CIacos`, `__CIasin`) operate directly on the x87 stack.
- `__fpmath` detects the Pentium FDIV erratum and configures 53-bit precision.

### Exception Handling
- Structured Exception Handling (SEH) frames register `___CxxFrameHandler` for C++ object destruction and `__except_handler3` for `__try`/`__except` blocks.
