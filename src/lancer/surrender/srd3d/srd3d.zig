//! `C:\lancer\surrender\srD3D\srD3D.cpp`: Surrender's Direct3D 7 driver, `srd3d.dll`. It draws
//! what the payload has transformed and lit, so these are its rules for turning a material into
//! render states.

const std = @import("std");

const Material = @import("../surrenderlib/srapiext.zig").Material;

/// The scene's layers, drawn in order, each with its blended polygons last.
pub const Layer = enum(u2) {
    background = 0,
    world = 1,
    overlay = 2,
};

pub const Depth = struct {
    testing: bool,
    writing: bool,
};

/// How a pass uses the depth buffer (`0x100018B0`). Depth is stored reversed: nearer is greater.
pub fn depth(layer: Layer, blend: Material.Blend) Depth {
    return switch (layer) {
        .background, .overlay => .{ .testing = false, .writing = false },
        .world => .{ .testing = true, .writing = blend == .off },
    };
}

/// Direct3D 7's blend factors (`D3DBLEND`), those the driver uses.
pub const BlendFactor = enum(u32) {
    zero = 1,
    one = 2,
    source_alpha = 5,
    inverse_source_alpha = 6,
};

pub const Factors = struct {
    source: BlendFactor,
    destination: BlendFactor,
};

/// The factors a blend mode sets (`SR_driver_init`, `0x100056B0`), or null where blending is off.
/// Values past `add_alpha` index beyond the driver's tables.
pub fn factors(blend: Material.Blend) ?Factors {
    return switch (blend) {
        .off => null,
        .add => .{ .source = .one, .destination = .one },
        .premultiplied => .{ .source = .one, .destination = .inverse_source_alpha },
        .alpha => .{ .source = .source_alpha, .destination = .inverse_source_alpha },
        .add_alpha => .{ .source = .source_alpha, .destination = .one },
        _ => null,
    };
}

/// Sides of a highlight texture, in texels.
pub const highlight_size = 64;

pub const Highlight = [highlight_size][highlight_size][4]u8;

/// Sharpness of the highlights, by index modulo 4.
const highlight_exponents = [4]f32{ 1.01, 2.01, 5.01, 10.01 };

/// The brightness a highlight falls to at its rim and keeps outside it.
const highlight_floor: f32 = 0.4;

/// Texel `(x, y)` of highlight texture `index` as red, green, blue and alpha: grey, brightest at the
/// centre (`0x10001620`). Indices 4 to 7 repeat 0 to 3 at seven tenths the brightness. The driver
/// makes the eight at start-up; a material whose image is below 8 names one.
pub fn highlightTexel(index: u3, x: u6, y: u6) [4]u8 {
    const e: f32 = highlight_exponents[index & 3];
    const peak: f32 = @floatCast(std.math.pow(f64, @as(f64, e) + 1, 1 / @as(f64, e)));
    const fx = centred(x);
    const fy = centred(y);
    const fy2: f32 = @floatCast(fy * fy);
    const d2: f32 = @floatCast(fx * fx + fy2);
    const intensity: f64 = if (d2 <= 1)
        std.math.pow(f64, (1 - @as(f64, @sqrt(d2))) * peak, e) + highlight_floor
    else
        highlight_floor;
    const scaled: f32 = @floatCast(intensity / (highlight_floor + 1) * 200);
    var level: i32 = std.math.lossyCast(i32, @round(scaled));
    if (index > 3) level = @divTrunc(level * 7, 10);
    const grey = std.math.lossyCast(u8, @divTrunc(level - 200, 3));
    const alpha = std.math.lossyCast(u8, @divTrunc(level * 3, 2));
    return .{ grey, grey, grey, alpha };
}

/// A texel's place across the texture, from -1 at the first to just short of 1 at the last.
fn centred(i: u6) f64 {
    return @as(f64, @floatFromInt(@as(i32, i) * 2 - highlight_size)) / highlight_size;
}

/// Highlight texture `index`, row by row from the top.
pub fn highlight(index: u3) Highlight {
    var texels: Highlight = undefined;
    for (&texels, 0..) |*row, y| {
        for (row, 0..) |*texel, x| texel.* = highlightTexel(index, @intCast(x), @intCast(y));
    }
    return texels;
}

test depth {
    try std.testing.expectEqual(Depth{ .testing = true, .writing = true }, depth(.world, .off));
    try std.testing.expectEqual(Depth{ .testing = true, .writing = false }, depth(.world, .add));
    try std.testing.expectEqual(Depth{ .testing = false, .writing = false }, depth(.background, .off));
    try std.testing.expectEqual(Depth{ .testing = false, .writing = false }, depth(.overlay, .alpha));
}

test factors {
    try std.testing.expectEqual(null, factors(.off));
    try std.testing.expectEqual(Factors{ .source = .one, .destination = .one }, factors(.add).?);
    try std.testing.expectEqual(
        Factors{ .source = .source_alpha, .destination = .inverse_source_alpha },
        factors(.alpha).?,
    );
    try std.testing.expectEqual(null, factors(@enumFromInt(9)));
}

test highlightTexel {
    // The centre, bright to saturated as the exponent grows, then dimmer for the upper four.
    const centres = [8]u8{ 48, 95, 238, 255, 13, 46, 147, 255 };
    for (centres, 0..) |grey, index| {
        try std.testing.expectEqual([4]u8{ grey, grey, grey, 255 }, highlightTexel(@intCast(index), 32, 32));
    }
    // Outside the circle only the floor is left: black, partly opaque.
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 85 }, highlightTexel(0, 0, 0));
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 58 }, highlightTexel(7, 0, 0));
    // Along a radius: sharper exponents fall off sooner.
    try std.testing.expectEqual([4]u8{ 24, 24, 24, 255 }, highlightTexel(0, 40, 32));
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 217 }, highlightTexel(3, 40, 32));
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 126 }, highlightTexel(1, 56, 32));
}

test highlight {
    const texels = highlight(2);
    try std.testing.expectEqual(highlightTexel(2, 5, 60), texels[60][5]);
    // Symmetric about the centre texel.
    try std.testing.expectEqual(texels[32][20], texels[20][32]);
    try std.testing.expectEqual(texels[32][20], texels[32][44]);
}
