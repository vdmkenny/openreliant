//! `.fat` sound banks: a table of RIFF/WAVE sounds packed into one file.
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

/// What a sound's WAVE header says, as far as listing it needs.
pub const Wave = struct {
    format: Format,
    channels: u16,
    rate: u32,
    bits: u16,
    block_align: u16,
    /// Sample frames, from the `fact` chunk, or for PCM from the data length.
    frames: ?u32,
    data: []const u8,

    pub const Format = enum(u16) {
        pcm = 1,
        ima_adpcm = 0x11,
        _,

        pub fn format(tag: Format, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            return switch (tag) {
                _ => writer.print("format {d}", .{@intFromEnum(tag)}),
                inline else => |named| writer.writeAll(@tagName(named)),
            };
        }
    };

    /// The chunks this module reads.
    const Chunk = enum { fmt, fact, data };

    /// The file's header: `RIFF`, the length of what follows, and the form, `WAVE`.
    pub const Riff = extern struct {
        id: [4]u8,
        size: u32,
        form: [4]u8,
    };

    /// What starts each chunk: its id and its length, which leaves out the padding to an even
    /// length.
    pub const ChunkHeader = extern struct {
        id: [4]u8,
        size: u32,
    };

    /// The `fmt ` chunk's fields, as far as every format has them.
    pub const FormatChunk = extern struct {
        format: Format,
        channels: u16,
        rate: u32,
        byte_rate: u32,
        block_align: u16,
        bits: u16,

        comptime {
            assert(@sizeOf(FormatChunk) == 16);
        }
    };

    fn chunkOf(id: *const [4]u8) ?Chunk {
        const ids = std.StaticStringMap(Chunk).initComptime(.{
            .{ "fmt ", .fmt },
            .{ "fact", .fact },
            .{ "data", .data },
        });
        return ids.get(id);
    }

    pub fn parse(bytes: []const u8) error{NotAWave}!Wave {
        const riff = layout.view(Riff, bytes) catch return error.NotAWave;
        if (!std.mem.eql(u8, &riff.id, "RIFF") or !std.mem.eql(u8, &riff.form, "WAVE")) return error.NotAWave;
        var wave: Wave = .{
            .format = @enumFromInt(0),
            .channels = 0,
            .rate = 0,
            .bits = 0,
            .block_align = 0,
            .frames = null,
            .data = &.{},
        };
        var seen_format = false;

        var rest = bytes[@sizeOf(Riff)..];
        while (layout.view(ChunkHeader, rest)) |chunk| {
            const after = rest[@sizeOf(ChunkHeader)..];
            if (chunk.size > after.len) return error.NotAWave;
            const body = after[0..chunk.size];
            // Chunks are padded to an even length.
            rest = after[@min(after.len, chunk.size + (chunk.size & 1))..];

            switch (chunkOf(&chunk.id) orelse continue) {
                .fmt => {
                    const fmt = layout.view(FormatChunk, body) catch return error.NotAWave;
                    wave.format = fmt.format;
                    wave.channels = fmt.channels;
                    wave.rate = fmt.rate;
                    wave.block_align = fmt.block_align;
                    wave.bits = fmt.bits;
                    seen_format = true;
                },
                .fact => if (layout.view(u32, body)) |frames| {
                    wave.frames = frames.*;
                } else |_| {},
                .data => wave.data = body,
            }
        } else |_| {}
        if (!seen_format) return error.NotAWave;
        if (wave.frames == null and wave.format == .pcm and wave.block_align != 0) {
            wave.frames = @intCast(wave.data.len / wave.block_align);
        }
        return wave;
    }

    /// Length in seconds, when the header says how many frames there are.
    pub fn seconds(wave: Wave) ?f64 {
        const frames = wave.frames orelse return null;
        if (wave.rate == 0) return null;
        return @as(f64, @floatFromInt(frames)) / @as(f64, @floatFromInt(wave.rate));
    }
};

/// A chunk of `body`, with its header.
fn testChunk(comptime id: *const [4]u8, comptime body: []const u8) []const u8 {
    return std.mem.toBytes(Wave.ChunkHeader{ .id = id.*, .size = body.len }) ++ body;
}

fn testWave(comptime format: Wave.Format, comptime extra: []const u8, comptime data: []const u8) []const u8 {
    const fmt: Wave.FormatChunk = .{ .format = format, .channels = 1, .rate = 22050, .byte_rate = 44100, .block_align = 2, .bits = 16 };
    const body = "WAVE" ++ testChunk("fmt ", &std.mem.toBytes(fmt)) ++ extra ++ testChunk("data", data);
    return "RIFF" ++ std.mem.toBytes(@as(u32, body.len)) ++ body;
}

test Bank {
    const wave = comptime testWave(.pcm, "", "\x00\x00\x01\x00");
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

test Wave {
    const pcm = try Wave.parse(comptime testWave(.pcm, "", "\x00\x00\x01\x00\x02\x00\x03\x00"));
    try std.testing.expectEqual(Wave.Format.pcm, pcm.format);
    try std.testing.expectEqual(@as(?u32, 4), pcm.frames);

    const fact = comptime testChunk("fact", &std.mem.toBytes(@as(u32, 22050)));
    const adpcm = try Wave.parse(comptime testWave(.ima_adpcm, fact, "\x00\x00"));
    try std.testing.expectEqual(Wave.Format.ima_adpcm, adpcm.format);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), adpcm.seconds().?, 1e-9);

    try std.testing.expectError(error.NotAWave, Wave.parse("RIFF\x04\x00\x00\x00AVI "));
}
