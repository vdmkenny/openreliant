//! A minimal PNG writer, enough to save the game's indexed images.
//!
//! The game's sprites and textures are 8-bit indexed with one colour reserved for transparency,
//! which PNG represents directly as colour type 3 plus a `tRNS` chunk. Keeping the indices means
//! the output is the original data, not a re-quantised copy of it.
//!
//! Pixel data is deflated as stored blocks: no compression, but the result is a valid zlib stream
//! every reader accepts, and it keeps this file free of any dependency on a compressor.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const signature = "\x89PNG\r\n\x1a\n";

/// Largest payload a single stored deflate block can carry.
const stored_block_max = 0xFFFF;

pub const Options = struct {
    width: u32,
    height: u32,
    /// 256 RGB triples.
    palette: []const u8,
    /// Index rendered fully transparent, if any.
    transparent: ?u8 = null,
};

pub const Error = error{ DimensionsInvalid, PaletteInvalid, PixelCountMismatch };

/// Writes an 8-bit indexed PNG. `pixels` is `width * height` palette indices, row-major.
pub fn writeIndexed(
    gpa: Allocator,
    out: *Writer,
    options: Options,
    pixels: []const u8,
) (Error || Allocator.Error || Writer.Error)!void {
    if (options.width == 0 or options.height == 0) return error.DimensionsInvalid;
    if (options.palette.len != 256 * 3) return error.PaletteInvalid;
    if (pixels.len != @as(usize, options.width) * options.height) return error.PixelCountMismatch;

    try out.writeAll(signature);

    var header: [13]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], options.width, .big);
    std.mem.writeInt(u32, header[4..8], options.height, .big);
    header[8] = 8; // bits per sample
    header[9] = 3; // colour type: indexed
    header[10] = 0; // deflate
    header[11] = 0; // adaptive filtering
    header[12] = 0; // no interlace
    try writeChunk(out, "IHDR", &header);
    try writeChunk(out, "PLTE", options.palette);

    if (options.transparent) |index| {
        // Entries before the transparent one are opaque; the chunk can stop right after it.
        const alpha = try gpa.alloc(u8, @as(usize, index) + 1);
        defer gpa.free(alpha);
        @memset(alpha, 0xFF);
        alpha[index] = 0;
        try writeChunk(out, "tRNS", alpha);
    }

    // Each scanline is prefixed with its filter type, which is always "none" here.
    const raw = try gpa.alloc(u8, pixels.len + options.height);
    defer gpa.free(raw);
    for (0..options.height) |row| {
        const stride = options.width;
        raw[row * (stride + 1)] = 0;
        @memcpy(raw[row * (stride + 1) + 1 ..][0..stride], pixels[row * stride ..][0..stride]);
    }

    const deflated = try storedZlib(gpa, raw);
    defer gpa.free(deflated);
    try writeChunk(out, "IDAT", deflated);
    try writeChunk(out, "IEND", &.{});
}

fn writeChunk(out: *Writer, name: *const [4]u8, data: []const u8) Writer.Error!void {
    var length: [4]u8 = undefined;
    std.mem.writeInt(u32, &length, @intCast(data.len), .big);
    try out.writeAll(&length);
    try out.writeAll(name);
    try out.writeAll(data);

    var crc: std.hash.crc.Crc32 = .init();
    crc.update(name);
    crc.update(data);
    var checksum: [4]u8 = undefined;
    std.mem.writeInt(u32, &checksum, crc.final(), .big);
    try out.writeAll(&checksum);
}

/// Wraps `data` in a zlib stream made of stored deflate blocks.
fn storedZlib(gpa: Allocator, data: []const u8) Allocator.Error![]u8 {
    const block_count = @max(1, std.math.divCeil(usize, data.len, stored_block_max) catch unreachable);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, 2 + block_count * 5 + data.len + 4);

    // zlib header: deflate, 32 KiB window, default level, no preset dictionary.
    out.appendSliceAssumeCapacity(&.{ 0x78, 0x01 });

    var offset: usize = 0;
    while (true) {
        const len: u16 = @intCast(@min(data.len - offset, stored_block_max));
        const final = offset + len == data.len;
        out.appendAssumeCapacity(if (final) 1 else 0);
        var sizes: [4]u8 = undefined;
        std.mem.writeInt(u16, sizes[0..2], len, .little);
        std.mem.writeInt(u16, sizes[2..4], ~len, .little);
        out.appendSliceAssumeCapacity(&sizes);
        out.appendSliceAssumeCapacity(data[offset..][0..len]);
        offset += len;
        if (final) break;
    }

    var adler: [4]u8 = undefined;
    std.mem.writeInt(u32, &adler, std.hash.Adler32.hash(data), .big);
    out.appendSliceAssumeCapacity(&adler);
    return out.toOwnedSlice(gpa);
}

test "writes a readable indexed PNG" {
    const gpa = std.testing.allocator;
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();

    const palette = try gpa.alloc(u8, 256 * 3);
    defer gpa.free(palette);
    @memset(palette, 0);
    palette[3] = 0xFF; // index 1 is red

    const pixels = [_]u8{ 0, 1, 1, 0 };
    try writeIndexed(gpa, &buffer.writer, .{ .width = 2, .height = 2, .palette = palette, .transparent = 0 }, &pixels);

    const png = buffer.written();
    try std.testing.expectEqualSlices(u8, signature, png[0..8]);
    // IHDR, PLTE, tRNS, IDAT and IEND must all be present, in that order.
    var at: usize = 8;
    for ([_][]const u8{ "IHDR", "PLTE", "tRNS", "IDAT", "IEND" }) |name| {
        const length = std.mem.readInt(u32, png[at..][0..4], .big);
        try std.testing.expectEqualStrings(name, png[at + 4 ..][0..4]);
        at += 12 + length;
    }
    try std.testing.expectEqual(png.len, at);
}

test "rejects mismatched input" {
    const gpa = std.testing.allocator;
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    const palette = try gpa.alloc(u8, 256 * 3);
    defer gpa.free(palette);
    @memset(palette, 0);

    try std.testing.expectError(error.PixelCountMismatch, writeIndexed(
        gpa,
        &buffer.writer,
        .{ .width = 4, .height = 4, .palette = palette },
        &.{ 0, 0 },
    ));
    try std.testing.expectError(error.PaletteInvalid, writeIndexed(
        gpa,
        &buffer.writer,
        .{ .width = 1, .height = 1, .palette = &.{} },
        &.{0},
    ));
}
