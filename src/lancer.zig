//! The game executable's own run-time structures, as the payload lays them out on 32-bit x86.
//!
//! The engine uses mission records in place, pointing each section at the file's bytes, so those
//! are the structures in `formats/dte.zig`. The ones here are those it builds itself. They describe
//! the payload's memory, for naming it in Ghidra: a `Pointer` is an address in the payload's
//! address space, never a host pointer.

const std = @import("std");

pub const game = @import("lancer/game.zig");
pub const input = @import("lancer/input.zig");
pub const orders = @import("lancer/orders.zig");
pub const sound = @import("lancer/sound.zig");
pub const stats = @import("lancer/stats.zig");
pub const vm = @import("lancer/vm.zig");

/// The 32-bit address of a `T` in the payload's address space.
pub fn Pointer(comptime T: type) type {
    return enum(u32) {
        null = 0,
        _,

        pub const Target = T;
    };
}

/// Machine code with the given signature, written in C for Ghidra's parser: a return type, an
/// optional calling convention and a parameter list, with no function name.
pub fn Code(comptime signature: []const u8) type {
    return opaque {
        pub const c_signature = signature;
    };
}

/// Whether `T` came from `Pointer`.
pub fn isPointer(comptime T: type) bool {
    return @typeInfo(T) == .@"enum" and @hasDecl(T, "Target") and T == Pointer(T.Target);
}

/// Whether `T` came from `Code`.
pub fn isCode(comptime T: type) bool {
    return @typeInfo(T) == .@"opaque" and @hasDecl(T, "c_signature");
}

test Pointer {
    const P = Pointer(u16);
    try std.testing.expect(isPointer(P));
    try std.testing.expect(!isPointer(u32));
    try std.testing.expectEqual(4, @sizeOf(P));
    try std.testing.expectEqual(0x00525F88, @intFromEnum(@as(P, @enumFromInt(0x00525F88))));
    try std.testing.expect(isCode(vm.Handler));
    try std.testing.expect(!isCode(anyopaque));
}

test {
    std.testing.refAllDecls(@This());
}
