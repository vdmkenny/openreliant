//! The C runtime linked into the payload: the static multithreaded library of Visual C++ 6.0,
//! LIBCMT. `ghidra/names/LANCER.EXE.runtime.tsv` names its functions and data; the structures
//! here are those of it that the game's own code handles.

const std = @import("std");
const assert = std.debug.assert;

const engine = @import("../engine.zig");
const Pointer = engine.Pointer;
const Range = engine.sources.Range;

/// The runtime's code: from `__fpmath`, after the `srmemory.dll` import thunks, to the end of the
/// last runtime function, before the unwind funclets of the game's own functions.
pub const code: Range = .{ .start = 0x004CF23A, .end = 0x004DB99A };

/// A stdio stream, the runtime's `FILE`. `fopen` returns one, and `_iob` holds the first twenty,
/// of which the first three are stdin, stdout and stderr. `sprintf` and its kin write through one
/// on the stack that points at the caller's buffer.
pub const File = extern struct {
    /// The next character to read or write in the buffer.
    ptr: Pointer(u8),
    /// The characters left to read, or the room left to write.
    cnt: i32,
    /// The buffer.
    base: Pointer(u8),
    flag: Flags,
    /// The low-level handle, an index into the runtime's table of open files.
    file: i32,
    charbuf: i32,
    /// The buffer's size.
    bufsiz: i32,
    /// The name of a temporary file, deleted when the stream closes.
    tmpfname: Pointer(u8),

    /// The stream's state: `_IOREAD` and the rest, bit for bit.
    pub const Flags = packed struct(u32) {
        read: bool = false,
        write: bool = false,
        unbuffered: bool = false,
        /// The runtime allocated the buffer, and frees it on close.
        own_buffer: bool = false,
        eof: bool = false,
        failed: bool = false,
        /// The stream writes to a string: `sprintf`'s.
        string: bool = false,
        read_write: bool = false,
        /// The caller supplied the buffer through `setvbuf`.
        user_buffer: bool = false,
        _unused_9: u1 = 0,
        /// `setvbuf` set the buffer's size, which `fseek` then keeps.
        setvbuf: bool = false,
        feof: bool = false,
        /// Flush when the current call returns: a buffer lent to stdout or stderr for one call.
        flush_on_return: bool = false,
        ctrl_z: bool = false,
        /// Flushing commits the file to disk as well.
        commit: bool = false,
        _unused_15: u17 = 0,
    };

    comptime {
        assert(@offsetOf(File, "flag") == 0x0C);
        assert(@offsetOf(File, "file") == 0x10);
        assert(@sizeOf(File) == 0x20);
    }
};

/// `rand` (`0x004CF555`) and `srand` (`0x004CF548`), for one thread: the seed, 1 until seeded.
pub const Rand = struct {
    seed: u32 = 1,

    pub const max = 0x7FFF;

    pub fn srand(r: *Rand, seed: u32) void {
        r.seed = seed;
    }

    /// The seed times 214013 plus 2531011, then bits 16 to 30 of the new seed.
    pub fn rand(r: *Rand) u15 {
        r.seed = r.seed *% 214013 +% 2531011;
        return @truncate(r.seed >> 16);
    }

    /// The next number over `max`, from 0 to 1, as the game's code takes it (times `0x004DC4C8`).
    pub fn fraction(r: *Rand) f32 {
        return @as(f32, @floatFromInt(r.rand())) * (1.0 / @as(f32, max));
    }

    /// `fraction` less a half, from -0.5 to 0.5, as the game's code takes it for a direction or a
    /// turn either way.
    pub fn centred(r: *Rand) f32 {
        return r.fraction() - 0.5;
    }

    /// Three `fraction`s times `reach`, the last drawn first, as the game's code draws a vector:
    /// its compiler works a call's arguments out from the last.
    pub fn fractionVector(r: *Rand, reach: @Vector(3, f32)) @Vector(3, f32) {
        const z = r.fraction();
        const y = r.fraction();
        const x = r.fraction();
        return @Vector(3, f32){ x, y, z } * reach;
    }

    /// `fractionVector`, each less a half: from -0.5 to 0.5 times `reach`.
    pub fn centredVector(r: *Rand, reach: @Vector(3, f32)) @Vector(3, f32) {
        return (r.fractionVector(@splat(1)) - @as(@Vector(3, f32), @splat(0.5))) * reach;
    }
};

test "a vector's numbers are drawn last first" {
    var drawn: Rand = .{};
    const vector = drawn.centredVector(.{ 1, 2, 4 });
    var one_by_one: Rand = .{};
    const z = one_by_one.centred() * 4;
    const y = one_by_one.centred() * 2;
    const x = one_by_one.centred();
    try std.testing.expectEqual(@Vector(3, f32){ x, y, z }, vector);
    try std.testing.expectEqual(one_by_one.seed, drawn.seed);
}

test "stream flags match the runtime's constants" {
    // `sprintf`'s stream is `_IOWRT | _IOSTRG`, and a stream is in use while any of `_IOREAD`,
    // `_IOWRT` and `_IORW` is set.
    try std.testing.expectEqual(0x42, @as(u32, @bitCast(File.Flags{ .write = true, .string = true })));
    try std.testing.expectEqual(0x83, @as(u32, @bitCast(File.Flags{ .read = true, .write = true, .read_write = true })));
    try std.testing.expectEqual(0x4000, @as(u32, @bitCast(File.Flags{ .commit = true })));
}

test Rand {
    // The runtime's first numbers from its default seed.
    var r: Rand = .{};
    try std.testing.expectEqual(41, r.rand());
    try std.testing.expectEqual(18467, r.rand());
    try std.testing.expectEqual(6334, r.rand());
    try std.testing.expectApproxEqAbs(@as(f32, 26500.0 / 32767.0), r.fraction(), 1e-7);
    try std.testing.expectApproxEqAbs(@as(f32, 19169.0 / 32767.0 - 0.5), r.centred(), 1e-7);
}

test {
    std.testing.refAllDecls(@This());
}
