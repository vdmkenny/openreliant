//! RefPack, the Electronic Arts LZ77 variant that compresses most members of a `.hog` archive.
//!
//! Also called QFS, and named FB10 after the two bytes its header starts with. A stream is a
//! sequence of commands, each of which copies a short run of literal bytes from the input and then
//! optionally repeats a run that already appeared in the output. Four command encodings cover
//! progressively longer matches, and a fifth ends the stream.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The second header byte. The first carries flags, so the pair is the format's signature.
pub const signature: u8 = 0xFB;

pub const Header = struct {
    flags: Flags,
    /// Present only when `flags.compressed_size_present`.
    compressed_size: ?u32,
    decompressed_size: u32,
    /// Bytes the header occupies.
    len: usize,

    pub const Flags = packed struct(u8) {
        /// Sizes are 4 bytes rather than 3.
        compressed_size_present: bool,
        _unused: u3,
        /// Set on every stream seen in this game; part of the signature in practice.
        magic: u1,
        _unused2: u2,
        /// Sizes are 4 bytes rather than 3.
        wide_sizes: bool,
    };

    pub fn sizeWidth(header: Header) usize {
        return if (header.flags.wide_sizes) 4 else 3;
    }
};

pub const Error = error{
    /// The stream does not start with a RefPack header.
    BadSignature,
    /// A command runs past the end of the input.
    UnexpectedEnd,
    /// A back-reference points before the start of the output.
    BadReference,
    /// The commands produced a different amount of data than the header promised.
    SizeMismatch,
};

/// Reads the header at the start of `data`.
pub fn readHeader(data: []const u8) Error!Header {
    if (data.len < 2 or data[1] != signature) return error.BadSignature;
    const flags: Header.Flags = @bitCast(data[0]);

    const width: usize = if (flags.wide_sizes) 4 else 3;
    var pos: usize = 2;

    var compressed_size: ?u32 = null;
    if (flags.compressed_size_present) {
        if (data.len < pos + width) return error.UnexpectedEnd;
        compressed_size = readBigEndian(data[pos..][0..width]);
        pos += width;
    }
    if (data.len < pos + width) return error.UnexpectedEnd;
    const decompressed_size = readBigEndian(data[pos..][0..width]);
    pos += width;

    return .{
        .flags = flags,
        .compressed_size = compressed_size,
        .decompressed_size = decompressed_size,
        .len = pos,
    };
}

fn readBigEndian(bytes: []const u8) u32 {
    var value: u32 = 0;
    for (bytes) |b| value = (value << 8) | b;
    return value;
}

/// True when `data` begins with a RefPack header.
pub fn looksCompressed(data: []const u8) bool {
    return data.len >= 2 and data[1] == signature;
}

/// One decoded command: copy `literals` bytes straight through, then repeat `match_len` bytes
/// from `match_distance` back in the output.
const Command = struct {
    literals: usize,
    match_len: usize,
    match_distance: usize,
    last: bool,

    /// Decodes the command at the start of `input`, returning it and its encoded length.
    fn decode(input: []const u8) Error!struct { Command, usize } {
        if (input.len < 1) return error.UnexpectedEnd;
        const b0 = input[0];

        // Short match: 2 bytes, distances up to 1024 and matches of 3 to 10.
        if (b0 < 0x80) {
            if (input.len < 2) return error.UnexpectedEnd;
            const b1 = input[1];
            return .{ .{
                .literals = b0 & 0x03,
                .match_len = ((b0 & 0x1C) >> 2) + 3,
                .match_distance = (@as(usize, b0 & 0x60) << 3) + b1 + 1,
                .last = false,
            }, 2 };
        }

        // Medium match: 3 bytes, distances up to 16384 and matches of 4 to 67.
        if (b0 < 0xC0) {
            if (input.len < 3) return error.UnexpectedEnd;
            const b1 = input[1];
            const b2 = input[2];
            return .{ .{
                .literals = (b1 >> 6) & 0x03,
                .match_len = (b0 & 0x3F) + 4,
                .match_distance = (@as(usize, b1 & 0x3F) << 8) + b2 + 1,
                .last = false,
            }, 3 };
        }

        // Long match: 4 bytes, distances up to 131072 and matches of 5 to 1028.
        if (b0 < 0xE0) {
            if (input.len < 4) return error.UnexpectedEnd;
            const b1 = input[1];
            const b2 = input[2];
            const b3 = input[3];
            return .{ .{
                .literals = b0 & 0x03,
                .match_len = (@as(usize, b0 & 0x0C) << 6) + b3 + 5,
                .match_distance = (@as(usize, b0 & 0x10) << 12) + (@as(usize, b1) << 8) + b2 + 1,
                .last = false,
            }, 4 };
        }

        // Literal run of 4 to 112 bytes, in multiples of four. No match follows.
        if (b0 < 0xFC) {
            return .{ .{
                .literals = (@as(usize, b0 & 0x1F) << 2) + 4,
                .match_len = 0,
                .match_distance = 0,
                .last = false,
            }, 1 };
        }

        // End of stream, with up to three trailing literals.
        return .{ .{
            .literals = b0 & 0x03,
            .match_len = 0,
            .match_distance = 0,
            .last = true,
        }, 1 };
    }
};

/// Decompresses a complete RefPack stream, header included.
pub fn decompressAlloc(gpa: Allocator, stream: []const u8) (Error || Allocator.Error)![]u8 {
    const header = try readHeader(stream);
    const out = try gpa.alloc(u8, header.decompressed_size);
    errdefer gpa.free(out);
    const written = try decompressInto(out, stream[header.len..]);
    if (written != out.len) return error.SizeMismatch;
    return out;
}

/// Decompresses the command stream in `input` into `out`, returning the number of bytes written.
/// `input` starts after the header.
pub fn decompressInto(out: []u8, input: []const u8) Error!usize {
    var in_pos: usize = 0;
    var out_pos: usize = 0;

    while (true) {
        const command, const encoded_len = try Command.decode(input[in_pos..]);
        in_pos += encoded_len;

        if (input.len - in_pos < command.literals) return error.UnexpectedEnd;
        if (out.len - out_pos < command.literals) return error.SizeMismatch;
        @memcpy(out[out_pos..][0..command.literals], input[in_pos..][0..command.literals]);
        in_pos += command.literals;
        out_pos += command.literals;

        if (command.last) return out_pos;

        if (command.match_distance > out_pos) return error.BadReference;
        if (out.len - out_pos < command.match_len) return error.SizeMismatch;
        // Runs may overlap their own output, so copy one byte at a time rather than @memcpy.
        var source = out_pos - command.match_distance;
        for (0..command.match_len) |_| {
            out[out_pos] = out[source];
            out_pos += 1;
            source += 1;
        }
    }
}

test readHeader {
    const header = try readHeader(&.{ 0x10, 0xFB, 0x08, 0xB5, 0xA8 });
    try std.testing.expectEqual(@as(u32, 0x08B5A8), header.decompressed_size);
    try std.testing.expectEqual(@as(?u32, null), header.compressed_size);
    try std.testing.expectEqual(@as(usize, 5), header.len);
    try std.testing.expect(!header.flags.wide_sizes);

    // With a compressed size, and with wide sizes.
    const with_both = try readHeader(&.{ 0x81, 0xFB, 0, 0, 0x10, 0x00, 0, 0, 0x20, 0x00 });
    try std.testing.expectEqual(@as(?u32, 0x1000), with_both.compressed_size);
    try std.testing.expectEqual(@as(u32, 0x2000), with_both.decompressed_size);
    try std.testing.expectEqual(@as(usize, 10), with_both.len);

    try std.testing.expectError(error.BadSignature, readHeader(&.{ 0x10, 0x00, 0, 0, 0 }));
    try std.testing.expectError(error.BadSignature, readHeader(&.{0x10}));
}

test "literal run then end" {
    // 0xE0: four literals. 0xFC: end with no trailing literals.
    var out: [4]u8 = undefined;
    const written = try decompressInto(&out, &.{ 0xE0, 'a', 'b', 'c', 'd', 0xFC });
    try std.testing.expectEqual(@as(usize, 4), written);
    try std.testing.expectEqualStrings("abcd", &out);
}

test "short match repeats earlier output" {
    // 0xE0 -> 4 literals "abcd"; then a short match: b0=0x04 gives 0 literals and length
    // ((0x04 & 0x1C) >> 2) + 3 = 4, b1=3 gives distance 4; then 0xFC ends.
    var out: [8]u8 = undefined;
    const written = try decompressInto(&out, &.{ 0xE0, 'a', 'b', 'c', 'd', 0x04, 0x03, 0xFC });
    try std.testing.expectEqual(@as(usize, 8), written);
    try std.testing.expectEqualStrings("abcdabcd", &out);
}

test "overlapping match extends a run" {
    // A distance of one repeats the previous byte, so the copy reads bytes it is still writing.
    // b0 = 0x01: one literal, match length ((0x01 & 0x1C) >> 2) + 3 = 3, b1 = 0 -> distance 1.
    // 0xFE ends the stream with two trailing literals.
    var out: [6]u8 = undefined;
    const written = try decompressInto(&out, &.{ 0x01, 0x00, 'x', 0xFE, 'y', 'z' });
    try std.testing.expectEqual(@as(usize, 6), written);
    try std.testing.expectEqualStrings("xxxxyz", &out);
}

test "truncated input is rejected" {
    var out: [16]u8 = undefined;
    try std.testing.expectError(error.UnexpectedEnd, decompressInto(&out, &.{0xE0}));
    try std.testing.expectError(error.UnexpectedEnd, decompressInto(&out, &.{0x04}));
    // A match reaching before the start of the output.
    try std.testing.expectError(error.BadReference, decompressInto(&out, &.{ 0x00, 0x00, 0xFC }));
}

test "round-trips a real stream shape" {
    const gpa = std.testing.allocator;
    // "abcdabcdabcd" as header + two commands.
    const stream = [_]u8{ 0x10, 0xFB, 0x00, 0x00, 0x0C, 0xE0, 'a', 'b', 'c', 'd', 0x14, 0x03, 0xFC };
    const out = try decompressAlloc(gpa, &stream);
    defer gpa.free(out);
    try std.testing.expectEqualStrings("abcdabcdabcd", out);
}
