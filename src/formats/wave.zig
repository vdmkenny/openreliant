//! RIFF/WAVE sounds: the `.fat` banks' entries and the music in `music\`. The game hands them to
//! Miles whole, which plays them as they are; `Decoder` reads their frames for the port's mixer.
//!
//! The game's sounds are IMA ADPCM (format `0x11`) or PCM. An IMA ADPCM block starts with a
//! header for each channel, the block's first sample and the step index, then holds four bits a
//! sample, the channels taking turns every eight samples.

const std = @import("std");
const assert = std.debug.assert;

const layout = @import("layout.zig");

/// What a sound's WAVE header says.
pub const Wave = struct {
    format: Format,
    channels: u16,
    rate: u32,
    bits: u16,
    block_align: u16,
    /// For IMA ADPCM, the frames each block holds, from the format chunk's extension.
    frames_per_block: u16,
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

    /// What follows the common fields for IMA ADPCM: the extension's size, then the frames a block
    /// holds.
    pub const AdpcmExtension = extern struct {
        size: u16,
        frames_per_block: u16,
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
            .frames_per_block = 0,
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
                    if (layout.view(AdpcmExtension, body[@sizeOf(FormatChunk)..])) |extension| {
                        wave.frames_per_block = extension.frames_per_block;
                    } else |_| {}
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

    /// The frames the data holds: for IMA ADPCM, whole blocks and the part of the last, as far as
    /// the `fact` chunk allows.
    pub fn frameCount(wave: Wave) u32 {
        const held: u32 = switch (wave.format) {
            .ima_adpcm => blocks: {
                const whole: u32 = @intCast(wave.data.len / wave.block_align);
                const left = wave.data.len % wave.block_align;
                const header = 4 * @as(usize, wave.channels);
                const partial: u32 = if (left > header) @intCast(1 + (left - header) * 2 / wave.channels) else 0;
                break :blocks whole * wave.frames_per_block + partial;
            },
            else => @intCast(wave.data.len / wave.block_align),
        };
        return if (wave.frames) |stated| @min(stated, held) else held;
    }
};

/// Reads a wave's frames in order, as 16-bit samples, the one channel of a mono sound in both. IMA
/// ADPCM is decoded as it goes, a block at a time, with no buffer of its own.
pub const Decoder = struct {
    wave: Wave,
    frames: u32,
    /// The next frame's index.
    frame: u32 = 0,
    /// IMA ADPCM's running state for each channel, which each block's header resets.
    predictor: [2]i32 = .{ 0, 0 },
    step_index: [2]u8 = .{ 0, 0 },

    pub const Error = error{Unsupported};

    pub fn init(wave: Wave) Error!Decoder {
        if (wave.channels != 1 and wave.channels != 2) return error.Unsupported;
        if (wave.block_align == 0) return error.Unsupported;
        switch (wave.format) {
            .pcm => if (wave.bits != 8 and wave.bits != 16 or wave.block_align != wave.channels * wave.bits / 8) return error.Unsupported,
            .ima_adpcm => {
                if (wave.bits != 4 or wave.block_align <= 4 * wave.channels) return error.Unsupported;
                // A block holds its header's sample and two a byte of the rest.
                const holds = (wave.block_align - 4 * wave.channels) * 2 / wave.channels + 1;
                if (wave.frames_per_block != holds) return error.Unsupported;
            },
            _ => return error.Unsupported,
        }
        return .{ .wave = wave, .frames = wave.frameCount() };
    }

    /// The next frame, left and right, or null past the last.
    pub fn next(decoder: *Decoder) ?[2]i16 {
        if (decoder.frame >= decoder.frames) return null;
        const wave = decoder.wave;
        const channels = wave.channels;
        var out: [2]i16 = undefined;
        switch (wave.format) {
            .pcm => {
                const at = @as(usize, decoder.frame) * wave.block_align;
                for (0..channels) |c| out[c] = if (wave.bits == 8)
                    (@as(i16, wave.data[at + c]) - 128) << 8
                else
                    std.mem.readInt(i16, wave.data[at + 2 * c ..][0..2], .little);
            },
            .ima_adpcm => {
                const in_block = decoder.frame % wave.frames_per_block;
                const block = wave.data[@as(usize, decoder.frame / wave.frames_per_block) * wave.block_align ..];
                for (0..channels) |c| {
                    if (in_block == 0) {
                        const header = block[4 * c ..][0..4];
                        decoder.predictor[c] = std.mem.readInt(i16, header[0..2], .little);
                        decoder.step_index[c] = @min(header[2], max_step_index);
                    } else {
                        // Eight samples of each channel in turn, four bytes each, low nibble first.
                        const n = in_block - 1;
                        const byte = block[4 * channels + (n / 8) * 4 * channels + 4 * c + (n % 8) / 2];
                        const nibble: u4 = @truncate(if (n % 2 == 0) byte else byte >> 4);
                        decoder.decodeNibble(c, nibble);
                    }
                    out[c] = @intCast(decoder.predictor[c]);
                }
            },
            _ => unreachable,
        }
        if (channels == 1) out[1] = out[0];
        decoder.frame += 1;
        return out;
    }

    /// Moves to `frame`, decoding from the start of its block for IMA ADPCM.
    pub fn seek(decoder: *Decoder, frame: u32) void {
        const target = @min(frame, decoder.frames);
        switch (decoder.wave.format) {
            .ima_adpcm => {
                decoder.frame = target - target % decoder.wave.frames_per_block;
                while (decoder.frame < target) _ = decoder.next();
            },
            else => decoder.frame = target,
        }
    }

    /// IMA ADPCM's step for one sample: the difference the nibble's three bits add up to, of the
    /// step and its halves, signed by its fourth.
    fn decodeNibble(decoder: *Decoder, channel: usize, nibble: u4) void {
        const step: i32 = steps[decoder.step_index[channel]];
        var difference = step >> 3;
        if (nibble & 4 != 0) difference += step;
        if (nibble & 2 != 0) difference += step >> 1;
        if (nibble & 1 != 0) difference += step >> 2;
        if (nibble & 8 != 0) difference = -difference;
        decoder.predictor[channel] = std.math.clamp(decoder.predictor[channel] + difference, std.math.minInt(i16), std.math.maxInt(i16));
        const moved = @as(i32, decoder.step_index[channel]) + index_moves[nibble & 7];
        decoder.step_index[channel] = @intCast(std.math.clamp(moved, 0, max_step_index));
    }

    const max_step_index = steps.len - 1;

    /// IMA ADPCM's step sizes, as the format defines them.
    const steps = [89]u16{
        7,     8,     9,     10,    11,    12,    13,    14,    16,    17,
        19,    21,    23,    25,    28,    31,    34,    37,    41,    45,
        50,    55,    60,    66,    73,    80,    88,    97,    107,   118,
        130,   143,   157,   173,   190,   209,   230,   253,   279,   307,
        337,   371,   408,   449,   494,   544,   598,   658,   724,   796,
        876,   963,   1060,  1166,  1282,  1411,  1552,  1707,  1878,  2066,
        2272,  2499,  2749,  3024,  3327,  3660,  4026,  4428,  4871,  5358,
        5894,  6484,  7132,  7845,  8630,  9493,  10442, 11487, 12635, 13899,
        15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767,
    };

    /// How far each magnitude moves the step index.
    const index_moves = [8]i8{ -1, -1, -1, -1, 2, 4, 6, 8 };
};

/// Builds WAVE files for tests.
pub const testing = struct {
    /// A chunk of `body`, with its header.
    pub fn chunk(comptime id: *const [4]u8, comptime body: []const u8) []const u8 {
        return std.mem.toBytes(Wave.ChunkHeader{ .id = id.*, .size = body.len }) ++ body;
    }

    /// A WAVE file of `format`, its format chunk `fmt` (and `extension`), then `extra` chunks
    /// before the data.
    pub fn file(comptime fmt: Wave.FormatChunk, comptime extension: []const u8, comptime extra: []const u8, comptime data: []const u8) []const u8 {
        const body = "WAVE" ++ chunk("fmt ", &std.mem.toBytes(fmt) ++ extension) ++ extra ++ chunk("data", data);
        return "RIFF" ++ std.mem.toBytes(@as(u32, body.len)) ++ body;
    }

    /// Mono 16-bit PCM at 22,050 Hz.
    pub fn pcm(comptime data: []const u8) []const u8 {
        return file(.{ .format = .pcm, .channels = 1, .rate = 22050, .byte_rate = 44100, .block_align = 2, .bits = 16 }, "", "", data);
    }
};

test Wave {
    const pcm = try Wave.parse(comptime testing.pcm("\x00\x00\x01\x00\x02\x00\x03\x00"));
    try std.testing.expectEqual(Wave.Format.pcm, pcm.format);
    try std.testing.expectEqual(@as(?u32, 4), pcm.frames);
    try std.testing.expectEqual(4, pcm.frameCount());

    const fact = comptime testing.chunk("fact", &std.mem.toBytes(@as(u32, 22050)));
    const adpcm = try Wave.parse(comptime testing.file(
        .{ .format = .ima_adpcm, .channels = 1, .rate = 22050, .byte_rate = 11100, .block_align = 256, .bits = 4 },
        &std.mem.toBytes(Wave.AdpcmExtension{ .size = 2, .frames_per_block = 505 }),
        fact,
        "\x00\x00",
    ));
    try std.testing.expectEqual(Wave.Format.ima_adpcm, adpcm.format);
    try std.testing.expectEqual(505, adpcm.frames_per_block);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), adpcm.seconds().?, 1e-9);

    try std.testing.expectError(error.NotAWave, Wave.parse("RIFF\x04\x00\x00\x00AVI "));
}

test "Decoder reads PCM" {
    var decoder: Decoder = try .init(try Wave.parse(comptime testing.pcm("\x00\x00\x01\x00\xff\xff")));
    try std.testing.expectEqual([2]i16{ 0, 0 }, decoder.next().?);
    try std.testing.expectEqual([2]i16{ 1, 1 }, decoder.next().?);
    try std.testing.expectEqual([2]i16{ -1, -1 }, decoder.next().?);
    try std.testing.expectEqual(null, decoder.next());
    decoder.seek(1);
    try std.testing.expectEqual([2]i16{ 1, 1 }, decoder.next().?);

    // Eight-bit samples are unsigned, around 128.
    const eight = comptime testing.file(.{ .format = .pcm, .channels = 1, .rate = 11025, .byte_rate = 11025, .block_align = 1, .bits = 8 }, "", "", "\x80\xff\x00");
    var bytes: Decoder = try .init(try Wave.parse(eight));
    try std.testing.expectEqual([2]i16{ 0, 0 }, bytes.next().?);
    try std.testing.expectEqual([2]i16{ 127 << 8, 127 << 8 }, bytes.next().?);
    try std.testing.expectEqual([2]i16{ -128 << 8, -128 << 8 }, bytes.next().?);
}

test "Decoder reads IMA ADPCM" {
    // One mono block of 9 frames: the header's sample, 100, at step index 0, then 0x7, 0x7 and
    // 0xF: 7 adds the step and both its halves, 0xF takes them away, and each 7 raises the index
    // by 8.
    const block = [_]u8{ 100, 0, 0, 0, 0x77, 0x0F, 0x00, 0x00 };
    const fmt: Wave.FormatChunk = .{ .format = .ima_adpcm, .channels = 1, .rate = 22050, .byte_rate = 22050, .block_align = block.len, .bits = 4 };
    const file = comptime testing.file(fmt, &std.mem.toBytes(Wave.AdpcmExtension{ .size = 2, .frames_per_block = 9 }), "", &block);
    var decoder: Decoder = try .init(try Wave.parse(file));
    try std.testing.expectEqual(9, decoder.frames);
    try std.testing.expectEqual(100, decoder.next().?[0]);
    try std.testing.expectEqual(111, decoder.next().?[0]);
    try std.testing.expectEqual(141, decoder.next().?[0]);
    try std.testing.expectEqual(78, decoder.next().?[0]);
    // Seeking starts again from the block's header.
    decoder.seek(2);
    try std.testing.expectEqual(141, decoder.next().?[0]);

    // A block too short for its frames is refused.
    const short = comptime testing.file(fmt, &std.mem.toBytes(Wave.AdpcmExtension{ .size = 2, .frames_per_block = 505 }), "", &block);
    try std.testing.expectError(error.Unsupported, Decoder.init(try Wave.parse(short)));
}

test "Decoder takes the channels of IMA ADPCM in turn" {
    // A stereo block: both headers, then four bytes of the left, four of the right. The left
    // steps up by 11, the right down.
    const block = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 } ++ [_]u8{ 0x07, 0, 0, 0 } ++ [_]u8{ 0x0F, 0, 0, 0 };
    const fmt: Wave.FormatChunk = .{ .format = .ima_adpcm, .channels = 2, .rate = 22050, .byte_rate = 22050, .block_align = block.len, .bits = 4 };
    const file = comptime testing.file(fmt, &std.mem.toBytes(Wave.AdpcmExtension{ .size = 2, .frames_per_block = 9 }), "", &block);
    var decoder: Decoder = try .init(try Wave.parse(file));
    try std.testing.expectEqual([2]i16{ 0, 0 }, decoder.next().?);
    try std.testing.expectEqual([2]i16{ 11, -11 }, decoder.next().?);
}
