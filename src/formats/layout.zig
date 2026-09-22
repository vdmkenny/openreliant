//! Reading fixed layouts in place: each record an `extern struct` whose fields are the file's own,
//! viewed over the bytes rather than read a field at a time. The game's files and its executable
//! are little-endian, as the host has to be for that; the few big-endian fields are `Big`.

const std = @import("std");
const builtin = @import("builtin");

comptime {
    if (builtin.cpu.arch.endian() != .little) @compileError("the game's layouts are read in place, which needs a little-endian host");
}

pub const Error = error{Truncated};

/// The record of type `T` at the start of `bytes`.
pub fn view(comptime T: type, bytes: []const u8) Error!*align(1) const T {
    if (bytes.len < @sizeOf(T)) return error.Truncated;
    return @ptrCast(bytes[0..@sizeOf(T)]);
}

/// The record of type `T` at the start of `bytes`, to write.
pub fn viewMut(comptime T: type, bytes: []u8) Error!*align(1) T {
    if (bytes.len < @sizeOf(T)) return error.Truncated;
    return @ptrCast(bytes[0..@sizeOf(T)]);
}

/// `count` records of type `T` from the start of `bytes`.
pub fn array(comptime T: type, bytes: []const u8, count: usize) Error![]align(1) const T {
    const size = std.math.mul(usize, count, @sizeOf(T)) catch return error.Truncated;
    if (bytes.len < size) return error.Truncated;
    return std.mem.bytesAsSlice(T, bytes[0..size]);
}

/// An integer stored big-endian, as a field of an `extern struct`.
pub fn Big(comptime T: type) type {
    return extern struct {
        bytes: [@sizeOf(T)]u8,

        const Self = @This();

        pub fn get(big: Self) T {
            return std.mem.readInt(T, &big.bytes, .big);
        }

        pub fn of(value: T) Self {
            var big: Self = undefined;
            std.mem.writeInt(T, &big.bytes, value, .big);
            return big;
        }
    };
}

test view {
    const Pair = extern struct { tag: u16, size: u32 align(1) };
    const bytes = [_]u8{ 0x34, 0x12, 0x78, 0x56, 0x34, 0x12, 0xFF };
    const pair = try view(Pair, &bytes);
    try std.testing.expectEqual(0x1234, pair.tag);
    try std.testing.expectEqual(0x12345678, pair.size);
    try std.testing.expectError(error.Truncated, view(Pair, bytes[0..5]));
    var out: [6]u8 = undefined;
    (try viewMut(Pair, &out)).* = .{ .tag = 1, .size = 2 };
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 2, 0, 0, 0 }, &out);
}

test array {
    const bytes = [_]u8{ 1, 0, 2, 0, 3 };
    const words = try array(u16, &bytes, 2);
    try std.testing.expectEqual(2, words[1]);
    try std.testing.expectError(error.Truncated, array(u16, &bytes, 3));
}

test Big {
    const size: Big(u32) = .of(0x01020304);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, &size.bytes);
    try std.testing.expectEqual(0x01020304, size.get());
}
