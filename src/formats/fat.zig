//! `.fat` sound banks: a table of RIFF/WAVE sounds packed into one file.
//!
//! The engine loads a whole bank into memory and plays entry `n` by handing Miles the WAVE file at
//! `bank + offset`. An entry's priority decides whether it may take over a voice that is already
//! playing: the player finds the busy voice of lowest priority and stops it only for a sound whose
//! priority is higher (`sound_play`, `0x00481F80`).

const std = @import("std");
const assert = std.debug.assert;

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

pub const header_size = 8;

pub const Bank = struct {
    bytes: []const u8,
    entries: []align(1) const Entry,

    pub fn parse(bytes: []const u8) Error!Bank {
        if (bytes.len < header_size or !std.mem.eql(u8, bytes[0..4], magic)) return error.NotABank;
        const count = std.mem.readInt(u32, bytes[4..8], .little);
        const table_end = header_size + @as(usize, count) * @sizeOf(Entry);
        if (table_end > bytes.len) return error.Truncated;

        const entries = std.mem.bytesAsSlice(Entry, bytes[header_size..table_end]);
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

    fn chunkOf(id: *const [4]u8) ?Chunk {
        const ids = std.StaticStringMap(Chunk).initComptime(.{
            .{ "fmt ", .fmt },
            .{ "fact", .fact },
            .{ "data", .data },
        });
        return ids.get(id);
    }

    pub fn parse(bytes: []const u8) error{NotAWave}!Wave {
        if (bytes.len < 12 or !std.mem.eql(u8, bytes[0..4], "RIFF") or !std.mem.eql(u8, bytes[8..12], "WAVE")) {
            return error.NotAWave;
        }
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

        var pos: usize = 12;
        while (pos + 8 <= bytes.len) {
            const id = bytes[pos..][0..4];
            const len = std.mem.readInt(u32, bytes[pos + 4 ..][0..4], .little);
            const start = pos + 8;
            if (start + len > bytes.len) return error.NotAWave;
            const body = bytes[start..][0..len];
            // Chunks are padded to an even length.
            pos = start + len + (len & 1);

            switch (chunkOf(id) orelse continue) {
                .fmt => {
                    if (body.len < 16) return error.NotAWave;
                    wave.format = @enumFromInt(std.mem.readInt(u16, body[0..2], .little));
                    wave.channels = std.mem.readInt(u16, body[2..4], .little);
                    wave.rate = std.mem.readInt(u32, body[4..8], .little);
                    wave.block_align = std.mem.readInt(u16, body[12..14], .little);
                    wave.bits = std.mem.readInt(u16, body[14..16], .little);
                    seen_format = true;
                },
                .fact => if (body.len >= 4) {
                    wave.frames = std.mem.readInt(u32, body[0..4], .little);
                },
                .data => wave.data = body,
            }
        }
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

fn testWave(comptime format: u16, comptime extra: []const u8, comptime data: []const u8) []const u8 {
    const fmt = std.mem.toBytes(std.mem.nativeToLittle(u16, format)) ++ // format
        std.mem.toBytes(std.mem.nativeToLittle(u16, 1)) ++ // channels
        std.mem.toBytes(std.mem.nativeToLittle(u32, 22050)) ++ // rate
        std.mem.toBytes(std.mem.nativeToLittle(u32, 44100)) ++ // bytes per second
        std.mem.toBytes(std.mem.nativeToLittle(u16, 2)) ++ // block align
        std.mem.toBytes(std.mem.nativeToLittle(u16, 16)); // bits
    const body = "WAVE" ++ "fmt " ++ std.mem.toBytes(std.mem.nativeToLittle(u32, fmt.len)) ++ fmt ++
        extra ++ "data" ++ std.mem.toBytes(std.mem.nativeToLittle(u32, data.len)) ++ data;
    return "RIFF" ++ std.mem.toBytes(std.mem.nativeToLittle(u32, body.len)) ++ body;
}

test Bank {
    const wave = comptime testWave(1, "", "\x00\x00\x01\x00");
    const entry: Entry = .{ .offset = header_size + @sizeOf(Entry), .size = wave.len, .priority = 50 };
    const file = magic ++ std.mem.toBytes(std.mem.nativeToLittle(u32, 1)) ++ std.mem.toBytes(entry) ++ wave;

    const bank = try Bank.parse(file);
    try std.testing.expectEqual(@as(usize, 1), bank.entries.len);
    try std.testing.expectEqual(@as(u32, 50), bank.entries[0].priority);
    try std.testing.expectEqualSlices(u8, wave, bank.sound(0).?);
    try std.testing.expectEqual(@as(?[]const u8, null), bank.sound(1));

    try std.testing.expectError(error.NotABank, Bank.parse("1.40\x00\x00\x00\x00"));
    try std.testing.expectError(error.Truncated, Bank.parse(magic ++ "\x09\x00\x00\x00"));
}

test Wave {
    const pcm = try Wave.parse(comptime testWave(1, "", "\x00\x00\x01\x00\x02\x00\x03\x00"));
    try std.testing.expectEqual(Wave.Format.pcm, pcm.format);
    try std.testing.expectEqual(@as(?u32, 4), pcm.frames);

    const fact = comptime "fact" ++ std.mem.toBytes(std.mem.nativeToLittle(u32, 4)) ++
        std.mem.toBytes(std.mem.nativeToLittle(u32, 22050));
    const adpcm = try Wave.parse(comptime testWave(0x11, fact, "\x00\x00"));
    try std.testing.expectEqual(Wave.Format.ima_adpcm, adpcm.format);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), adpcm.seconds().?, 1e-9);

    try std.testing.expectError(error.NotAWave, Wave.parse("RIFF\x04\x00\x00\x00AVI "));
}
