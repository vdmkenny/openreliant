//! `C:\lancer\surrender\surrenderlib\srLight.cpp`: lights, and what each adds to a vertex's colour
//! (`SR_mesh_pointlight`, `0x004CDE40`; `SR_mesh_dirlight`, `0x004CE120`).

const std = @import("std");

const math = @import("../math.zig");
const Vector = math.Vector;

pub const Light = struct {
    /// Reaches an object whose light mask shares no bit with it.
    mask: u32,
    intensity: f32,
    colour: [3]f32,
    /// Only an ambient light adds it, to the vertices' alpha (`mesh_light`).
    alpha: f32 = 0,
    kind: Kind,
    /// OpenReliant's: added to each pixel of a lit mesh by a device that lights each pixel, rather
    /// than to each vertex (`srapi.Context.pixel_lighting`). The driver sets it for the frame.
    per_pixel: bool = false,
    /// OpenReliant's: kept off what a caster shades from it, where the device draws shadows
    /// (`srshadow`). Only a directional light added to each pixel is.
    shadowed: bool = false,

    pub const Kind = union(enum) {
        /// Adds its colour everywhere.
        ambient,
        /// Lights a surface in proportion to its normal's dot product with this axis, the light's
        /// forward axis: it points toward the light.
        directional: [3]f32,
        /// Reaches out to its intensity times `range`.
        point: struct { position: [3]f32, range: f32 },
    };

    /// Whether the light reaches an object with `object_mask`. An object whose mask is all ones
    /// takes no lights.
    pub fn reaches(light: Light, object_mask: u32) bool {
        return object_mask != std.math.maxInt(u32) and light.mask & object_mask == 0;
    }

    /// What the light adds to the colour of a vertex at `position`, with unit `normal`, both in the
    /// same frame as the light.
    pub fn at(light: Light, position: Vector, normal: Vector) Vector {
        const colour: Vector = light.colour;
        const intensity: Vector = @splat(light.intensity);
        return switch (light.kind) {
            .ambient => colour * intensity,
            .directional => |forward| blk: {
                const amount = math.dot(normal, forward) * light.intensity;
                break :blk if (amount > 0) colour * @as(Vector, @splat(amount)) else @splat(0);
            },
            .point => |point| blk: {
                const to_light = @as(Vector, point.position) - position;
                const reach = light.intensity * point.range;
                const distance_squared = math.dot(to_light, to_light);
                if (distance_squared >= reach * reach) break :blk @splat(0);
                const facing = math.dot(normal, to_light);
                if (facing <= 0) break :blk @splat(0);
                // (1 / r + r / R^2 - 2 / R) * (n . d), which is the cosine times (1 - r / R)^2.
                const r = @sqrt(distance_squared);
                const amount = (1 / r + r / (reach * reach) - 2 / reach) * facing * light.intensity;
                break :blk colour * @as(Vector, @splat(amount));
            },
        };
    }
};

test "ambient light" {
    const light: Light = .{ .mask = 4, .intensity = 1, .colour = .{ 0.04, 0.04, 0.04 }, .kind = .ambient };
    try std.testing.expectEqual(@as(Vector, .{ 0.04, 0.04, 0.04 }), light.at(.{ 0, 0, 0 }, .{ 0, 0, 1 }));
    try std.testing.expect(light.reaches(0x03));
    try std.testing.expect(!light.reaches(0x04));
    try std.testing.expect(!light.reaches(std.math.maxInt(u32)));
}

test "directional light" {
    const light: Light = .{ .mask = 1, .intensity = 0.5, .colour = .{ 1, 1, 0.8 }, .kind = .{ .directional = .{ 0, 0, 1 } } };
    try std.testing.expectEqual(@as(Vector, .{ 0.5, 0.5, 0.4 }), light.at(.{ 0, 0, 0 }, .{ 0, 0, 1 }));
    try std.testing.expectEqual(@as(Vector, .{ 0, 0, 0 }), light.at(.{ 0, 0, 0 }, .{ 0, 0, -1 }));
}

test "point light" {
    const light: Light = .{ .mask = 1, .intensity = 1, .colour = .{ 1, 1, 1 }, .kind = .{ .point = .{ .position = .{ 0, 0, 10 }, .range = 20 } } };
    // Straight on at half its reach: the cosine is 1 and (1 - 1/2)^2 a quarter.
    const lit = light.at(.{ 0, 0, 0 }, .{ 0, 0, 1 });
    try std.testing.expectApproxEqAbs(0.25, lit[0], 1e-6);
    // Out of reach, or facing away, adds nothing.
    try std.testing.expectEqual(@as(Vector, .{ 0, 0, 0 }), light.at(.{ 0, 0, -30 }, .{ 0, 0, 1 }));
    try std.testing.expectEqual(@as(Vector, .{ 0, 0, 0 }), light.at(.{ 0, 0, 0 }, .{ 0, 0, -1 }));
}
