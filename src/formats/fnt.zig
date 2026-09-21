//! `.fnt` fonts: WinVFX bitmap fonts.
//!
//! A font is a header, a table with one offset per character code, and one glyph per code: a width
//! and a raw `width x height` block of pixels, row by row. WinVFX reads the height at `+0x08`
//! (`VFX_font_height`), a glyph's width through the table (`VFX_character_width`), and draws its
//! pixels either as they are or through a remap table the caller supplies (`VFX_character_draw`).
//! Pixels are coverage levels, `0` for none up to `16` for full, so a remap table is what colours
//! the text.

const std = @import("std");
const assert = std.debug.assert;

pub const header_size = 0x10;

/// Bytes of the palette some fonts carry after their last glyph: 256 RGB triples of 6-bit levels.
pub const palette_size = 0x300;

/// Coverage of a fully inked pixel.
pub const full_coverage = 16;

/// The engine caches widths for character codes below this, so higher glyphs are never drawn
/// (`font_open`, `0x00480D70`).
pub const engine_limit = 0xFF;

pub const Error = error{ NotAFont, Truncated, BadGlyph };

pub const Header = extern struct {
    /// `2.` or `1.`, as raw bytes.
    version: [4]u8,
    /// Entries in the offset table.
    count: u32,
    /// Rows in every glyph.
    height: u32,
    /// **Unknown.** Nothing in WinVFX or the payload reads it.
    _unknown_0c: u32,

    comptime {
        assert(@sizeOf(Header) == header_size);
    }
};

pub const Glyph = struct {
    width: u32,
    height: u32,
    /// `width * height` coverage levels, row by row.
    pixels: []const u8,
};

pub const Font = struct {
    bytes: []const u8,
    header: *align(1) const Header,
    /// Offsets from the start of the file, one per character code; `0` for no glyph.
    offsets: []align(1) const u32,
    /// The trailing palette, when the file has one. **Unknown:** what reads it.
    palette: ?*const [palette_size]u8,

    pub fn parse(bytes: []const u8) Error!Font {
        if (bytes.len < header_size) return error.Truncated;
        const header: *align(1) const Header = @ptrCast(bytes[0..header_size]);
        const version = header.version;
        if (!std.ascii.isDigit(version[0]) or version[1] != '.' or version[2] != 0 or version[3] != 0) {
            return error.NotAFont;
        }

        const table_end = header_size + @as(usize, header.count) * 4;
        if (table_end > bytes.len) return error.Truncated;
        const offsets = std.mem.bytesAsSlice(u32, bytes[header_size..table_end]);

        // Every glyph must fit, and the last one's end tells whether a palette follows.
        var end = table_end;
        for (offsets) |offset| {
            if (offset == 0) continue;
            if (offset + 4 > bytes.len) return error.BadGlyph;
            const width = std.mem.readInt(u32, bytes[offset..][0..4], .little);
            const glyph_end = @as(usize, offset) + 4 + @as(usize, width) * header.height;
            if (glyph_end > bytes.len) return error.BadGlyph;
            end = @max(end, glyph_end);
        }
        const palette: ?*const [palette_size]u8 = if (bytes.len - end == palette_size)
            bytes[end..][0..palette_size]
        else
            null;

        return .{ .bytes = bytes, .header = header, .offsets = offsets, .palette = palette };
    }

    pub fn height(font: Font) u32 {
        return font.header.height;
    }

    /// The glyph for character code `code`, or null when the font has none.
    pub fn glyph(font: Font, code: usize) ?Glyph {
        if (code >= font.offsets.len) return null;
        const offset = font.offsets[code];
        if (offset == 0) return null;
        const width = std.mem.readInt(u32, font.bytes[offset..][0..4], .little);
        return .{
            .width = width,
            .height = font.header.height,
            .pixels = font.bytes[offset + 4 ..][0 .. @as(usize, width) * font.header.height],
        };
    }
};

pub const testing = struct {
    /// A font of two codes: 0 has no glyph, 1 is two pixels wide and two tall, with a palette
    /// after it or without.
    pub const font = testFont;
};

fn testFont(comptime with_palette: bool) []const u8 {
    // Two codes: 0 has no glyph, 1 is two pixels wide and two tall.
    const table_end = header_size + 2 * 4;
    const glyph = std.mem.toBytes(std.mem.nativeToLittle(u32, 2)) ++ [_]u8{ 0, 16, 8, 0 };
    const header = "2.\x00\x00" ++ std.mem.toBytes(std.mem.nativeToLittle(u32, 2)) ++
        std.mem.toBytes(std.mem.nativeToLittle(u32, 2)) ++ std.mem.toBytes(@as(u32, 0));
    const table = std.mem.toBytes(@as(u32, 0)) ++ std.mem.toBytes(std.mem.nativeToLittle(u32, table_end));
    const palette: [palette_size]u8 = @splat(0x3F);
    return header ++ table ++ glyph ++ (if (with_palette) palette else [0]u8{});
}

test Font {
    const font = try Font.parse(comptime testFont(false));
    try std.testing.expectEqual(@as(u32, 2), font.height());
    try std.testing.expectEqual(@as(?Glyph, null), font.glyph(0));
    const one = font.glyph(1).?;
    try std.testing.expectEqual(@as(u32, 2), one.width);
    try std.testing.expectEqualSlices(u8, &.{ 0, 16, 8, 0 }, one.pixels);
    try std.testing.expectEqual(@as(?Glyph, null), font.glyph(2));
    try std.testing.expect(font.palette == null);

    const coloured = try Font.parse(comptime testFont(true));
    try std.testing.expect(coloured.palette != null);

    try std.testing.expectError(error.NotAFont, Font.parse("1.40\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"));
}
