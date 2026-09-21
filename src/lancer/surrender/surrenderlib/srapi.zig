//! `C:\lancer\surrender\surrenderlib\srAPI.cpp`: Surrender's interface to the game. This module has
//! the camera's projection.

const std = @import("std");

const math = @import("../math.zig");
const Vector = math.Vector;

/// The projection `sr_set_projection` (`0x004C3A60`) sets from a viewport, its edges as fractions
/// of the screen, left, top, right and bottom, and a factor across and one down. The view's middle
/// is the screen's, whatever the viewport.
pub const Projection = struct {
    /// Pixels to a view unit, a point's position over its depth, across and down: the screen's
    /// size less a tenth of a pixel, times the factor.
    scale: [2]f32,
    /// Where the view axis meets the screen, in pixels.
    centre: [2]f32,
    /// The viewport's edges in view units: left, top, right and bottom.
    bounds: [4]f32,
    /// The viewport's edges in pixels.
    viewport: [4]f32,

    pub fn init(width: u32, height: u32, viewport: [4]f32, factors: [2]f32) Projection {
        const size = [2]f32{ @floatFromInt(width), @floatFromInt(height) };
        var projection: Projection = undefined;
        for (0..2) |axis| {
            projection.scale[axis] = (size[axis] - 0.1) * factors[axis];
            projection.centre[axis] = size[axis] * 0.5;
            for ([2]usize{ axis, axis + 2 }) |edge| {
                projection.bounds[edge] = (viewport[edge] - 0.5) / factors[axis];
                projection.viewport[edge] = size[axis] * viewport[edge];
            }
        }
        return projection;
    }

    /// Where a point in the camera's frame, in front of it, falls on the screen.
    pub fn project(projection: Projection, point: Vector) [2]f32 {
        return .{
            projection.centre[0] + projection.scale[0] * point[0] / point[2],
            projection.centre[1] + projection.scale[1] * point[1] / point[2],
        };
    }
};

/// The whole screen, as a viewport.
pub const full_screen = [4]f32{ 0, 0, 1, 1 };

test Projection {
    // The game's usual view on a 1024 by 768 screen: square pixels, and a view 5/6 of a unit
    // either side across and 5/8 up and down.
    const projection: Projection = .init(1024, 768, full_screen, .{ 0.6, 0.8 });
    try std.testing.expectApproxEqAbs(614.34, projection.scale[0], 1e-3);
    try std.testing.expectApproxEqAbs(614.32, projection.scale[1], 1e-3);
    try std.testing.expectEqual([2]f32{ 512, 384 }, projection.centre);
    try std.testing.expectApproxEqAbs(-5.0 / 6.0, projection.bounds[0], 1e-6);
    try std.testing.expectApproxEqAbs(0.625, projection.bounds[3], 1e-6);
    try std.testing.expectEqual([2]f32{ 512, 384 }, projection.project(.{ 0, 0, 10 }));

    // Bars over the top and bottom tenth leave the middle where it was.
    const bars: Projection = .init(1024, 768, .{ 0, 0.1, 1, 0.9 }, .{ 0.6, 0.8 });
    try std.testing.expectEqual(projection.centre, bars.centre);
    try std.testing.expectApproxEqAbs(76.8, bars.viewport[1], 1e-3);
    try std.testing.expectApproxEqAbs(-0.5, bars.bounds[1], 1e-6);
}
