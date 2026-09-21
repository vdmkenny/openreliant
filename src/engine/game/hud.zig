//! `C:\lancer\game\hud.cpp`: the head-up display drawn over the view. `hud_draw` (`0x004843B0`)
//! draws it once a frame; `mission_run` puts it in `sr + 0x88` and Surrender calls it while it
//! renders. [`hud.md`](../../../docs/engine/hud.md) describes the file.
//!
//! Ported so far: where an element stands, and the width and alignment of a line of its text.
//! Not yet: `hud_draw` itself, and the drawing, which goes through `vfx.dll`'s panes.

const std = @import("std");
const assert = std.debug.assert;

const fnt = @import("../../formats/fnt.zig");
const math = @import("../surrender/math.zig");

/// What `hud_place` takes off the screen's size before working a place out, and what it adds back
/// afterwards. An element therefore keeps its place at any resolution.
const inset: i32 = 0x21;
const margin: i32 = 0x10;

/// Where an element stands, for a fraction of the screen across and down and an offset in pixels
/// (`hud_place`, `0x00482E90`). `screen` is the screen's size, which the engine keeps at
/// `sr + 0x1666` and `sr + 0x166A`.
pub fn place(screen: [2]u32, offset: [2]i32, across: f32, down: f32) [2]i32 {
    var at: [2]i32 = undefined;
    for (&at, screen, offset, [2]f32{ across, down }) |*out, size, from, fraction| {
        const span: f32 = @floatFromInt(@as(i32, @intCast(size)) - inset);
        out.* = round(span * fraction) + from + margin;
    }
    return at;
}

/// How far apart the items of the display's grid stand, and where its first one does
/// (`hud_grid_place`, `0x00482F00`).
pub const grid_across: i32 = 0x30;
pub const grid_down: i32 = 0x26;
pub const grid_offset: [2]i32 = .{ -156, 0 };

/// Where the item of `index` stands in the grid: from half-way across the screen, two to a row.
pub fn gridPlace(screen: [2]u32, index: i32) [2]i32 {
    var at = place(screen, grid_offset, 0.5, 0);
    at[0] += @rem(index, 2) * grid_across;
    at[1] += @divTrunc(index, 2) * grid_down;
    return at;
}

/// A float turned into an integer the way the engine's `0x004C3330` does, with the rounding the
/// x87 is left in: to the nearest, and to the even one of a tie.
fn round(value: f32) i32 {
    return @intFromFloat(math.roundEven(value));
}

/// The character codes `font_open` caches the widths of. A glyph of a higher code is never drawn.
pub const cached_codes = fnt.engine_limit;

/// A font as the display draws with it (`font_open`, `0x00480D70`): the font, and the width of
/// every code it caches, which is every code below `cached_codes` that the font has a glyph for.
pub const Opened = struct {
    font: fnt.Font,
    widths: [cached_codes]u16,

    /// Takes the widths out of `font`, as `font_open` does with `VFX_character_width`.
    pub fn open(font: fnt.Font) Opened {
        var opened: Opened = .{ .font = font, .widths = @splat(0) };
        const codes = @min(font.header.count, cached_codes);
        for (0..codes) |code| {
            const glyph = font.glyph(code) orelse continue;
            opened.widths[code] = @truncate(glyph.width);
        }
        return opened;
    }

    /// How wide `text` is drawn, the sum of its codes' cached widths (`font_text_width`,
    /// `0x00480E10`). A code the font does not reach counts as nothing.
    pub fn textWidth(opened: Opened, text: []const u8) u32 {
        var width: u32 = 0;
        for (text) |code| {
            if (code < cached_codes) width += opened.widths[code];
        }
        return width;
    }
};

/// Where a line of text stands from the place it is drawn at (`hud_text`, `0x00480E40`).
pub const Align = enum(u32) {
    left = 0,
    centre = 1,
    right = 2,
    _,
};

/// Where a line of `text` starts, for a line drawn at `x` with `alignment`: `hud_text` takes half
/// its width off a centred line and the whole of it off one to the right.
pub fn textLeft(opened: Opened, x: i32, text: []const u8, alignment: Align) i32 {
    const width: i32 = @intCast(opened.textWidth(text));
    return switch (alignment) {
        .centre => x - (width >> 1),
        .right => x - width,
        else => x,
    };
}

test place {
    // Half of the way across is the middle of the screen, which is what the inset and the margin
    // between them come to: (640 - 0x21) / 2 rounded is 304, and 0x10 on top is 320.
    try std.testing.expectEqual([2]i32{ 320, 240 }, place(.{ 640, 480 }, .{ 0, 0 }, 0.5, 0.5));
    try std.testing.expectEqual([2]i32{ 960, 540 }, place(.{ 1920, 1080 }, .{ 0, 0 }, 0.5, 0.5));
    // The offset is added as it stands, and a fraction of nothing leaves only the margin.
    try std.testing.expectEqual([2]i32{ 6, 116 }, place(.{ 640, 480 }, .{ -10, 100 }, 0, 0));
    // The whole way across stops a margin and an inset short of the far edge.
    try std.testing.expectEqual([2]i32{ 1903, 1063 }, place(.{ 1920, 1080 }, .{ 0, 0 }, 1, 1));
}

test gridPlace {
    const first = gridPlace(.{ 640, 480 }, 0);
    // From half-way across, less the grid's own offset.
    try std.testing.expectEqual(place(.{ 640, 480 }, grid_offset, 0.5, 0), first);
    // Two to a row: the next stands a column across, the one after a row down.
    try std.testing.expectEqual([2]i32{ first[0] + grid_across, first[1] }, gridPlace(.{ 640, 480 }, 1));
    try std.testing.expectEqual([2]i32{ first[0], first[1] + grid_down }, gridPlace(.{ 640, 480 }, 2));
    try std.testing.expectEqual([2]i32{ first[0] + grid_across, first[1] + grid_down }, gridPlace(.{ 640, 480 }, 3));
}

test Opened {
    const font = try fnt.Font.parse(comptime fnt.testing.font(false));
    const opened: Opened = .open(font);

    // Every code the font draws has its width cached, and the rest count as nothing.
    var drawn: usize = 0;
    for (0..cached_codes) |code| {
        const glyph = font.glyph(code) orelse {
            try std.testing.expectEqual(0, opened.widths[code]);
            continue;
        };
        drawn += 1;
        try std.testing.expectEqual(@as(u16, @truncate(glyph.width)), opened.widths[code]);
    }
    try std.testing.expect(drawn > 0);

    // A line is as wide as its codes together, and an empty one is nothing.
    try std.testing.expectEqual(0, opened.textWidth(""));
    const code: u8 = @intCast(for (0..cached_codes) |c| {
        if (opened.widths[c] > 0) break c;
    } else unreachable);
    const twice = [2]u8{ code, code };
    try std.testing.expectEqual(@as(u32, opened.widths[code]) * 2, opened.textWidth(&twice));
}

test textLeft {
    const opened: Opened = .open(try fnt.Font.parse(comptime fnt.testing.font(false)));
    const code: u8 = @intCast(for (0..cached_codes) |c| {
        if (opened.widths[c] > 0) break c;
    } else unreachable);
    const text = [2]u8{ code, code };
    const width: i32 = @intCast(opened.textWidth(&text));

    try std.testing.expectEqual(100, textLeft(opened, 100, &text, .left));
    try std.testing.expectEqual(100 - (width >> 1), textLeft(opened, 100, &text, .centre));
    try std.testing.expectEqual(100 - width, textLeft(opened, 100, &text, .right));
}
