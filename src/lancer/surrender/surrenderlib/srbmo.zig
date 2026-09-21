//! `C:\lancer\surrender\surrenderlib\srBMO.cpp`: sets of sprites, scene objects of kind 4, which the
//! game calls BMOs (`sprite_set_create`, `0x004C4DB0`, in `srAPIext.cpp`). `SR_bmopipe_init`
//! (`0x004CE4D0`) finds each sprite's rectangle in view units; the driver draws those in view.

const std = @import("std");
const Allocator = std.mem.Allocator;

const math = @import("../math.zig");
const srapi = @import("srapi.zig");
const srapiext = @import("srapiext.zig");
const Vector = math.Vector;

/// A sprite in view.
pub const Projected = struct {
    /// Which of the set's sprites.
    index: u32,
    /// Its centre's depth (`+0x4C`).
    depth: f32,
    /// One over its depth plus its bias, at least the near plane (`+0x50`): what its vertices'
    /// depth is made from.
    reciprocal: f32,
    /// Its rectangle in view units, a position over its depth: left, top, right and bottom
    /// (`+0x28`).
    rect: [4]f32,
};

pub const Drawn = struct {
    set: *const srapiext.SpriteSet,
    /// The sprites in view, in the set's order.
    sprites: []const Projected,
};

/// Finds the rectangle of each sprite of `set` in view (`SR_bmopipe_init`): at or beyond the near
/// plane, at least a pixel across, and overlapping the view. Null when none is.
pub fn project(arena: Allocator, context: *const srapi.Context, set: *const srapiext.SpriteSet) Allocator.Error!?*const Drawn {
    const projection = context.projection;
    const relative = context.view(set.position);
    var matrix = math.transpose(context.camera.orientation);
    if (set.scale != 1) {
        for (&matrix) |*m| m.* *= set.scale;
    }
    var shown: std.ArrayList(Projected) = .empty;
    for (set.sprites, 0..) |sprite, index| {
        if (sprite.hidden) continue;
        const centre = math.transform(matrix, sprite.offset) + relative;
        const z = centre[2];
        if (!(projection.near <= z and z <= projection.scale[0] * sprite.half_size[0])) continue;
        const w = 1 / z;
        const rect = [4]f32{
            (centre[0] - sprite.half_size[0]) * w,
            (centre[1] - sprite.half_size[1]) * w,
            (centre[0] + sprite.half_size[0]) * w,
            (centre[1] + sprite.half_size[1]) * w,
        };
        var reciprocal = w;
        if (sprite.bias != 0) reciprocal = 1 / @max(z + sprite.bias, projection.near);
        const bounds = projection.bounds;
        const across = (bounds[0] <= rect[0] or bounds[0] <= rect[2]) and (rect[0] <= bounds[2] or rect[2] <= bounds[2]);
        const down = (bounds[1] <= rect[1] or bounds[1] <= rect[3]) and (rect[1] <= bounds[3] or rect[3] <= bounds[3]);
        if (!(across and down)) continue;
        try shown.append(arena, .{ .index = @intCast(index), .depth = z, .reciprocal = reciprocal, .rect = rect });
    }
    if (shown.items.len == 0) return null;
    const drawn = try arena.create(Drawn);
    drawn.* = .{ .set = set, .sprites = shown.items };
    return drawn;
}

/// A sprite's rectangle cut to the view's bounds, and its texture's span cut to match
/// (`0x1000C9D0`): left, top, right and bottom, and the texture's left, right, top and bottom.
pub fn cut(rect: [4]f32, uv: [4]f32, bounds: [4]f32) struct { [4]f32, [4]f32 } {
    var r = rect;
    var t = uv;
    // Left and right edges, then top and bottom, each against both bounds.
    for (0..2) |edge| {
        const x = &r[edge * 2];
        const u = &t[edge];
        if (x.* < bounds[0]) {
            u.* = along(t[0], t[1], r[0], r[2], bounds[0]);
            x.* = bounds[0];
        }
        if (bounds[2] < x.*) {
            u.* = along(t[0], t[1], r[0], r[2], bounds[2]);
            x.* = bounds[2];
        }
        const y = &r[edge * 2 + 1];
        const v = &t[edge + 2];
        if (y.* < bounds[1]) {
            v.* = along(t[2], t[3], r[1], r[3], bounds[1]);
            y.* = bounds[1];
        }
        if (bounds[3] < y.*) {
            v.* = along(t[2], t[3], r[1], r[3], bounds[3]);
            y.* = bounds[3];
        }
    }
    return .{ r, t };
}

/// The value at `x` of the line through `(x0, a)` and `(x1, b)`.
fn along(a: f32, b: f32, x0: f32, x1: f32, x: f32) f32 {
    return a + (b - a) * (x - x0) / (x1 - x0);
}

test project {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const context: srapi.Context = .{ .projection = .init(1024, 768, srapi.full_screen, .{ 0.6, 0.8 }) };

    var sprites = [_]srapiext.Sprite{
        // Ahead, 200 across at 1000: a fifth of a view unit either way.
        .{ .offset = .{ 0, 0, 1000 }, .half_size = .{ 200, 200 } },
        // Behind the near plane.
        .{ .offset = .{ 0, 0, 50 }, .half_size = .{ 20, 20 } },
        // Off to the side.
        .{ .offset = .{ 5000, 0, 1000 }, .half_size = .{ 200, 200 } },
        // Smaller than a pixel.
        .{ .offset = .{ 0, 0, 100000 }, .half_size = .{ 1, 1 } },
    };
    const set: srapiext.SpriteSet = .{ .sprites = &sprites };
    const drawn = (try project(arena, &context, &set)).?;
    try std.testing.expectEqual(1, drawn.sprites.len);
    try std.testing.expectEqual(0, drawn.sprites[0].index);
    try std.testing.expectApproxEqAbs(-0.2, drawn.sprites[0].rect[0], 1e-6);
    try std.testing.expectApproxEqAbs(0.2, drawn.sprites[0].rect[3], 1e-6);
}

test cut {
    // Half of it past the right bound: the texture's right edge moves to its middle.
    const rect, const uv = cut(.{ 0, -0.5, 2, 0.5 }, .{ 0, 1, 0, 1 }, .{ -1, -1, 1, 1 });
    try std.testing.expectEqual([4]f32{ 0, -0.5, 1, 0.5 }, rect);
    try std.testing.expectEqual([4]f32{ 0, 0.5, 0, 1 }, uv);
}
