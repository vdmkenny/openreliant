//! Truevision TGA images: the header, a palette image's colour map, and the pixels.
//!
//! The engine's palettes are the colour maps of 8-bit colour-mapped TGA files in `resource.hog`:
//! `palette.tga`, `softpal.tga` and `palette3.tga`. `SR_TGA_allocate_palette` (`0x004CACB0`)
//! loads one and `SR_TGA_get_palette` (`0x004CA9B0`) copies out its colour map; the image under it
//! is not used. `SR_TGA_allocate_raw` (`0x004CABE0`) reads an image's pixels, top row first, for
//! the star map and the sky dome's colours.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const header_size = 18;

/// Colours in a palette.
pub const palette_length = 256;

/// Red, green and blue, 8 bits each.
pub const Palette = [palette_length][3]u8;

pub const ImageType = enum(u8) {
    none = 0,
    color_mapped = 1,
    true_color = 2,
    grayscale = 3,
    rle_color_mapped = 9,
    rle_true_color = 10,
    rle_grayscale = 11,
    _,
};

pub const Descriptor = packed struct(u8) {
    alpha_bits: u4,
    right_to_left: bool,
    top_to_bottom: bool,
    _reserved: u2,
};

pub const Header = struct {
    id_length: u8,
    /// `1` when a colour map follows the image ID.
    color_map_type: u8,
    image_type: ImageType,
    color_map_first: u16,
    color_map_length: u16,
    color_map_entry_bits: u8,
    x_origin: u16,
    y_origin: u16,
    width: u16,
    height: u16,
    pixel_bits: u8,
    descriptor: Descriptor,

    pub fn parse(bytes: *const [header_size]u8) Header {
        return .{
            .id_length = bytes[0],
            .color_map_type = bytes[1],
            .image_type = @enumFromInt(bytes[2]),
            .color_map_first = std.mem.readInt(u16, bytes[3..5], .little),
            .color_map_length = std.mem.readInt(u16, bytes[5..7], .little),
            .color_map_entry_bits = bytes[7],
            .x_origin = std.mem.readInt(u16, bytes[8..10], .little),
            .y_origin = std.mem.readInt(u16, bytes[10..12], .little),
            .width = std.mem.readInt(u16, bytes[12..14], .little),
            .height = std.mem.readInt(u16, bytes[14..16], .little),
            .pixel_bits = bytes[16],
            .descriptor = @bitCast(bytes[17]),
        };
    }

    /// Where the colour map starts: after the header and the image ID.
    pub fn colorMapOffset(header: Header) usize {
        return header_size + @as(usize, header.id_length);
    }
};

pub const Error = error{ Truncated, NotColorMapped, UnsupportedColorMap, UnsupportedImage };

/// The palette of a colour-mapped image, as `SR_TGA_get_palette` reads it: the first 256 entries of
/// its colour map, stored blue, green, red.
pub fn palette(bytes: []const u8) Error!Palette {
    if (bytes.len < header_size) return error.Truncated;
    const header: Header = .parse(bytes[0..header_size]);
    switch (header.image_type) {
        .color_mapped, .rle_color_mapped => {},
        else => return error.NotColorMapped,
    }
    if (header.color_map_type != 1) return error.NotColorMapped;
    if (header.color_map_entry_bits != 24 or header.color_map_first != 0 or
        header.color_map_length < palette_length) return error.UnsupportedColorMap;

    const start = header.colorMapOffset();
    if (bytes.len < start + palette_length * 3) return error.Truncated;
    var result: Palette = undefined;
    for (&result, 0..) |*colour, i| {
        const entry = bytes[start + i * 3 ..][0..3];
        colour.* = .{ entry[2], entry[1], entry[0] };
    }
    return result;
}

/// An image's pixels as red, green and blue, row by row from the top.
pub const Image = struct {
    width: u16,
    height: u16,
    rgb: []u8,

    pub fn pixel(image: Image, x: usize, y: usize) [3]u8 {
        return image.rgb[(y * image.width + x) * 3 ..][0..3].*;
    }

    pub fn deinit(image: Image, gpa: Allocator) void {
        gpa.free(image.rgb);
    }
};

/// The pixels of a true-colour image of 24 or 32 bits, uncompressed or run-length encoded, or of an
/// 8-bit colour-mapped one. Alpha is dropped.
pub fn decode(gpa: Allocator, bytes: []const u8) (Error || Allocator.Error)!Image {
    if (bytes.len < header_size) return error.Truncated;
    const header: Header = .parse(bytes[0..header_size]);
    const encoded = switch (header.image_type) {
        .color_mapped, .true_color => false,
        .rle_color_mapped, .rle_true_color => true,
        else => return error.UnsupportedImage,
    };
    const colour_mapped = header.image_type == .color_mapped or header.image_type == .rle_color_mapped;
    const map: ?Palette = if (colour_mapped) try palette(bytes) else null;
    const bytes_per_pixel: usize = switch (header.pixel_bits) {
        8 => if (colour_mapped) 1 else return error.UnsupportedImage,
        24 => if (colour_mapped) return error.UnsupportedImage else 3,
        32 => if (colour_mapped) return error.UnsupportedImage else 4,
        else => return error.UnsupportedImage,
    };
    if (header.descriptor.right_to_left) return error.UnsupportedImage;

    var at = header.colorMapOffset();
    if (header.color_map_type == 1) at += @as(usize, header.color_map_length) * ((@as(usize, header.color_map_entry_bits) + 7) / 8);
    const count = @as(usize, header.width) * header.height;
    const rgb = try gpa.alloc(u8, count * 3);
    errdefer gpa.free(rgb);

    // Pixels come in file order, bottom row first unless the descriptor says otherwise.
    var written: usize = 0;
    while (written < count) {
        var run: usize = 1;
        var repeat = false;
        if (encoded) {
            if (at >= bytes.len) return error.Truncated;
            run = (bytes[at] & 0x7F) + 1;
            repeat = bytes[at] & 0x80 != 0;
            at += 1;
        }
        if (written + run > count) return error.Truncated;
        for (0..run) |i| {
            const source = if (repeat) at else at + i * bytes_per_pixel;
            if (source + bytes_per_pixel > bytes.len) return error.Truncated;
            const colour: [3]u8 = if (map) |m| m[bytes[source]] else .{ bytes[source + 2], bytes[source + 1], bytes[source] };
            const file_row = (written + i) / header.width;
            const row = if (header.descriptor.top_to_bottom) file_row else header.height - 1 - file_row;
            const column = (written + i) % header.width;
            rgb[(row * header.width + column) * 3 ..][0..3].* = colour;
        }
        at += if (repeat) bytes_per_pixel else run * bytes_per_pixel;
        written += run;
    }
    return .{ .width = header.width, .height = header.height, .rgb = rgb };
}

/// A colour-mapped image with a 256-entry map in which entry `i` is `(i, i + 1, i + 2)`, and a
/// 1x1 image.
fn testImage(buffer: []u8, id: []const u8) []u8 {
    const header = [header_size]u8{
        @intCast(id.len), 1, 1, // ID length, colour map type, image type
        0, 0, 0, 1, 24, // colour map: first 0, length 256, 24 bits
        0, 0, 0, 0, // origin
        1, 0, 1, 0, // 1x1
        8, 0x20, // 8 bits per pixel, top to bottom
    };
    @memcpy(buffer[0..header_size], &header);
    @memcpy(buffer[header_size..][0..id.len], id);
    const map = buffer[header_size + id.len ..][0 .. palette_length * 3];
    for (0..palette_length) |i| {
        map[i * 3 + 0] = @truncate(i + 2); // blue
        map[i * 3 + 1] = @truncate(i + 1); // green
        map[i * 3 + 2] = @truncate(i); // red
    }
    const end = header_size + id.len + palette_length * 3;
    buffer[end] = 0;
    return buffer[0 .. end + 1];
}

test Header {
    var buffer: [1024]u8 = undefined;
    const image = testImage(&buffer, "id");
    const header: Header = .parse(image[0..header_size]);
    try std.testing.expectEqual(ImageType.color_mapped, header.image_type);
    try std.testing.expectEqual(256, header.color_map_length);
    try std.testing.expectEqual(1, header.width);
    try std.testing.expect(header.descriptor.top_to_bottom);
    try std.testing.expect(!header.descriptor.right_to_left);
    try std.testing.expectEqual(header_size + 2, header.colorMapOffset());
}

test palette {
    var buffer: [1024]u8 = undefined;
    const image = testImage(&buffer, "palette");
    const colours = try palette(image);
    try std.testing.expectEqual([3]u8{ 0, 1, 2 }, colours[0]);
    try std.testing.expectEqual([3]u8{ 255, 0, 1 }, colours[255]);

    try std.testing.expectError(error.Truncated, palette(image[0 .. image.len - 100]));
    try std.testing.expectError(error.Truncated, palette(image[0..10]));

    var true_color = buffer;
    true_color[2] = 2;
    try std.testing.expectError(error.NotColorMapped, palette(&true_color));
    var small_entries = buffer;
    small_entries[7] = 16;
    try std.testing.expectError(error.UnsupportedColorMap, palette(&small_entries));
}

test decode {
    const gpa = std.testing.allocator;
    // A 2x2 true-colour image, bottom row first: blue, green, then red, white.
    const plain = [_]u8{ 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 2, 0, 24, 0 } ++
        [_]u8{ 0xFF, 0, 0, 0, 0xFF, 0 } ++ [_]u8{ 0, 0, 0xFF, 0xFF, 0xFF, 0xFF };
    const image = try decode(gpa, &plain);
    defer image.deinit(gpa);
    try std.testing.expectEqual([3]u8{ 255, 0, 0 }, image.pixel(0, 0));
    try std.testing.expectEqual([3]u8{ 255, 255, 255 }, image.pixel(1, 0));
    try std.testing.expectEqual([3]u8{ 0, 0, 255 }, image.pixel(0, 1));
    try std.testing.expectEqual([3]u8{ 0, 255, 0 }, image.pixel(1, 1));

    // The same pixels run-length encoded, top row first: a run of two reds, then two raw pixels.
    const rle = [_]u8{ 0, 0, 10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 2, 0, 24, 0x20 } ++
        [_]u8{ 0x81, 0, 0, 0xFF } ++ [_]u8{ 0x01, 0xFF, 0, 0, 0, 0xFF, 0 };
    const encoded = try decode(gpa, &rle);
    defer encoded.deinit(gpa);
    try std.testing.expectEqual([3]u8{ 255, 0, 0 }, encoded.pixel(1, 0));
    try std.testing.expectEqual([3]u8{ 0, 0, 255 }, encoded.pixel(0, 1));
    try std.testing.expectEqual([3]u8{ 0, 255, 0 }, encoded.pixel(1, 1));

    try std.testing.expectError(error.Truncated, decode(gpa, rle[0 .. rle.len - 1]));
    var mapped: [1024]u8 = undefined;
    const indexed = try decode(gpa, testImage(&mapped, ""));
    defer indexed.deinit(gpa);
    try std.testing.expectEqual([3]u8{ 0, 1, 2 }, indexed.pixel(0, 0));
}
