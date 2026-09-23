//! `.fat` sound banks: a table of RIFF/WAVE sounds ([`wave.zig`](wave.zig)) packed into one file.
//!
//! The engine loads a whole bank into memory and plays entry `n` by handing Miles the WAVE file at
//! `bank + offset`. An entry's priority decides whether it may take over a voice that is already
//! playing: the player finds the busy voice of lowest priority and stops it only for a sound whose
//! priority is higher (`sound_play`, `0x00481F80`).

const std = @import("std");
const assert = std.debug.assert;

const layout = @import("layout.zig");

pub const magic = "2.00";

pub const Error = error{
    NotABank,
    Truncated,
    /// An entry points outside the file.
    BadEntry,
};

pub const Entry = extern struct {
    /// From the start of the bank.
    offset: u32,
    size: u32,
    /// Higher takes over a voice from lower. The shipped banks use 1, 5, 50 and 10000.
    priority: u32,

    comptime {
        assert(@sizeOf(Entry) == 12);
    }
};

/// The bank's header, which its table of entries follows.
pub const Header = extern struct {
    magic: [4]u8,
    count: u32,

    comptime {
        assert(@sizeOf(Header) == 8);
    }
};

pub const header_size = @sizeOf(Header);

pub const Bank = struct {
    bytes: []const u8,
    entries: []align(1) const Entry,

    pub fn parse(bytes: []const u8) Error!Bank {
        const header = layout.view(Header, bytes) catch return error.NotABank;
        if (!std.mem.eql(u8, &header.magic, magic)) return error.NotABank;
        const entries = layout.array(Entry, bytes[header_size..], header.count) catch return error.Truncated;
        for (entries) |entry| {
            if (@as(usize, entry.offset) + entry.size > bytes.len) return error.BadEntry;
        }
        return .{ .bytes = bytes, .entries = entries };
    }

    /// Sound `index`, a complete RIFF/WAVE file.
    pub fn sound(bank: Bank, index: usize) ?[]const u8 {
        if (index >= bank.entries.len) return null;
        const entry = bank.entries[index];
        return bank.bytes[entry.offset..][0..entry.size];
    }
};

test Bank {
    const wave = comptime @import("wave.zig").testing.pcm("\x00\x00\x01\x00");
    const entry: Entry = .{ .offset = header_size + @sizeOf(Entry), .size = wave.len, .priority = 50 };
    const file = std.mem.toBytes(Header{ .magic = magic.*, .count = 1 }) ++ std.mem.toBytes(entry) ++ wave;

    const bank = try Bank.parse(file);
    try std.testing.expectEqual(@as(usize, 1), bank.entries.len);
    try std.testing.expectEqual(@as(u32, 50), bank.entries[0].priority);
    try std.testing.expectEqualSlices(u8, wave, bank.sound(0).?);
    try std.testing.expectEqual(@as(?[]const u8, null), bank.sound(1));

    try std.testing.expectError(error.NotABank, Bank.parse("1.40\x00\x00\x00\x00"));
    try std.testing.expectError(error.Truncated, Bank.parse(magic ++ "\x09\x00\x00\x00"));
}
