//! `C:\lancer\game\hud.cpp`: the head-up display drawn over the view. `hud_draw` (`0x004843B0`)
//! draws it once a frame; `mission_run` puts it in `sr + 0x88` and Surrender calls it while it
//! renders. [`hud.md`](../../../docs/engine/hud.md) describes the file.
//!
//! Ported so far: where an element stands, the width and alignment of a line of its text, and
//! drawing that line. Not yet: `hud_draw` itself, and so what the display actually shows.
//!
//! **Improvement.** The game draws the display with the processor, whichever renderer is running:
//! `hud_text` hands its line to `VFX_string_draw`, out of `vfx.dll`, which blits each glyph into a
//! pane a pixel at a time. The port draws a glyph as a textured rectangle instead, so the display
//! costs the processor nothing and scales without blurring. What it draws is the same: a glyph's
//! bytes index the font's own palette, as they do for `VFX_character_draw`, and index 0 is left
//! clear. The state is the engine's own, an overlay-layer depth and its alpha blend.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const fnt = @import("../../formats/fnt.zig");
const math = @import("../surrender/math.zig");
const srtexture = @import("../surrender/surrenderlib/srtexture.zig");
const srd3d = @import("../surrender/srd3d/srd3d.zig");
const device = @import("../surrender/srd3d/device.zig");

/// What `hud_place` takes off the screen's size before working a place out, and what it adds back
/// afterwards. An element therefore keeps its place at any resolution.
const inset: i32 = 0x21;
const margin: i32 = 0x10;

/// The screen the display is drawn for: the size the game gives its window (`0x004A85BC`). At that
/// size `scaleFor` is 1 and the port draws the display as the game does.
pub const base_screen: [2]u32 = .{ 640, 480 };

/// **Improvement.** How much larger than its own art the display is drawn in a window of `screen`.
/// The game drew its shapes and its glyphs at their own size whatever the window's, so on a screen
/// several times the one it was drawn for they come out a fraction of the size they had. The port
/// draws them as large against the window as they stood against `base_screen`, by whichever side
/// has room for less so that the display keeps its shape. Drawing at 1 is what the game does.
pub fn scaleFor(screen: [2]u32) f32 {
    var least: f32 = std.math.floatMax(f32);
    for (screen, base_screen) |size, base| {
        least = @min(least, @as(f32, @floatFromInt(size)) / @as(f32, @floatFromInt(base)));
    }
    return least;
}

/// Where an element stands, for a fraction of the screen across and down and an offset in pixels
/// (`hud_place`, `0x00482E90`), drawn `scale` times its own size. `screen` is the window's size,
/// which the engine keeps at `sr + 0x1666` and `sr + 0x166A`.
///
/// The fraction is of the window itself, as the game takes it, so the display reaches the edges of
/// a window of any shape. What the display measures in its own pixels, the inset and the margin
/// and the offset, is what `scale` multiplies. At a scale of 1 this is the game's own arithmetic.
pub fn place(screen: [2]u32, offset: [2]i32, across: f32, down: f32, scale: f32) [2]i32 {
    var at: [2]i32 = undefined;
    for (&at, screen, offset, [2]f32{ across, down }) |*out, size, from, fraction| {
        const span = @as(f32, @floatFromInt(size)) - @as(f32, inset) * scale;
        out.* = round(span * fraction) + round(@as(f32, @floatFromInt(margin + from)) * scale);
    }
    return at;
}

/// How far apart the items of the display's grid stand, and where its first one does
/// (`hud_grid_place`, `0x00482F00`).
pub const grid_across: i32 = 0x30;
pub const grid_down: i32 = 0x26;
pub const grid_offset: [2]i32 = .{ -156, 0 };

/// Where the item of `index` stands in the grid: from half-way across the screen, two to a row.
/// The grid is measured in the display's own pixels, so `scale` carries it too.
pub fn gridPlace(screen: [2]u32, index: i32, scale: f32) [2]i32 {
    var at = place(screen, grid_offset, 0.5, 0, scale);
    at[0] += round(@as(f32, @floatFromInt(@rem(index, 2) * grid_across)) * scale);
    at[1] += round(@as(f32, @floatFromInt(@divTrunc(index, 2) * grid_down)) * scale);
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
    /// What the GPU draws each code with, made as each is first drawn.
    images: [cached_codes]?srtexture.Image = @splat(null),

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

    /// Frees the glyphs the GPU was given.
    pub fn deinit(opened: *Opened, gpa: Allocator) void {
        for (&opened.images) |*image| if (image.*) |made| {
            gpa.free(made.levels[0].rgba);
            gpa.free(made.levels);
            image.* = null;
        };
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

/// A glyph as the GPU draws it: the font's palette looked up for each of its bytes, with index 0
/// left clear. Made the first time the glyph is drawn and kept for the rest of the run.
fn glyphImage(opened: *Opened, gpa: Allocator, code: u8) Allocator.Error!?*srtexture.Image {
    if (opened.images[code]) |*made| return made;
    const glyph = opened.font.glyph(code) orelse return null;
    const palette = opened.font.palette orelse return null;
    if (glyph.width == 0 or opened.font.header.height == 0) return null;

    const rgba = try gpa.alloc(u8, glyph.pixels.len * 4);
    errdefer gpa.free(rgba);
    for (glyph.pixels, 0..) |index, at| {
        const entry = palette[@as(usize, index) * 3 ..][0..3];
        // The palette holds 6-bit levels, as the sprites' does.
        for (0..3) |channel| rgba[at * 4 + channel] = expand(entry[channel]);
        rgba[at * 4 + 3] = if (index == 0) 0 else 255;
    }
    const levels = try gpa.alloc(srtexture.Level, 1);
    errdefer gpa.free(levels);
    levels[0] = .{ .width = glyph.width, .height = opened.font.header.height, .rgba = rgba };
    opened.images[code] = .{ .levels = levels };
    return &opened.images[code].?;
}

/// A 6-bit palette level as an 8-bit one, as `spr.expandPalette` does.
fn expand(level: u8) u8 {
    const six: u8 = level & 0x3F;
    return (six << 2) | (six >> 4);
}

/// Draws `text` at `at`, tinted by `colour`, `scale` times the font's own size, and returns where
/// the line ends. `hud_text` aligns the line first; the glyphs then follow one another by their
/// own widths, as `VFX_string_draw` moves along by what each glyph returns.
pub fn drawText(
    opened: *Opened,
    gpa: Allocator,
    target: device.Device,
    at: [2]i32,
    text: []const u8,
    colour: [4]f32,
    alignment: Align,
    scale: f32,
) Allocator.Error!i32 {
    if (text.len == 0) return at[0];
    var x: f32 = @floatFromInt(textLeft(opened.*, at[0], text, alignment, scale));
    const top: f32 = @floatFromInt(at[1]);
    const height = @as(f32, @floatFromInt(opened.font.header.height)) * scale;
    const tint = device.pack(colour);
    // The display stands over the scene, blended by what it covers.
    const state: device.State = .{
        .texture = null,
        .depth = srd3d.depth(.overlay, .alpha),
        .blend = srd3d.factors(.alpha),
    };
    for (text) |code| {
        const width = @as(f32, @floatFromInt(opened.widths[code])) * scale;
        defer x += width;
        const image = try glyphImage(opened, gpa, code) orelse continue;
        var drawn = state;
        drawn.texture = image;
        const corners = [4]device.Vertex{
            .{ .x = x, .y = top, .z = 1, .rhw = 1, .diffuse = tint, .u = 0, .v = 0 },
            .{ .x = x + width, .y = top, .z = 1, .rhw = 1, .diffuse = tint, .u = 1, .v = 0 },
            .{ .x = x + width, .y = top + height, .z = 1, .rhw = 1, .diffuse = tint, .u = 1, .v = 1 },
            .{ .x = x, .y = top + height, .z = 1, .rhw = 1, .diffuse = tint, .u = 0, .v = 1 },
        };
        target.draw(drawn, .fan, &corners, null);
    }
    return @intFromFloat(x);
}

/// Where a line of `text` starts, for a line drawn at `x` with `alignment` and `scale`: `hud_text`
/// takes half its width off a centred line and the whole of it off one to the right. The width is
/// in the display's own pixels, so `scale` carries it too.
pub fn textLeft(opened: Opened, x: i32, text: []const u8, alignment: Align, scale: f32) i32 {
    const width: i32 = @intCast(opened.textWidth(text));
    const shift: i32 = switch (alignment) {
        .centre => width >> 1,
        .right => width,
        else => return x,
    };
    return x - round(@as(f32, @floatFromInt(shift)) * scale);
}

test place {
    // Half of the way across is the middle of the screen, which is what the inset and the margin
    // between them come to: (640 - 0x21) / 2 rounded is 304, and 0x10 on top is 320.
    try std.testing.expectEqual([2]i32{ 320, 240 }, place(.{ 640, 480 }, .{ 0, 0 }, 0.5, 0.5, 1));
    try std.testing.expectEqual([2]i32{ 960, 540 }, place(.{ 1920, 1080 }, .{ 0, 0 }, 0.5, 0.5, 1));
    // The offset is added as it stands, and a fraction of nothing leaves only the margin.
    try std.testing.expectEqual([2]i32{ 6, 116 }, place(.{ 640, 480 }, .{ -10, 100 }, 0, 0, 1));
    // The whole way across stops a margin and an inset short of the far edge.
    try std.testing.expectEqual([2]i32{ 1903, 1063 }, place(.{ 1920, 1080 }, .{ 0, 0 }, 1, 1, 1));
}

test "a scaled element keeps its share of the window" {
    // Drawn twice its own size, what the display measures in its own pixels doubles: the margin,
    // the offset and the inset. The fraction of the window does not.
    try std.testing.expectEqual([2]i32{ 12, 232 }, place(.{ 640, 480 }, .{ -10, 100 }, 0, 0, 2));
    // Half of the way across stays within a pixel or so of the middle of the window: the inset
    // grows with the display, which moves the middle by half of it.
    try std.testing.expectEqual([2]i32{ 319, 239 }, place(.{ 640, 480 }, .{ 0, 0 }, 0.5, 0.5, 2));
    try std.testing.expectEqual([2]i32{ 1278, 718 }, place(.{ 2560, 1440 }, .{ 0, 0 }, 0.5, 0.5, 3));
    // The whole way across keeps the margin and the inset, both grown with the display.
    try std.testing.expectEqual([2]i32{ 2509, 1389 }, place(.{ 2560, 1440 }, .{ 0, 0 }, 1, 1, 3));
}

test scaleFor {
    // The screen the display is drawn for leaves it at its own size.
    try std.testing.expectEqual(1, scaleFor(base_screen));
    // Three times as tall and four times as wide: the side with room for less wins.
    try std.testing.expectEqual(3, scaleFor(.{ 2560, 1440 }));
    try std.testing.expectEqual(2, scaleFor(.{ 1280, 960 }));
    // A window smaller than the screen it was drawn for draws it smaller, so that it still fits.
    try std.testing.expectEqual(0.5, scaleFor(.{ 320, 240 }));
}

test gridPlace {
    const first = gridPlace(.{ 640, 480 }, 0, 1);
    // From half-way across, less the grid's own offset.
    try std.testing.expectEqual(place(.{ 640, 480 }, grid_offset, 0.5, 0, 1), first);
    // Two to a row: the next stands a column across, the one after a row down.
    try std.testing.expectEqual([2]i32{ first[0] + grid_across, first[1] }, gridPlace(.{ 640, 480 }, 1, 1));
    try std.testing.expectEqual([2]i32{ first[0], first[1] + grid_down }, gridPlace(.{ 640, 480 }, 2, 1));
    try std.testing.expectEqual([2]i32{ first[0] + grid_across, first[1] + grid_down }, gridPlace(.{ 640, 480 }, 3, 1));
    // Scaled, the grid's own spacing grows with it.
    const scaled = gridPlace(.{ 640, 480 }, 3, 2);
    const scaled_first = gridPlace(.{ 640, 480 }, 0, 2);
    try std.testing.expectEqual([2]i32{ scaled_first[0] + grid_across * 2, scaled_first[1] + grid_down * 2 }, scaled);
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

    try std.testing.expectEqual(100, textLeft(opened, 100, &text, .left, 1));
    try std.testing.expectEqual(100 - (width >> 1), textLeft(opened, 100, &text, .centre, 1));
    try std.testing.expectEqual(100 - width, textLeft(opened, 100, &text, .right, 1));
    // Drawn larger, the line is wider, so a centred one starts further back.
    try std.testing.expectEqual(100 - width * 2, textLeft(opened, 100, &text, .right, 2));
}

test drawText {
    const gpa = std.testing.allocator;
    var opened: Opened = .open(try fnt.Font.parse(comptime fnt.testing.font(true)));
    defer opened.deinit(gpa);

    // A device that keeps what it was asked to draw.
    const Recorder = struct {
        drawn: std.ArrayList([4]device.Vertex) = .empty,
        states: std.ArrayList(device.State) = .empty,
        gpa: Allocator,

        fn begin(_: *anyopaque) void {}
        fn end(_: *anyopaque) void {}
        fn draw(context: *anyopaque, state: device.State, primitive: device.Primitive, vertices: []const device.Vertex, indices: ?[]const u16) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            std.debug.assert(primitive == .fan and indices == null and vertices.len == 4);
            self.drawn.append(self.gpa, vertices[0..4].*) catch unreachable;
            self.states.append(self.gpa, state) catch unreachable;
        }
        fn interface(self: *@This()) device.Device {
            return .{ .ptr = self, .vtable = &.{ .begin = begin, .end = end, .draw = draw } };
        }
    };
    var recorder: Recorder = .{ .gpa = gpa };
    defer recorder.drawn.deinit(gpa);
    defer recorder.states.deinit(gpa);

    // The fixture's code 1 is the only one with a glyph; code 0 has none and draws nothing.
    const text = [_]u8{ 1, 0, 1 };
    const ended = try drawText(&opened, gpa, recorder.interface(), .{ 10, 20 }, &text, .{ 1, 1, 1, 1 }, .left, 1);
    try std.testing.expectEqual(2, recorder.drawn.items.len);

    // The first glyph stands where the line does, and the second follows the first's width along,
    // the code with no glyph having moved nothing.
    const width: f32 = @floatFromInt(opened.widths[1]);
    try std.testing.expectEqual(10, recorder.drawn.items[0][0].x);
    try std.testing.expectEqual(20, recorder.drawn.items[0][0].y);
    try std.testing.expectEqual(10 + width, recorder.drawn.items[1][0].x);
    try std.testing.expectEqual(@as(i32, @intFromFloat(10 + width * 2)), ended);

    // Each is as tall as the font and as wide as the glyph, and drawn over the scene.
    const height: f32 = @floatFromInt(opened.font.header.height);
    try std.testing.expectEqual(10 + width, recorder.drawn.items[0][2].x);
    try std.testing.expectEqual(20 + height, recorder.drawn.items[0][2].y);
    try std.testing.expect(!recorder.states.items[0].depth.testing);
    try std.testing.expect(!recorder.states.items[0].depth.writing);
    try std.testing.expectEqual(srd3d.factors(.alpha), recorder.states.items[0].blend);

    // Drawn twice the size, a glyph covers twice as much and the line is twice as long.
    recorder.drawn.clearRetainingCapacity();
    _ = try drawText(&opened, gpa, recorder.interface(), .{ 0, 0 }, text[0..1], .{ 1, 1, 1, 1 }, .left, 2);
    try std.testing.expectEqual(width * 2, recorder.drawn.items[0][2].x);
    try std.testing.expectEqual(height * 2, recorder.drawn.items[0][2].y);
}
