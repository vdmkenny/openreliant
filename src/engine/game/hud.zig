//! `C:\lancer\game\hud.cpp`: the head-up display drawn over the view. `hud_draw` (`0x004843B0`)
//! draws it once a frame; `mission_run` puts it in `sr + 0x88` and Surrender calls it while it
//! renders. [`hud.md`](../../../docs/engine/hud.md) describes the file.
//!
//! Ported so far: where an element stands, its text, the readouts, the clock, the status lights
//! with the devices' charges, the jump prompt, the eject marker, the scanner, the ship status
//! indicator's shields, the targeting cluster, the radar's rings and ranges, and the windows,
//! their frames and how they open and close ([`hud/windows.zig`](hud/windows.zig)). Not yet: the
//! rest of `hud_draw`, whose other elements [`hud.md`](../../../docs/engine/hud.md) lists, and
//! what the windows show.
//!
//! **Improvement.** The game draws the display with the processor, whichever renderer is running:
//! `hud_text` hands its line to `VFX_string_draw`, out of `vfx.dll`, which blits each glyph into a
//! pane a pixel at a time. The port draws a glyph as a textured rectangle instead, so the display
//! costs the processor nothing and scales without blurring. What it draws is the same: a glyph's
//! bytes index the font's own palette, as they do for `VFX_character_draw`, and index 0 is left
//! clear. The state is the engine's own, an overlay-layer depth and its alpha blend. It has no
//! fallback yet: `--original` draws the same way, and the software device cannot draw the text at
//! all until `VFX_character_draw` is ported.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const fnt = @import("../../formats/fnt.zig");
const math = @import("../surrender/math.zig");
const spr = @import("../../formats/spr.zig");
const camera = @import("camera.zig");
const gameobj = @import("gameobj.zig");
const input = @import("../input.zig");
const language = @import("language.zig");
const srtexture = @import("../surrender/surrenderlib/srtexture.zig");
const srd3d = @import("../surrender/srd3d/srd3d.zig");
const device = @import("../surrender/srd3d/device.zig");

pub const windows = @import("hud/windows.zig");

/// What `hud_place` takes off the screen's size before working a place out, and what it adds back
/// afterwards. An element therefore keeps its place at any resolution.
const inset: i32 = 0x21;
const margin: i32 = 0x10;

/// The screen the port draws the display for: 1024 by 768, a mode the hardware renderers run in
/// and the size of the retail game's own screenshots. At that size `scaleFor` is 1 and the port
/// draws the display as the game does. The game's window starts at 640 by 480 (`0x004A85BC`),
/// where the same offsets in pixels stand further in from the edges.
pub const base_screen: [2]u32 = .{ 1024, 768 };

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

/// The sprite set the display's shapes come from: `HUDHARD.SPR` for the hardware renderers and
/// `HUDSOFT.SPR` for the software one.
pub const hardware_shapes = "HUDHARD.SPR";
pub const software_shapes = "HUDSOFT.SPR";

/// The block of the display's set that `hud_draw` makes VFX's global palette of every frame
/// under the hardware renderers (`0x00428410`), at the brightness `0x00569718` holds, which
/// `hud_init` sets to 1 and nothing changes. `VFX_shape_draw` draws a shape whose entry names no
/// palette with the global one, and no entry of a shipped set names one: so every shape of the
/// display is drawn with this block's palette, those after the set's second palette block
/// included, and the ships' schematics too. Nothing in the display makes another block the
/// global palette.
pub const global_palette_block = 0x77;

/// VFX's global palette as `hud_draw` sets it from the display's set, or null for a set whose
/// block there is no palette.
pub fn globalPalette(set: spr.Sprite) ?*const [spr.palette_size]u8 {
    if (global_palette_block >= set.count()) return null;
    return switch (set.block(global_palette_block)) {
        .palette => |found| found,
        else => null,
    };
}

/// A set of the display's shapes, with an image made of each as it is first drawn. Every entry of
/// a shipped set names no palette, so VFX draws each shape with its global palette, which
/// `hud_draw` makes of the display's own set; a set given none takes the nearest palette at or
/// before a shape, as the tools show them.
pub const Art = struct {
    set: spr.Sprite,
    images: []?srtexture.Image,
    /// The palette every shape is drawn with: VFX's global palette.
    global: ?*const [spr.palette_size]u8 = null,

    pub fn init(gpa: Allocator, set: spr.Sprite, global: ?*const [spr.palette_size]u8) Allocator.Error!Art {
        const images = try gpa.alloc(?srtexture.Image, set.count());
        @memset(images, null);
        return .{ .set = set, .images = images, .global = global };
    }

    pub fn deinit(art: *Art, gpa: Allocator) void {
        for (art.images) |held| if (held) |made| {
            gpa.free(made.levels[0].rgba);
            gpa.free(made.levels);
        };
        gpa.free(art.images);
    }

    fn shape(art: Art, index: usize) ?spr.Shape {
        if (index >= art.set.count()) return null;
        return switch (art.set.block(index)) {
            .shape => |found| found,
            else => null,
        };
    }

    /// The image of the shape at `index`, made the first time it is drawn. Index 0 of a shape is
    /// clear, as it is wherever the sprites are drawn.
    fn image(art: *Art, gpa: Allocator, index: usize) (spr.Error || Allocator.Error)!?*srtexture.Image {
        if (index >= art.images.len) return null;
        if (art.images[index]) |*made| return made;
        const found = art.shape(index) orelse return null;
        const palette = art.global orelse art.set.paletteFor(index) orelse return null;
        var expanded: [spr.palette_size]u8 = undefined;
        spr.expandPalette(palette, &expanded);

        const indices = try found.decode(gpa);
        defer gpa.free(indices);
        const rgba = try gpa.alloc(u8, indices.len * 4);
        errdefer gpa.free(rgba);
        for (indices, 0..) |at, pixel| {
            const entry = expanded[@as(usize, at) * 3 ..][0..3];
            for (0..3) |channel| rgba[pixel * 4 + channel] = entry[channel];
            rgba[pixel * 4 + 3] = if (at == 0) 0 else 255;
        }
        const levels = try gpa.alloc(srtexture.Level, 1);
        errdefer gpa.free(levels);
        levels[0] = .{ .width = found.width(), .height = found.height(), .rgba = rgba };
        art.images[index] = .{ .levels = levels };
        return &art.images[index].?;
    }
};

/// Draws the shape at `index` with its anchor at `at`, `scale` times its own size. A shape's
/// bounds are in a frame whose origin is that anchor, so they say where it hangs from the point.
pub fn drawShape(
    art: *Art,
    gpa: Allocator,
    target: device.Device,
    index: usize,
    at: [2]i32,
    colour: [4]f32,
    scale: f32,
) (spr.Error || Allocator.Error)!void {
    return drawShapeWith(art, gpa, target, index, at, colour, scale, .{});
}

/// How a shape is drawn besides as it stands.
pub const Draw = struct {
    /// Flipped within its own bounds, which keep their place.
    mirror: Mirror = .{},
    /// Only what falls inside a rectangle of the screen, as a VFX pane clips what is drawn into
    /// it.
    clip: ?Clip = null,
};

/// Which ways `VFX_shape_draw_mirrored` flips a shape, the two low bits of its mode: 1 across, 2
/// down, 3 both. Its bit 4, drawing through a remap table, the display does not use with it.
pub const Mirror = packed struct(u2) {
    across: bool = false,
    down: bool = false,

    /// The flips of a mode as the display's tables give it.
    pub fn of(mode: u2) Mirror {
        return @bitCast(mode);
    }
};

/// A rectangle of the screen in its pixels: its left and top edges inside it, its right and
/// bottom ones not.
pub const Clip = struct {
    left: f32,
    top: f32,
    right: f32,
    bottom: f32,
};

/// Draws the shape at `index` as `drawShape` does, mirrored or clipped as `how` says.
pub fn drawShapeWith(
    art: *Art,
    gpa: Allocator,
    target: device.Device,
    index: usize,
    at: [2]i32,
    colour: [4]f32,
    scale: f32,
    how: Draw,
) (spr.Error || Allocator.Error)!void {
    const found = art.shape(index) orelse return;
    const image = try art.image(gpa, index) orelse return;
    const left = @as(f32, @floatFromInt(at[0])) + @as(f32, @floatFromInt(found.header.x1)) * scale;
    const top = @as(f32, @floatFromInt(at[1])) + @as(f32, @floatFromInt(found.header.y1)) * scale;
    const right = left + @as(f32, @floatFromInt(found.width())) * scale;
    const bottom = top + @as(f32, @floatFromInt(found.height())) * scale;
    var x: [2]f32 = .{ left, right };
    var y: [2]f32 = .{ top, bottom };
    var u: [2]f32 = if (how.mirror.across) .{ 1, 0 } else .{ 0, 1 };
    var v: [2]f32 = if (how.mirror.down) .{ 1, 0 } else .{ 0, 1 };
    if (how.clip) |clip| {
        const kept_x: [2]f32 = .{ @max(left, clip.left), @min(right, clip.right) };
        const kept_y: [2]f32 = .{ @max(top, clip.top), @min(bottom, clip.bottom) };
        if (kept_x[0] >= kept_x[1] or kept_y[0] >= kept_y[1]) return;
        // Each texture coordinate follows its edge in, in the shape's own proportion.
        const across = u;
        const down = v;
        for (0..2) |edge| {
            u[edge] = across[0] + (across[1] - across[0]) * (kept_x[edge] - left) / (right - left);
            v[edge] = down[0] + (down[1] - down[0]) * (kept_y[edge] - top) / (bottom - top);
        }
        x = kept_x;
        y = kept_y;
    }
    const tint = device.pack(colour);
    const corners = [4]device.Vertex{
        .{ .x = x[0], .y = y[0], .z = 1, .rhw = 1, .diffuse = tint, .u = u[0], .v = v[0] },
        .{ .x = x[1], .y = y[0], .z = 1, .rhw = 1, .diffuse = tint, .u = u[1], .v = v[0] },
        .{ .x = x[1], .y = y[1], .z = 1, .rhw = 1, .diffuse = tint, .u = u[1], .v = v[1] },
        .{ .x = x[0], .y = y[1], .z = 1, .rhw = 1, .diffuse = tint, .u = u[0], .v = v[1] },
    };
    target.draw(.{
        .texture = image,
        .depth = srd3d.depth(.overlay, .alpha),
        .blend = srd3d.factors(.alpha),
    }, .fan, &corners, null);
}

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
    // Wider than it is tall: the side with room for less wins.
    try std.testing.expectEqual(1.875, scaleFor(.{ 2560, 1440 }));
    try std.testing.expectEqual(2, scaleFor(.{ 2048, 1536 }));
    // A window smaller than the screen it was drawn for draws it smaller, so that it still fits.
    try std.testing.expectEqual(0.625, scaleFor(.{ 640, 480 }));
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
    const larger = gridPlace(.{ 640, 480 }, 3, 2);
    const larger_first = gridPlace(.{ 640, 480 }, 0, 2);
    try std.testing.expectEqual([2]i32{ larger_first[0] + grid_across * 2, larger_first[1] + grid_down * 2 }, larger);
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
        fn mark(_: *anyopaque) void {}
        fn draw(context: *anyopaque, state: device.State, primitive: device.Primitive, vertices: []const device.Vertex, indices: ?[]const u16) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            std.debug.assert(primitive == .fan and indices == null and vertices.len == 4);
            self.drawn.append(self.gpa, vertices[0..4].*) catch unreachable;
            self.states.append(self.gpa, state) catch unreachable;
        }
        fn interface(self: *@This()) device.Device {
            return .{ .ptr = self, .vtable = &.{ .begin = begin, .end = end, .draw = draw, .overlay = mark } };
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

/// The readouts `hud_draw` puts in a row across the top of the screen, each a shape with a number
/// centred under it. All three stand half of the way across, at the offsets it hands `hud_place`.
pub const Readout = enum {
    /// The seconds of afterburner fuel left, `afterburner_fuel` being in hundredths, under a ship
    /// with its engines burning.
    fuel,
    /// **Unknown** what it counts: the word at `0x00562DF4`, which the front end sets, under a
    /// skull and crossbones.
    skull,
    /// The countermeasures left, the object's `countermeasures`, under a coil. `ShowHudIcon` can
    /// flash it (`State.shows`).
    coil,

    /// Where a readout stands and what it draws there.
    pub const Spec = struct {
        /// The offset `hud_draw` hands `hud_place`, and the fraction of the screen.
        offset: [2]i32,
        across: f32,
        down: f32,
        /// The shape of the display's set drawn at that point.
        shape: u16,
        /// Where the shape hangs from it, which two of the three shift along.
        shape_offset: [2]i32 = .{ 0, 0 },
        /// Where the number is centred from the point: `0x1E` below it, and across by as much
        /// as its shape is shifted, near enough to stand under it.
        text_offset: [2]i32,
    };

    pub fn spec(readout: Readout) Spec {
        return switch (readout) {
            .fuel => .{ .offset = .{ 0x39, 0 }, .across = 0.5, .down = 0, .shape = 0xCD, .text_offset = .{ 0x10, 0x1E } },
            .skull => .{ .offset = .{ 0x5F, 0 }, .across = 0.5, .down = 0, .shape = 0xD0, .shape_offset = .{ -4, 0 }, .text_offset = .{ 0x0B, 0x1E } },
            .coil => .{ .offset = .{ 0x98, 0 }, .across = 0.5, .down = 0, .shape = 0xCF, .shape_offset = .{ -0x1A, 0 }, .text_offset = .{ -9, 0x1E } },
        };
    }

    /// Draws the readout for a window of `screen`, showing `value`.
    pub fn draw(
        readout: Readout,
        art: *Art,
        opened: *Opened,
        gpa: Allocator,
        target: device.Device,
        screen: [2]u32,
        value: i32,
        colour: [4]f32,
        scale: f32,
    ) (spr.Error || Allocator.Error)!void {
        const at = readout.spec();
        const point = place(screen, at.offset, at.across, at.down, scale);
        try drawShape(art, gpa, target, at.shape, scaled(point, at.shape_offset, scale), colour, scale);

        var buffer: [16]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, "{d}", .{value}) catch return;
        _ = try drawText(opened, gpa, target, scaled(point, at.text_offset, scale), text, colour, .centre, scale);
    }
};

/// `point` moved by an offset the display measures in its own pixels.
fn scaled(point: [2]i32, offset: [2]i32, scale: f32) [2]i32 {
    var at: [2]i32 = undefined;
    for (&at, point, offset) |*out, from, by| {
        out.* = from + round(@as(f32, @floatFromInt(by)) * scale);
    }
    return at;
}

test Readout {
    // The three stand in a row across the top, half of the way across and rising to the right.
    var last: i32 = 0;
    for ([_]Readout{ .fuel, .skull, .coil }) |readout| {
        const at = readout.spec();
        try std.testing.expectEqual(0.5, at.across);
        try std.testing.expectEqual(0, at.down);
        try std.testing.expect(at.offset[0] > last);
        last = at.offset[0];
        const point = place(.{ 640, 480 }, at.offset, at.across, at.down, 1);
        try std.testing.expectEqual([2]i32{ 320 + at.offset[0], 16 }, point);
    }
    // An offset the display measures in its own pixels grows with it.
    try std.testing.expectEqual([2]i32{ 100 - 8, 20 }, scaled(.{ 100, 20 }, .{ -4, 0 }, 2));
    try std.testing.expectEqual([2]i32{ 100 + 0x10, 20 + 0x1E }, scaled(.{ 100, 20 }, Readout.fuel.spec().text_offset, 1));
    // Each number stands under its own shape: the coil's shape and number both lie left of the
    // point, its number 9 left.
    try std.testing.expectEqual(-9, Readout.coil.spec().text_offset[0]);
    try std.testing.expectEqual(0x0B, Readout.skull.spec().text_offset[0]);
}

/// Whether the display's instruments are drawn: `hud_draw` leaves out the jump prompt, the radar,
/// the eject marker, the scanner, the status lights and everything from the readouts to the clock
/// unless last frame's view was 0, the one ahead from the cockpit, in whichever cockpit mode, the
/// chase view among them. The rest of the views get the view's name in their place.
pub fn instrumented(last_view: camera.View) bool {
    return last_view == .cockpit;
}

/// How far down `hud_draw` draws the view's name, centred half of the way across the screen. It
/// measures both from the screen's edge rather than placing the text with `hud_place`.
pub const view_name_down: i32 = 10;

/// Whether `hud_draw` names `last_view` at the top of the screen: every view but 0, and but the
/// fly-bys, `0x24` to `0x26`.
pub fn namesView(last_view: camera.View) bool {
    const n = @intFromEnum(last_view);
    return n != 0 and (n < 0x24 or n > 0x26);
}

/// Draws the name of `last_view` where `hud_draw` does, the view table's string for it out of
/// `strings`. A view past the table, or a string past `strings`, draws nothing; the game stops
/// with a fatal error for either.
pub fn drawViewName(
    opened: *Opened,
    gpa: Allocator,
    target: device.Device,
    screen: [2]u32,
    last_view: camera.View,
    strings: language.Language,
    colour: [4]f32,
    scale: f32,
) Allocator.Error!void {
    if (!namesView(last_view)) return;
    const text = strings.string(last_view.name() orelse return) orelse return;
    const at: [2]i32 = .{ @intCast(screen[0] >> 1), round(@as(f32, @floatFromInt(view_name_down)) * scale) };
    _ = try drawText(opened, gpa, target, at, text, colour, .centre, scale);
}

/// Where `hud_draw` centres the mission's clock: half of the way across, at the foot of the screen
/// and `130` up.
pub const clock_offset: [2]i32 = .{ 0, -130 };
pub const clock_across: f32 = 0.5;
pub const clock_down: f32 = 1;

/// Draws the mission's clock as `hud_draw` does: the minutes and the seconds, each of two figures,
/// centred at its place. The game shows the time played, or the mission's own countdown where it
/// runs one.
pub fn drawClock(
    opened: *Opened,
    gpa: Allocator,
    target: device.Device,
    screen: [2]u32,
    minutes: u16,
    seconds: u16,
    colour: [4]f32,
    scale: f32,
) Allocator.Error!void {
    var buffer: [16]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{d:0>2}:{d:0>2}", .{ minutes, seconds }) catch return;
    const at = place(screen, clock_offset, clock_across, clock_down, scale);
    _ = try drawText(opened, gpa, target, at, text, colour, .centre, scale);
}

test drawClock {
    // The clock stands at the foot of the screen, 130 of the display's own pixels up.
    const at = place(.{ 640, 480 }, clock_offset, clock_across, clock_down, 1);
    try std.testing.expectEqual([2]i32{ 320, 480 - 33 + 16 - 130 }, at);
    // Drawn larger, it keeps to the foot and rises by as much more.
    const larger = place(.{ 640, 480 }, clock_offset, clock_across, clock_down, 2);
    try std.testing.expectEqual(480 - 66 + 32 - 260, larger[1]);

    // The figures are padded to two as "%02d:%02d" does.
    var buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("09:06", try std.fmt.bufPrint(&buffer, "{d:0>2}:{d:0>2}", .{ @as(u16, 9), @as(u16, 6) }));
}

test namesView {
    try std.testing.expect(!namesView(.cockpit));
    try std.testing.expect(namesView(.cockpit_rear));
    try std.testing.expect(namesView(.external));
    try std.testing.expect(namesView(.chase));
    try std.testing.expect(!namesView(.flyby));
    try std.testing.expect(!namesView(@enumFromInt(0x26)));
    try std.testing.expect(namesView(@enumFromInt(0x27)));
}

test instrumented {
    // The view ahead from the cockpit has the instruments; the others do not, the cockpit's own
    // side and rear views among them.
    try std.testing.expect(instrumented(.cockpit));
    try std.testing.expect(!instrumented(.cockpit_left));
    try std.testing.expect(!instrumented(.chase));
    try std.testing.expect(!instrumented(.external));
    try std.testing.expect(!instrumented(.flyby));
}

// --- The status lights -----------------------------------------------------------------------

/// The status lights `hud_draw` packs into the display's grid, in the order it draws them, each
/// valued by its shape. A light takes the next place only while its condition holds, so the ones
/// after a light that is out close up. A flashing light keeps its place while it is dark.
pub const Light = enum(u16) {
    /// MATCH SPEED holds the ship to its target's speed: `matching_speed`.
    match_speed = 0xCC,
    /// Blind fire, which aims the guns at whatever stands in the middle of the display: the ship
    /// carries it, TOGGLE BLINDFIRE has it on, and the guns are not all firing (`GunMode.all`).
    blind_fire = 0xCB,
    /// Smart targeting, which makes any ship the player fires on the target: SMART TARGET has it
    /// on.
    smart_targeting = 0xC5,
    /// The lock warning, a ship in a gun sight: `State.enemy_lock`, with no missile homing on the
    /// ship yet. It flashes, and a warning sound loops while it is shown.
    enemy_lock = 0xC3,
    /// A missile homes on the ship: its `missile_homing`. It flashes twice as fast as the lock
    /// warning, on the same count.
    missile_incoming = 0xC4,
    /// The ECM is on, with its charge as a bar under it.
    ecm = 0xC6,
    /// The ship carries a cloak, on or off, with its charge as a bar under it. Never in a
    /// multiplayer game.
    cloak = 0xC7,
    /// The spectral shields are on, with their charge as a bar under them.
    spectral_shields = 0xCA,
    /// Reverse thrust burns: the object's `reverse_thrust`.
    reverse_thrust = 0xC8,

    /// The device whose charge the light's bar shows, for the three that have one.
    pub fn charged(light: Light) ?Device {
        return switch (light) {
            .ecm => .ecm,
            .cloak => .cloak,
            .spectral_shields => .spectral_shields,
            else => null,
        };
    }
};

/// Which lights' conditions hold, a bit a light, named and ordered as `Light` has them.
pub const Lit = packed struct(u9) {
    match_speed: bool = false,
    blind_fire: bool = false,
    smart_targeting: bool = false,
    enemy_lock: bool = false,
    missile_incoming: bool = false,
    ecm: bool = false,
    cloak: bool = false,
    spectral_shields: bool = false,
    reverse_thrust: bool = false,

    comptime {
        for (@typeInfo(Lit).@"struct".fields, std.enums.values(Light)) |field, light| {
            assert(std.mem.eql(u8, field.name, @tagName(light)));
        }
    }
};

/// How the display flashes a shape: lit for the first `on` ticks of every `period`.
pub const Flash = struct {
    on: i32,
    period: i32,

    /// The pace of `ShowHudIcon`'s icons, the lock warning, the jump prompt and the eject marker.
    pub const slow: Flash = .{ .on = 50, .period = 100 };
    /// The pace of the missile warning.
    pub const fast: Flash = .{ .on = 25, .period = 50 };

    /// Moves `ticks` on by a frame of `frame_duration` and says whether the shape is drawn in it.
    /// Past the period the count starts again from nothing, on a dark frame.
    pub fn step(flash: Flash, ticks: *i32, frame_duration: i32) bool {
        ticks.* += frame_duration;
        if (ticks.* < flash.on) return true;
        if (ticks.* > flash.period) ticks.* = 0;
        return false;
    }
};

/// The display's elements `ShowHudIcon` (mission command `0x5B`, `0x0045A1F0`) can light or flash
/// through `hud_icon_lit`, numbered as the command numbers them.
pub const Icon = enum(u5) {
    enemy_lock = 0,
    missile_incoming = 1,
    ecm = 2,
    /// The countermeasures readout, which is drawn anyway unless the icon flashes it.
    countermeasures = 3,
    smart_targeting = 4,
    /// The eject marker.
    ejected = 5,
    _,
};

/// What `ShowHudIcon` sets an icon to: "0 - off, 1 - on, 2 - flash".
pub const IconState = enum(u32) {
    off = 0,
    on = 1,
    flash = 2,
    _,
};

/// The icons `ShowHudIcon` sets (`0x00566558`), which `hud_init` turns off. The table holds
/// twenty; the display reads the six `Icon` names.
pub const Icons = struct {
    pub const count = 20;

    /// An icon's state and the count its flash is at.
    pub const Slot = extern struct {
        state: IconState = .off,
        ticks: i32 = 0,
    };

    slots: [count]Slot = @splat(.{}),

    /// Sets an icon as `ShowHudIcon` does, its flash starting from the beginning.
    ///
    /// **Improvement.** The game writes past the table for an icon of 20 or more; the port leaves
    /// such an icon alone.
    pub fn show(icons: *Icons, icon: Icon, state: IconState) void {
        const at = @intFromEnum(icon);
        if (at >= count) return;
        icons.slots[at] = .{ .state = state };
    }

    /// Whether `icon` is lit in a frame of `frame_duration` (`hud_icon_lit`, `0x00482F50`): always
    /// when on, and when flashing for the first 50 ticks of every 100. Unlike the display's other
    /// flashes, one that runs past 100 carries what it ran over into the next and is lit.
    pub fn lit(icons: *Icons, icon: Icon, frame_duration: i32) bool {
        const at = @intFromEnum(icon);
        if (at >= count) return false;
        const slot = &icons.slots[at];
        switch (slot.state) {
            .on => return true,
            .flash => {
                slot.ticks += frame_duration;
                if (slot.ticks < Flash.slow.on) return true;
                if (slot.ticks > Flash.slow.period) {
                    slot.ticks -= Flash.slow.period;
                    return true;
                }
                return false;
            },
            else => return false,
        }
    }
};

/// A device a ship may carry that runs off a charge, which its light shows as a bar.
pub const Device = enum {
    ecm,
    cloak,
    spectral_shields,

    pub const Spec = struct {
        /// The charge when full, in ticks, where `hud_init` starts it.
        full: i32,
        /// What it spends of the charge a tick while it is on. It charges at one a tick while off.
        drain: i32,
        /// The bar's length for a tick of charge, in the display's own pixels, and how far below
        /// the light's point it runs.
        bar_scale: f32,
        bar_down: i32,
    };

    /// Twenty seconds of ECM, a hundred of the cloak and ten of the spectral shields, each bar
    /// about 32 pixels long when full.
    pub fn spec(kind: Device) Spec {
        return switch (kind) {
            .ecm => .{ .full = 2000, .drain = 1, .bar_scale = 1.0 / 62.0, .bar_down = 0x23 },
            .cloak => .{ .full = 10000, .drain = 1, .bar_scale = 1.0 / 312.0, .bar_down = 0x20 },
            .spectral_shields => .{ .full = 6000, .drain = 6, .bar_scale = 1.0 / 187.0, .bar_down = 0x20 },
        };
    }
};

/// Whether the ship carries a device, and whether it is on: `ecm_state` (`0x0057BF4C`),
/// `cloak_state` (`0x00566638`) and `spectral_shields_state` (`0x0057BF20`).
pub const Setting = enum(i32) {
    absent = -1,
    off = 0,
    on = 1,
    _,
};

/// A device's setting and its charge in ticks: `ecm_charge` (`0x005665F8`), `cloak_charge`
/// (`0x0056663C`) and `spectral_shields_charge` (`0x00566620`).
pub const Charge = struct {
    setting: Setting = .off,
    ticks: i32,

    /// Carried, off and full, as `hud_init` leaves each device.
    pub fn full(kind: Device) Charge {
        return .{ .ticks = kind.spec().full };
    }

    /// `hud_draw`'s work on the charge for a frame of `frame_duration`: while the device is off it
    /// charges up to full, and while it is on it drains. Says whether it has just run dry, which
    /// leaves the charge at nothing for the device to be turned off.
    pub fn run(charge: *Charge, kind: Device, frame_duration: i32) bool {
        const at = kind.spec();
        switch (charge.setting) {
            .off => charge.ticks = @min(charge.ticks + frame_duration, at.full),
            .on => {
                charge.ticks -= frame_duration * at.drain;
                if (charge.ticks < 0) {
                    charge.ticks = 0;
                    return true;
                }
            },
            else => {},
        }
        return false;
    }

    /// The bar's length in the display's own pixels: the charge times the bar's scale, rounded as
    /// `0x004C3330` does, and nothing for less than nothing.
    pub fn bar(charge: Charge, kind: Device) i32 {
        const length = @as(f32, @floatFromInt(charge.ticks)) * kind.spec().bar_scale;
        return if (length < 0) 0 else round(length);
    }
};

/// The colour the charge bars are drawn in: `hud_colour(0xE7, 0x68, 0x00)` (`0x0048D780`).
pub const bar_colour: [4]f32 = .{ 0xE7.0 / 255.0, 0x68.0 / 255.0, 0, 1 };

/// Whether the mission has a jump or a warp ready for JUMP DRIVE: `jump_ready` (`0x0052A3F0`) and
/// `warp_ready` (`0x0052A3F4`). The mission sets one to `newly`, the prompt moves it on to
/// `shown`, and JUMP DRIVE (`player_jump`, `0x00412B20`) clears it as it posts the event.
pub const Ready = enum(i32) {
    no = 0,
    newly = 1,
    shown = 2,
    _,
};

/// The display's own state: `hud.cpp`'s globals, as `hud_init` sets them when it sets the display
/// up. The mission's start then fits the devices to the player's ship.
pub const State = struct {
    devices: std.EnumArray(Device, Charge) = .init(.{
        .ecm = .full(.ecm),
        .cloak = .full(.cloak),
        .spectral_shields = .full(.spectral_shields),
    }),
    /// `blind_fire_fitted` (`0x00566F8C`): whether the ship carries blind fire.
    blind_fire_fitted: bool = false,
    /// `blind_fire` (`0x00579990`), which TOGGLE BLINDFIRE flips.
    blind_fire: bool = true,
    /// `smart_targeting` (`0x0056996C`), which SMART TARGET flips.
    smart_targeting: bool = false,
    /// `enemy_lock` (`0x00579988`): whether an enemy has a missile lock on the player.
    /// `mission_frame` sets it each frame when a ship whose order is Fight, against the player,
    /// has byte `0x2F` of its fight state set. **Unverified:** that the byte is a missile lock;
    /// nothing in the payload writes it at that offset, and the light's shape is a ship in a
    /// sight.
    enemy_lock: bool = false,
    /// `player_ejected` (`0x00579986`), which the Eject Player order sets.
    ejected: bool = false,
    icons: Icons = .{},
    /// The count the lock and missile warnings flash by (`0x0057BC44`), which the two share.
    warning_ticks: i32 = 0,
    /// The count the eject marker flashes by (`0x00569938`), which the Eject Player order starts
    /// again.
    eject_ticks: i32 = 0,
    /// The count the jump prompt flashes by (`0x00566790`).
    prompt_ticks: i32 = 0,
    /// The scanner's frame (`0x0057BC34`), 0 to 4, and the tick it next moves on at
    /// (`0x005667B0`).
    scanner_frame: u8 = 0,
    scanner_next: u32 = 0,
    /// Where blind fire's sight stands (`0x00566628`, `0x0056662C`), which `hud_init` puts at
    /// the middle of the screen; null until the port first draws it there.
    sight: ?[2]i32 = null,
    /// The radar's rings (`0x0057BC50`).
    radar_rings: u16 = Radar.first_rings,
    /// The radar's range (`radar_range`, `0x0057BE00`), 0 the closest.
    radar_range: u2 = Radar.first_range,
    /// The rings moving to a new range's, or null while they are still.
    radar_zoom: ?Radar.Zoom = null,
    /// The display's windows (`0x00501D30`).
    windows: windows.Windows = .{},

    /// `hud_draw`'s work on the devices' charges for a frame, which it does in every view: a
    /// device that runs dry is turned off.
    pub fn runCharges(state: *State, object: *gameobj.GameObject, frame_duration: i32, multiplayer: bool) void {
        if (state.devices.getPtr(.ecm).run(.ecm, frame_duration)) input.setEcm(state, object, false);
        // The cloak's charge runs only outside a multiplayer game. `player_cloak_set` uncloaks
        // the ship; the cloak itself is not ported yet (`cloak.cpp`), so only its setting goes.
        if (!multiplayer and state.devices.getPtr(.cloak).run(.cloak, frame_duration)) {
            state.devices.getPtr(.cloak).setting = .off;
        }
        if (state.devices.getPtr(.spectral_shields).run(.spectral_shields, frame_duration)) {
            input.setSpectralShields(state, object, false);
        }
    }

    /// Which lights' conditions hold for the player's `object`, tested as `hud_draw` tests them,
    /// in its order: an icon's flash moves on only when `hud_draw` asks for it. `matching` is
    /// `matching_speed`.
    pub fn lit(state: *State, object: *const gameobj.GameObject, matching: bool, multiplayer: bool, frame_duration: i32) Lit {
        const homing = object.missile_homing != 0;
        var found: Lit = .{};
        found.match_speed = matching;
        found.blind_fire = state.blind_fire_fitted and state.blind_fire and !object.gun_mode.all;
        found.smart_targeting = state.smart_targeting or state.icons.lit(.smart_targeting, frame_duration);
        found.enemy_lock = (state.enemy_lock and !homing) or state.icons.lit(.enemy_lock, frame_duration);
        found.missile_incoming = homing or state.icons.lit(.missile_incoming, frame_duration);
        found.ecm = state.devices.get(.ecm).setting == .on or state.icons.lit(.ecm, frame_duration);
        found.cloak = !multiplayer and state.devices.get(.cloak).setting != .absent;
        found.spectral_shields = state.devices.get(.spectral_shields).setting == .on;
        found.reverse_thrust = object.reverse_thrust;
        return found;
    }

    /// Whether `hud_draw` draws `readout` in a frame of `frame_duration`: the countermeasures only
    /// while their icon is not flashing them dark.
    pub fn shows(state: *State, readout: Readout, frame_duration: i32) bool {
        return switch (readout) {
            .coil => state.icons.slots[@intFromEnum(Icon.countermeasures)].state == .off or
                state.icons.lit(.countermeasures, frame_duration),
            else => true,
        };
    }

    /// Draws the lights `lit` has, each in the next place of the grid, the warnings flashing and
    /// the devices' charges as bars under their lights.
    pub fn drawLights(
        state: *State,
        art: *Art,
        gpa: Allocator,
        target: device.Device,
        screen: [2]u32,
        shown: Lit,
        frame_duration: i32,
        colour: [4]f32,
        scale: f32,
    ) (spr.Error || Allocator.Error)!void {
        var index: i32 = 0;
        inline for (comptime std.enums.values(Light)) |light| {
            if (@field(shown, @tagName(light))) {
                const at = gridPlace(screen, index, scale);
                index += 1;
                const drawn = switch (light) {
                    .enemy_lock => Flash.slow.step(&state.warning_ticks, frame_duration),
                    .missile_incoming => Flash.fast.step(&state.warning_ticks, frame_duration),
                    else => true,
                };
                if (drawn) try drawShape(art, gpa, target, @intFromEnum(light), at, colour, scale);
                if (comptime light.charged()) |kind| {
                    drawBar(target, at, kind.spec().bar_down, state.devices.get(kind).bar(kind), scale);
                }
            }
        }
    }

    /// The prompt for JUMP DRIVE (`hud_jump_prompt`, `0x00482FA0`): the shape it draws in a frame
    /// of `frame_duration`, if any. A warp the mission has ready comes before a jump. The frame one
    /// becomes ready the prompt starts its flash and draws nothing.
    pub fn jumpPrompt(state: *State, ready: *Readiness, frame_duration: i32) ?u16 {
        const which: *Ready, const shape: u16 = if (ready.warp != .no)
            .{ &ready.warp, JumpPrompt.warp_shape }
        else
            .{ &ready.jump, JumpPrompt.jump_shape };
        switch (which.*) {
            .newly => {
                state.prompt_ticks = 0;
                which.* = .shown;
                return null;
            },
            .shown => return if (Flash.slow.step(&state.prompt_ticks, frame_duration)) shape else null,
            else => return null,
        }
    }

    /// Draws the jump prompt, flashing above the middle of the screen.
    pub fn drawJumpPrompt(
        state: *State,
        ready: *Readiness,
        art: *Art,
        gpa: Allocator,
        target: device.Device,
        screen: [2]u32,
        frame_duration: i32,
        colour: [4]f32,
        scale: f32,
    ) (spr.Error || Allocator.Error)!void {
        const shape = state.jumpPrompt(ready, frame_duration) orelse return;
        try drawShape(art, gpa, target, shape, place(screen, JumpPrompt.offset, 0.5, 0.5, scale), colour, scale);
    }

    /// The eject marker (`hud_eject_marker`, `0x004830B0`): the pilot rising out of the ship,
    /// flashing under the middle of the screen once the player has ejected, or while its icon is
    /// lit.
    pub fn drawEjectMarker(
        state: *State,
        art: *Art,
        gpa: Allocator,
        target: device.Device,
        screen: [2]u32,
        frame_duration: i32,
        colour: [4]f32,
        scale: f32,
    ) (spr.Error || Allocator.Error)!void {
        if (!state.ejected and !state.icons.lit(.ejected, frame_duration)) return;
        const at = scaled(place(screen, marker_offset, 0.5, 0.5, scale), .{ 0, 0x26 }, scale);
        if (Flash.slow.step(&state.eject_ticks, frame_duration)) {
            try drawShape(art, gpa, target, eject_shape, at, colour, scale);
        }
    }

    /// The scanner (`hud_scanner`, `0x00489250`): while the `Scanner` mission command has the
    /// player look for an object, a hand and the rings it sends out, drawn over the middle of the
    /// screen in five frames.
    pub fn drawScanner(
        state: *State,
        scanning: bool,
        game_ticks: u32,
        art: *Art,
        gpa: Allocator,
        target: device.Device,
        screen: [2]u32,
        colour: [4]f32,
        scale: f32,
    ) (spr.Error || Allocator.Error)!void {
        if (!scanning) return;
        const at = place(screen, marker_offset, 0.5, 0.5, scale);
        try drawShape(art, gpa, target, scanner_shape + state.scannerFrame(game_ticks), at, colour, scale);
    }

    /// The scanner's frame at `game_ticks`: the next, going round, once `game_ticks` is past the
    /// tick it waits for, which is then 25 on.
    pub fn scannerFrame(state: *State, game_ticks: u32) u8 {
        if (state.scanner_next < game_ticks) {
            state.scanner_next = game_ticks + scanner_step;
            state.scanner_frame = if (state.scanner_frame >= scanner_frames - 1) 0 else state.scanner_frame + 1;
        }
        return state.scanner_frame;
    }
};

/// What the mission has ready for JUMP DRIVE.
pub const Readiness = struct {
    jump: Ready = .no,
    warp: Ready = .no,
};

/// Where the jump prompt stands, from the middle of the screen, and its two shapes.
pub const JumpPrompt = struct {
    pub const offset: [2]i32 = .{ -16, -90 };
    pub const warp_shape: u16 = 0xC9;
    pub const jump_shape: u16 = 0xCE;
};

/// Where the eject marker and the scanner stand, from the middle of the screen; the marker hangs
/// `0x26` below.
pub const marker_offset: [2]i32 = .{ -16, -100 };
pub const eject_shape: u16 = 0xC2;
pub const scanner_shape: u16 = 0xD1;
pub const scanner_frames = 5;
pub const scanner_step = 25;

/// A charge's bar: a line of the display's pixels `down` below the light's point, from one right
/// of it to `length` further, both ends drawn as `VFX_line_draw` draws them.
fn drawBar(target: device.Device, at: [2]i32, down: i32, length: i32, scale: f32) void {
    const left = @as(f32, @floatFromInt(at[0])) + scale;
    const top = @as(f32, @floatFromInt(at[1])) + @as(f32, @floatFromInt(down)) * scale;
    const right = left + @as(f32, @floatFromInt(length + 1)) * scale;
    const bottom = top + scale;
    const tint = device.pack(bar_colour);
    const corners = [4]device.Vertex{
        .{ .x = left, .y = top, .z = 1, .rhw = 1, .diffuse = tint },
        .{ .x = right, .y = top, .z = 1, .rhw = 1, .diffuse = tint },
        .{ .x = right, .y = bottom, .z = 1, .rhw = 1, .diffuse = tint },
        .{ .x = left, .y = bottom, .z = 1, .rhw = 1, .diffuse = tint },
    };
    target.draw(.{
        .texture = null,
        .depth = srd3d.depth(.overlay, .alpha),
        .blend = srd3d.factors(.alpha),
    }, .fan, &corners, null);
}

/// The keys of `hud_target_keys` (`0x0048B6B0`) ported: SMART TARGET, which flips smart
/// targeting, then MISSILE WINDOW, which opens the missile window held and, pressed again once it
/// is open, closes it, and outside a multiplayer game the keys that turn the missile ring, which
/// open it held too. `frame_controls` runs the routine for the targeting and missile keys, before
/// its own. Not yet ported: the targeting keys, turning the ring, and the display's sounds.
pub fn targetKeys(state: *State, devices: *input.Devices, multiplayer: bool) void {
    if (devices.active(.smart_target, true)) {
        state.smart_targeting = !state.smart_targeting;
    }
    const missiles = state.windows.status.getPtr(.missiles);
    if (devices.active(.missile_window, true)) {
        switch (missiles.phase) {
            .shut => if (state.windows.open(.missiles, multiplayer)) {
                missiles.held = true;
            },
            .open => {
                missiles.held = false;
                state.windows.close(.missiles);
            },
            .opening, .closing => {},
        }
    }
    if (multiplayer) return;
    for ([_]input.controls.Action{ .rotate_missiles_clockwise, .rotate_missiles_anticlockwise }) |action| {
        if (!devices.active(action, true)) continue;
        if (state.windows.open(.missiles, multiplayer)) missiles.held = true;
    }
}

test Flash {
    // The slow flash is lit for its first 50 ticks, dark to 100, and past that starts again dark.
    var ticks: i32 = 0;
    try std.testing.expect(Flash.slow.step(&ticks, 49));
    try std.testing.expect(!Flash.slow.step(&ticks, 1));
    try std.testing.expect(!Flash.slow.step(&ticks, 50));
    try std.testing.expectEqual(100, ticks);
    try std.testing.expect(!Flash.slow.step(&ticks, 1));
    try std.testing.expectEqual(0, ticks);
    try std.testing.expect(Flash.slow.step(&ticks, 1));
    // The fast one runs at twice the pace.
    ticks = 24;
    try std.testing.expect(!Flash.fast.step(&ticks, 1));
}

test Icons {
    var icons: Icons = .{};
    // Off, an icon is dark; on, it is lit and its count stands still.
    try std.testing.expect(!icons.lit(.ecm, 10));
    icons.show(.ecm, .on);
    try std.testing.expect(icons.lit(.ecm, 10));
    try std.testing.expectEqual(0, icons.slots[2].ticks);
    // Flashing, it is lit to 50 and dark to 100, and what runs past 100 carries over, lit.
    icons.show(.ecm, .flash);
    try std.testing.expect(icons.lit(.ecm, 49));
    try std.testing.expect(!icons.lit(.ecm, 1));
    try std.testing.expect(icons.lit(.ecm, 60));
    try std.testing.expectEqual(10, icons.slots[2].ticks);
    // Setting it again starts the flash over.
    icons.show(.ecm, .flash);
    try std.testing.expectEqual(0, icons.slots[2].ticks);
    // Past the table, an icon is left alone.
    icons.show(@enumFromInt(25), .on);
    try std.testing.expect(!icons.lit(@enumFromInt(25), 1));
}

test Charge {
    // Each device starts carried, off and full, and its bar is then about 32 pixels long.
    for (std.enums.values(Device)) |kind| {
        const charge: Charge = .full(kind);
        try std.testing.expectEqual(.off, charge.setting);
        try std.testing.expectEqual(32, charge.bar(kind));
    }
    // On, the spectral shields spend six ticks a tick, so ten seconds run them dry.
    var shields: Charge = .full(.spectral_shields);
    shields.setting = .on;
    try std.testing.expect(!shields.run(.spectral_shields, 999));
    try std.testing.expectEqual(6, shields.ticks);
    try std.testing.expect(shields.run(.spectral_shields, 2));
    try std.testing.expectEqual(0, shields.ticks);
    try std.testing.expectEqual(0, shields.bar(.spectral_shields));
    // Off, a device charges a tick a tick and stops at full.
    shields.setting = .off;
    try std.testing.expect(!shields.run(.spectral_shields, 7000));
    try std.testing.expectEqual(6000, shields.ticks);
    // A device the ship does not carry neither charges nor drains.
    var absent: Charge = .{ .setting = .absent, .ticks = 5 };
    try std.testing.expect(!absent.run(.ecm, 100));
    try std.testing.expectEqual(5, absent.ticks);
}

test "the lights hold as hud_draw tests them" {
    var state: State = .{};
    var object: gameobj.GameObject = std.mem.zeroes(gameobj.GameObject);
    // A ship that carries every device but has none on shows only its cloak.
    try std.testing.expectEqual(Lit{ .cloak = true }, state.lit(&object, false, false, 1));
    // ... and not even that in a multiplayer game.
    try std.testing.expectEqual(Lit{}, state.lit(&object, false, true, 1));

    // Blind fire, carried and on, shows while the guns are not all firing.
    state.blind_fire_fitted = true;
    try std.testing.expect(state.lit(&object, false, true, 1).blind_fire);
    object.gun_mode.all = true;
    try std.testing.expect(!state.lit(&object, false, true, 1).blind_fire);

    // A missile homing on the ship takes the lock warning's place.
    state.enemy_lock = true;
    try std.testing.expect(state.lit(&object, false, true, 1).enemy_lock);
    object.missile_homing = 1;
    const both = state.lit(&object, false, true, 1);
    try std.testing.expect(!both.enemy_lock and both.missile_incoming);

    // The spectral shields show only while on; an icon lights the ECM's light without it.
    state.devices.getPtr(.spectral_shields).setting = .on;
    try std.testing.expect(state.lit(&object, false, true, 1).spectral_shields);
    try std.testing.expect(!state.lit(&object, false, true, 1).ecm);
    state.icons.show(.ecm, .on);
    try std.testing.expect(state.lit(&object, false, true, 1).ecm);
}

test "an icon flashes only as it is asked for" {
    // `hud_draw` asks for the smart targeting icon only while smart targeting is off.
    var state: State = .{};
    const object: gameobj.GameObject = std.mem.zeroes(gameobj.GameObject);
    state.icons.show(.smart_targeting, .flash);
    state.smart_targeting = true;
    _ = state.lit(&object, false, false, 30);
    try std.testing.expectEqual(0, state.icons.slots[4].ticks);
    state.smart_targeting = false;
    _ = state.lit(&object, false, false, 30);
    try std.testing.expectEqual(30, state.icons.slots[4].ticks);
}

test "the countermeasures readout flashes with its icon" {
    var state: State = .{};
    try std.testing.expect(state.shows(.coil, 10));
    state.icons.show(.countermeasures, .flash);
    try std.testing.expect(state.shows(.coil, 49));
    try std.testing.expect(!state.shows(.coil, 1));
    // The other readouts have no icon.
    try std.testing.expect(state.shows(.fuel, 1));
}

test "the jump prompt waits a frame, and a warp comes first" {
    var state: State = .{ .prompt_ticks = 70 };
    var ready: Readiness = .{ .jump = .newly, .warp = .newly };
    // The first frame starts the warp's flash and draws nothing; the jump waits its turn.
    try std.testing.expectEqual(null, state.jumpPrompt(&ready, 10));
    try std.testing.expectEqual(.shown, ready.warp);
    try std.testing.expectEqual(.newly, ready.jump);
    try std.testing.expectEqual(0, state.prompt_ticks);
    // Then the warp's shape flashes.
    try std.testing.expectEqual(JumpPrompt.warp_shape, state.jumpPrompt(&ready, 10));
    try std.testing.expectEqual(null, state.jumpPrompt(&ready, 40));
    // With the warp taken, the jump comes up.
    ready.warp = .no;
    try std.testing.expectEqual(null, state.jumpPrompt(&ready, 10));
    try std.testing.expectEqual(JumpPrompt.jump_shape, state.jumpPrompt(&ready, 10));
}

test "the scanner moves on once 25 ticks have passed" {
    var state: State = .{};
    // It moves on at the first tick past the one it waits for, so a frame lasts 26 ticks.
    var frames: [7]u8 = undefined;
    for (&frames, 0..) |*frame, step| frame.* = state.scannerFrame(@intCast(1 + step * (scanner_step + 1)));
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 0, 1, 2 }, &frames);
    try std.testing.expectEqual(2, state.scannerFrame(state.scanner_next));
    try std.testing.expectEqual(3, state.scannerFrame(state.scanner_next + 1));
}

/// The ship status indicator (`hud_ship_status`, `0x00489350`): the ship's own schematic, and its
/// shields as four arcs around it. `hud_draw` places it 0.3 of the way across, at the foot of the
/// screen, 2 right and 44 up.
pub const ShipStatus = struct {
    pub const offset: [2]i32 = .{ 2, -44 };
    pub const across: f32 = 0.3;
    pub const down: f32 = 1;

    /// Where the schematic hangs from the indicator's point: shape 0 of the ship type's own sprite,
    /// its `type_data`, which for a ship is its schematic.
    pub const schematic_offset: [2]i32 = .{ -0x22, -0x1B };

    /// One arc of the ring: where it hangs from the point, and the shape a level of 0 would be,
    /// each level above it drawing the shape one before. Five shapes an arc.
    pub const Arc = struct { offset: [2]i32, base: u16 };

    /// The arcs in the order of the object's `shields`, as `hud_draw`'s call draws them: the first
    /// at the left, then the right, the top and the foot.
    pub const arcs = [4]Arc{
        .{ .offset = .{ -0x2D, -0x14 }, .base = 0xAD },
        .{ .offset = .{ 0x1F, -0x14 }, .base = 0xA3 },
        .{ .offset = .{ -0x17, -0x1F }, .base = 0x9E },
        .{ .offset = .{ -0x22, 0x19 }, .base = 0xA8 },
    };

    /// How much of an arc is drawn: the quadrant's shield over the ship's shield power, cut down to
    /// a whole number as the runtime's `__ftol` does, less one. An arc of 0 or less is not drawn.
    /// A ship with no shield power has no arcs; the game divides by it regardless.
    pub fn level(shield: f32, shield_power: i32) i32 {
        if (shield_power == 0) return 0;
        const share = shield / @as(f32, @floatFromInt(shield_power));
        return @as(i32, @intFromFloat(std.math.clamp(@trunc(share), -1e9, 1e9))) - 1;
    }

    /// Draws the ship's schematic, the first thing `hud_ship_status` draws. The schematic is the
    /// ship's own, so it comes with an allocator of its own.
    pub fn drawSchematic(
        schematic: *Art,
        gpa: Allocator,
        target: device.Device,
        screen: [2]u32,
        colour: [4]f32,
        scale: f32,
    ) (spr.Error || Allocator.Error)!void {
        const point = place(screen, offset, across, down, scale);
        try drawShape(schematic, gpa, target, 0, scaled(point, schematic_offset, scale), colour, scale);
    }

    /// Draws the shields of a ship of `shields` and `shield_power` round its schematic.
    pub fn draw(
        art: *Art,
        gpa: Allocator,
        target: device.Device,
        screen: [2]u32,
        shields: [4]f32,
        shield_power: i32,
        colour: [4]f32,
        scale: f32,
    ) (spr.Error || Allocator.Error)!void {
        const point = place(screen, offset, across, down, scale);
        for (arcs, shields) |arc, shield| {
            const drawn = level(shield, shield_power);
            if (drawn <= 0) continue;
            const shape = @as(i32, arc.base) - drawn;
            if (shape < 0) continue;
            try drawShape(art, gpa, target, @intCast(shape), scaled(point, arc.offset, scale), colour, scale);
        }
    }
};

test ShipStatus {
    // A ship is created with 6 times its shield power, less one, in each quadrant: four arcs of
    // the five, which is what a quadrant keeps until its shield charges the rest of the way.
    try std.testing.expectEqual(4, ShipStatus.level(6 * 3 - 1, 3));
    try std.testing.expectEqual(5, ShipStatus.level(6 * 3, 3));
    // Down to under twice the power, none are left.
    try std.testing.expectEqual(0, ShipStatus.level(5, 3));
    // The runtime cuts toward zero rather than rounding.
    try std.testing.expectEqual(1, ShipStatus.level(2.99 * 3, 3));
    try std.testing.expectEqual(0, ShipStatus.level(10, 0));

    // Each arc's five shapes follow on from the last's, the first arc's from 0x99.
    var shapes: [4 * 5]u16 = undefined;
    var at: usize = 0;
    for (ShipStatus.arcs) |arc| {
        for (1..6) |l| {
            shapes[at] = arc.base - @as(u16, @intCast(l));
            at += 1;
        }
    }
    std.mem.sort(u16, &shapes, {}, std.sort.asc(u16));
    for (shapes, 0..) |shape, i| try std.testing.expectEqual(0x99 + i, shape);
}

// --- The targeting cluster -------------------------------------------------------------------

/// The targeting cluster about the middle of the screen, which `hud_draw` draws in view 0 after
/// the ship status indicator: an arc either side, the left one for the speed and the right one
/// for the guns' charge, each lit from the foot up to its level; a marker on the left arc for the
/// speed the ship makes and another for the speed its throttle asks, each with its figure; and
/// the reticle at the middle.
pub const Cluster = struct {
    /// The left arc; the right one is the same shape drawn mirrored.
    pub const arc_shape: u16 = 0x7F;
    /// How far either arc stands from the middle: this share of the screen's width, cut down to
    /// a whole number as `__ftol` does. The arcs part as the screen widens.
    pub const spread: f32 = 0.15625;
    /// How far above the middle the arcs' tops stand.
    pub const up: i32 = 0x4A;
    /// How far left of its place the right arc is drawn, near the arc's own width.
    pub const mirror_shift: i32 = 0x43;
    /// The centre of the circle the markers ride, from the left arc's point, and how far out
    /// across and down they ride from it.
    pub const circle: [2]i32 = .{ 100, 80 };
    pub const reach: [2]f32 = .{ 124, 94 };
    /// A marker's angle, in degrees: 310 at nothing, less 100 at full.
    pub const empty_angle: f32 = 310;
    pub const sweep: f32 = 100;
    pub const marker_shape: u16 = 0xEA;
    /// Where a marker's figure stands from the marker, ending there.
    pub const figure_offset: [2]i32 = .{ -10, -8 };
    /// The throttle's marker shows while the throttle differs from the speed by more than this,
    /// three times over, and as bright as that, to full.
    pub const throttle_shown: f32 = 0.1;
    pub const throttle_fade: f32 = 3;

    /// An arc's fill: the lit shape below the level and the unlit one above it, both drawn at
    /// `offset` from the arc's point, into two panes a pixel above and left of it, `pane_width`
    /// wide and down to `pane_bottom` below the arcs' top.
    pub const Fill = struct { lit: u16, unlit: u16, offset: [2]i32 };
    pub const speed_fill: Fill = .{ .lit = 0xB8, .unlit = 0xB9, .offset = .{ -10, 0 } };
    pub const charge_fill: Fill = .{ .lit = 0xF9, .unlit = 0xF8, .offset = .{ 14, 0 } };
    pub const pane_width: i32 = 0x42;
    pub const pane_bottom: i32 = 0x8A;
    /// The charge arc's height in pixels, all of it lit when the guns are full.
    pub const charge_height: f32 = 0x8A;

    /// What the cluster shows: the object's throttle and speed, its type's top speed, and its
    /// guns' charge against the most it holds.
    pub const Gauges = struct {
        throttle: f32,
        speed: f32,
        max_speed: f32,
        charge: f32,
        full_charge: f32,
    };

    /// Where a marker for `share` of the arc stands from the circle's centre, in the display's
    /// own pixels, rounded as `0x004C3330` does.
    pub fn markerOffset(share: f32) [2]i32 {
        const angle = (empty_angle - share * sweep) * std.math.rad_per_deg;
        return .{ round(@sin(angle) * reach[0]), round(@cos(angle) * reach[1]) };
    }

    /// How far down from the arcs' top the charge arc is unlit: all of it for no charge, none
    /// for a full one. A ship whose guns hold nothing has it all unlit; the game divides by the
    /// nothing regardless.
    pub fn chargeLevel(charge: f32, full: f32) i32 {
        if (full <= 0) return @intFromFloat(charge_height);
        return @as(i32, @intFromFloat(charge_height)) - round(charge * charge_height / full);
    }

    /// The throttle and the speed as shares of the arc: the throttle's size to 1, and the speed
    /// over the top speed to 1.
    pub fn shares(gauges: Gauges) [2]f32 {
        const throttle = @min(@abs(gauges.throttle), 1);
        const speed = if (gauges.max_speed > 0) @min(gauges.speed / gauges.max_speed, 1) else 0;
        return .{ throttle, speed };
    }
};

/// Draws the targeting cluster's arcs and markers as `hud_draw` does, from its right arc to the
/// charge's fill.
pub fn drawCluster(
    art: *Art,
    opened: *Opened,
    gpa: Allocator,
    target: device.Device,
    screen: [2]u32,
    gauges: Cluster.Gauges,
    colour: [4]f32,
    scale: f32,
) (spr.Error || Allocator.Error)!void {
    const width: i32 = @intCast(screen[0]);
    const height: i32 = @intCast(screen[1]);
    const apart: i32 = @intFromFloat(@trunc(@as(f32, @floatFromInt(width)) * Cluster.spread));
    const top = (height >> 1) - round(@as(f32, Cluster.up) * scale);
    const left: [2]i32 = .{ (width >> 1) - apart, top };
    const right: [2]i32 = .{ (width >> 1) + apart - round(@as(f32, Cluster.mirror_shift) * scale), top };
    try drawShapeWith(art, gpa, target, Cluster.arc_shape, right, colour, scale, .{ .mirror = .{ .across = true } });
    try drawShape(art, gpa, target, Cluster.arc_shape, left, colour, scale);

    const centre = scaled(left, Cluster.circle, scale);
    const throttle, const speed = Cluster.shares(gauges);
    var buffer: [16]u8 = undefined;

    // The throttle's marker, dimmed as it nears the speed: `hud_draw` makes the global palette
    // that much darker for it.
    const brightness = @min(@abs(throttle - speed) * Cluster.throttle_fade, 1);
    if (brightness > Cluster.throttle_shown) {
        const dim: [4]f32 = .{ colour[0] * brightness, colour[1] * brightness, colour[2] * brightness, colour[3] };
        const marker = scaled(centre, Cluster.markerOffset(throttle), scale);
        try drawShape(art, gpa, target, Cluster.marker_shape, marker, dim, scale);
        const asked = std.fmt.bufPrint(&buffer, "{d}", .{round(gauges.max_speed * gauges.throttle)}) catch return;
        _ = try drawText(opened, gpa, target, scaled(marker, Cluster.figure_offset, scale), asked, dim, .right, scale);
    }

    const offset = Cluster.markerOffset(speed);
    const marker = scaled(centre, offset, scale);
    try drawShape(art, gpa, target, Cluster.marker_shape, marker, colour, scale);
    const made = std.fmt.bufPrint(&buffer, "{d}", .{round(gauges.speed)}) catch return;
    _ = try drawText(opened, gpa, target, scaled(marker, Cluster.figure_offset, scale), made, colour, .right, scale);

    // The speed's fill is lit below its marker, the charge's below its level.
    try drawFill(art, gpa, target, Cluster.speed_fill, left, offset[1] + Cluster.circle[1], colour, scale);
    try drawFill(art, gpa, target, Cluster.charge_fill, right, Cluster.chargeLevel(gauges.charge, gauges.full_charge), colour, scale);
}

/// An arc's fill for `level` pixels down from the arcs' top: the lit shape into the pane from
/// a pixel above the level to the foot, then the unlit one into the pane from a pixel above the
/// top to the level, so the row they share is unlit.
fn drawFill(
    art: *Art,
    gpa: Allocator,
    target: device.Device,
    fill: Cluster.Fill,
    arc: [2]i32,
    level: i32,
    colour: [4]f32,
    scale: f32,
) (spr.Error || Allocator.Error)!void {
    const at = scaled(arc, fill.offset, scale);
    const x: f32 = @floatFromInt(at[0]);
    const y: f32 = @floatFromInt(at[1]);
    const edge = struct {
        fn of(from: f32, pixels: i32, by: f32) f32 {
            return from + @as(f32, @floatFromInt(pixels)) * by;
        }
    }.of;
    const pane_left = x - scale;
    const pane_right = edge(x, Cluster.pane_width - 1, scale);
    try drawShapeWith(art, gpa, target, fill.lit, at, colour, scale, .{ .clip = .{
        .left = pane_left,
        .top = edge(y, level - 1, scale),
        .right = pane_right,
        .bottom = edge(y, Cluster.pane_bottom, scale),
    } });
    try drawShapeWith(art, gpa, target, fill.unlit, at, colour, scale, .{ .clip = .{
        .left = pane_left,
        .top = y - scale,
        .right = pane_right,
        .bottom = edge(y, level, scale),
    } });
}

/// The reticle at the middle of the screen, and blind fire's sight: the same shape brighter, which
/// jumps onto a target near the middle while blind fire aims the guns at it and glides back.
pub const reticle_shape: u16 = 0xD7;
pub const sight_shape: u16 = 0xD8;
/// How near the middle a target stands for the reticle to be drawn bright: within `0x10` either
/// way.
pub const under_reticle: i32 = 0x10;
/// How near the middle blind fire takes a target: within `0x46` across and `0x32` down.
pub const blind_fire_reach: [2]i32 = .{ 0x46, 0x32 };
/// How near the middle the sight comes to rest, gliding a pixel a tick.
pub const sight_rest: i32 = 2;

/// What blind fire does about a target near the middle.
pub const BlindFire = enum {
    /// The ship does not carry it, it is off, or every group of guns fires on a ship of more
    /// than one.
    off,
    /// It aims the guns at the target.
    on,
    /// It is on, but the chosen group's first gun is of type 11, which it does not aim.
    excluded,
};

/// Draws the reticle as `hud_draw` does in view 0, for a target standing at `target_at` on the
/// screen, if one does, and says whether blind fire aims at it, which the game keeps as the
/// object's `blind_fire_aim`. The chase view draws neither the reticle nor the sight.
pub fn drawReticle(
    state: *State,
    art: *Art,
    gpa: Allocator,
    target: device.Device,
    screen: [2]u32,
    mode: camera.CockpitMode,
    target_at: ?[2]i32,
    blind_fire: BlindFire,
    frame_duration: i32,
    colour: [4]f32,
    scale: f32,
) (spr.Error || Allocator.Error)!bool {
    const middle: [2]i32 = .{ @as(i32, @intCast(screen[0])) >> 1, @as(i32, @intCast(screen[1])) >> 1 };
    const drawn = mode != .chase;
    if (drawn) try drawShape(art, gpa, target, reticle_shape, middle, colour, scale);
    const found = target_at orelse {
        if (drawn) try drawShape(art, gpa, target, reticle_shape, middle, colour, scale);
        return false;
    };
    const near = round(@as(f32, @floatFromInt(under_reticle)) * scale);
    var bright = found[0] > middle[0] - near and found[0] < middle[0] + near and
        found[1] > middle[1] - near and found[1] < middle[1] + near;
    const reach: [2]i32 = .{
        round(@as(f32, @floatFromInt(blind_fire_reach[0])) * scale),
        round(@as(f32, @floatFromInt(blind_fire_reach[1])) * scale),
    };
    const apart: [2]i32 = .{ found[0] - middle[0], found[1] - middle[1] };
    var at = middle;
    var aims = false;
    const within = @abs(apart[0]) < reach[0] and @abs(apart[1]) < reach[1];
    if (within and blind_fire == .on) {
        at = found;
        state.sight = found;
        aims = true;
        bright = true;
    } else if (!(within and blind_fire == .excluded)) {
        var sight = state.sight orelse middle;
        const rest = round(@as(f32, @floatFromInt(sight_rest)) * scale);
        const glide = round(@as(f32, @floatFromInt(frame_duration)) * scale);
        for (0..2) |axis| {
            if (sight[axis] < middle[axis] - rest) {
                sight[axis] += glide;
                at[axis] = sight[axis];
            } else if (sight[axis] > middle[axis] + rest) {
                sight[axis] -= glide;
                at[axis] = sight[axis];
            }
        }
        state.sight = sight;
    }
    if (drawn) try drawShape(art, gpa, target, if (bright) sight_shape else reticle_shape, at, colour, scale);
    return aims;
}

/// The radar (`hud_radar`, `0x00488BD0`): its rings, the shape `hud_init` starts on and the
/// range key steps through, stand from a point placed half of the way across, at the foot of the
/// screen, 1 right and 51 up. Not yet ported: the dots for the objects in range, with their
/// lines up or down to the rings, and the rings' change of range.
pub const Radar = struct {
    pub const offset: [2]i32 = .{ 1, -51 };
    pub const across: f32 = 0.5;
    pub const down: f32 = 1;
    /// Where the rings hang from the point.
    pub const rings_offset: [2]i32 = .{ -0x42, -0x20 };
    /// The rings `hud_init` starts on (`0x0057BC50`), the widest range's.
    pub const first_rings: u16 = 0x16B;
    /// The range `hud_init` starts on (`radar_range`, `0x0057BE00`), the widest.
    pub const first_range: u2 = 2;
    /// The rings each range comes to rest on, 0 the closest: one ring with the wedge of the view
    /// ahead, two, and three. The shapes between are the steps between them.
    pub const range_rings = [3]u16{ 0x161, 0x166, 0x16B };
    /// The ticks `hud_radar_zoom` keeps its next step ahead of `game_ticks`.
    pub const zoom_ticks: u32 = 50;

    /// The rings moving to a new range's: the shape they stop at (`radar_zoom_rings`,
    /// `0x005799B4`), whether they step down toward it (`radar_zoom_down`, `0x005656AC`), and the
    /// tick the step waits to be short of (`radar_zoom_next`, `0x005656A0`). `radar_zooming`
    /// (`0x00569714`) is set while they move.
    pub const Zoom = struct {
        to: u16,
        down: bool,
        next: u32,
    };
};

/// RADAR RANGES (`frame_controls`, `0x00414060`): in the view ahead from the cockpit, with the
/// rings still, the radar moves to its next range, round from the widest to the closest, and its
/// rings start moving to that range's.
pub fn nextRadarRange(state: *State, view: camera.View, game_ticks: u32) void {
    if (view != .cockpit or state.radar_zoom != null) return;
    state.radar_range = if (state.radar_range >= 2) 0 else state.radar_range + 1;
    state.radar_zoom = .{
        .to = Radar.range_rings[state.radar_range],
        .down = state.radar_range == 0,
        .next = game_ticks + Radar.zoom_ticks,
    };
}

/// `hud_radar_zoom` (`0x004892F0`), which `hud_draw` runs after the radar: while the rings are
/// moving, a step toward the range's. It steps while `game_ticks` is short of the tick it keeps
/// `zoom_ticks` ahead, and puts that tick ahead again as it steps, so the rings step once each
/// frame the radar is drawn.
pub fn stepRadarZoom(state: *State, game_ticks: u32) void {
    const zoom = &(state.radar_zoom orelse return);
    if (@as(i32, @bitCast(zoom.next)) <= @as(i32, @bitCast(game_ticks))) return;
    zoom.next = game_ticks +% Radar.zoom_ticks;
    if (zoom.down) state.radar_rings -= 1 else state.radar_rings += 1;
    if (state.radar_rings == zoom.to) state.radar_zoom = null;
}

/// Draws the radar's rings for a window of `screen`.
pub fn drawRadar(
    art: *Art,
    gpa: Allocator,
    target: device.Device,
    screen: [2]u32,
    rings: u16,
    colour: [4]f32,
    scale: f32,
) (spr.Error || Allocator.Error)!void {
    const point = place(screen, Radar.offset, Radar.across, Radar.down, scale);
    try drawShape(art, gpa, target, rings, scaled(point, Radar.rings_offset, scale), colour, scale);
}

test nextRadarRange {
    var state: State = .{};
    // From the widest range the key comes round to the closest, whose rings are one; the rings
    // step there a shape a frame.
    nextRadarRange(&state, .cockpit, 1000);
    try std.testing.expectEqual(0, state.radar_range);
    for (0..9) |_| stepRadarZoom(&state, 1000);
    try std.testing.expectEqual(0x162, state.radar_rings);
    // While they move, the key does nothing.
    nextRadarRange(&state, .cockpit, 1000);
    try std.testing.expectEqual(0, state.radar_range);
    stepRadarZoom(&state, 1000);
    try std.testing.expectEqual(0x161, state.radar_rings);
    try std.testing.expectEqual(null, state.radar_zoom);
    // The next range steps up to two rings; outside the view ahead the key does nothing.
    nextRadarRange(&state, .cockpit_rear, 1000);
    try std.testing.expectEqual(0, state.radar_range);
    nextRadarRange(&state, .cockpit, 1000);
    for (0..5) |_| stepRadarZoom(&state, 1000);
    try std.testing.expectEqual(0x166, state.radar_rings);
    try std.testing.expectEqual(null, state.radar_zoom);
}

test Cluster {
    // At nothing a marker rides the foot of the left arc, left of the circle's centre and below
    // it; at full it rides near the top.
    const empty = Cluster.markerOffset(0);
    try std.testing.expect(empty[0] < 0 and empty[1] > 0);
    const full = Cluster.markerOffset(1);
    try std.testing.expect(full[0] < 0 and full[1] < 0);
    try std.testing.expectEqual([2]i32{ -95, 60 }, empty);
    // Full guns light the whole charge arc; none light nothing of it.
    try std.testing.expectEqual(0, Cluster.chargeLevel(50, 50));
    try std.testing.expectEqual(0x8A, Cluster.chargeLevel(0, 50));
    try std.testing.expectEqual(0x8A / 2, Cluster.chargeLevel(25, 50));
    try std.testing.expectEqual(0x8A, Cluster.chargeLevel(10, 0));
    // The throttle counts by its size, the speed by its share of the top speed, each to 1.
    try std.testing.expectEqual([2]f32{ 1, 0.5 }, Cluster.shares(.{ .throttle = -1.5, .speed = 50, .max_speed = 100, .charge = 0, .full_charge = 0 }));
    try std.testing.expectEqual([2]f32{ 0.25, 1 }, Cluster.shares(.{ .throttle = 0.25, .speed = 300, .max_speed = 100, .charge = 0, .full_charge = 0 }));
}

test "the arcs part as the screen widens" {
    // At 640 across the arcs stand 100 either side of the middle; at 1024, 160.
    const narrow: i32 = @intFromFloat(@trunc(640 * Cluster.spread));
    const wide: i32 = @intFromFloat(@trunc(1024 * Cluster.spread));
    try std.testing.expectEqual(100, narrow);
    try std.testing.expectEqual(160, wide);
}

test "the sight glides back to the middle" {
    var state: State = .{ .sight = .{ 300, 250 } };
    const screen: [2]u32 = .{ 640, 480 };
    // With a target off the reach of blind fire, the sight moves a pixel a tick toward the
    // middle, and rests within two of it.
    const Null = struct {
        fn begin(_: *anyopaque) void {}
        fn end(_: *anyopaque) void {}
        fn mark(_: *anyopaque) void {}
        fn draw(_: *anyopaque, _: device.State, _: device.Primitive, _: []const device.Vertex, _: ?[]const u16) void {}
    };
    var nothing: u8 = 0;
    const target: device.Device = .{ .ptr = &nothing, .vtable = &.{ .begin = Null.begin, .end = Null.end, .draw = Null.draw, .overlay = Null.mark } };
    var art: Art = .{ .set = undefined, .images = &.{} };
    const aims = try drawReticle(&state, &art, std.testing.allocator, target, screen, .chase, .{ 600, 400 }, .on, 10, .{ 1, 1, 1, 1 }, 1);
    try std.testing.expect(!aims);
    try std.testing.expectEqual([2]i32{ 310, 240 }, state.sight.?);
    // Within its reach, blind fire takes the target.
    try std.testing.expect(try drawReticle(&state, &art, std.testing.allocator, target, screen, .chase, .{ 350, 260 }, .on, 10, .{ 1, 1, 1, 1 }, 1));
    try std.testing.expectEqual([2]i32{ 350, 260 }, state.sight.?);
    // A gun it does not aim leaves the sight where it is.
    _ = try drawReticle(&state, &art, std.testing.allocator, target, screen, .chase, .{ 350, 260 }, .excluded, 10, .{ 1, 1, 1, 1 }, 1);
    try std.testing.expectEqual([2]i32{ 350, 260 }, state.sight.?);
}
