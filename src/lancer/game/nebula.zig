//! `C:\lancer\game\nebula.cpp`: the sky dome and the nebula. `nebula_create` (`0x00498B30`) builds
//! both at start-up, `nebula_select` (`0x00498D00`) applies the script's choice of nebula and
//! `nebula_frame` (`0x00498E10`) centres both on the camera and adds them to the background layer.

const std = @import("std");

const tga = @import("../../formats/tga.zig");

/// A nebula a script can pick with `SetEnvironmentFXNebula`: a texture, and the colour it gives the
/// fill light (`nebula_fill_colours`, `0x00504000`).
pub const Nebula = struct {
    texture: []const u8,
    fill: [3]f32,
};

pub const nebulae = [7]Nebula{
    .{ .texture = "neb01", .fill = .{ 0.24, 0.5, 1 } },
    .{ .texture = "neb02", .fill = .{ 0, 1, 0.8 } },
    .{ .texture = "neb03", .fill = .{ 0.33, 0.46, 1 } },
    .{ .texture = "neb04", .fill = .{ 0.74, 1, 0.32 } },
    .{ .texture = "neb05", .fill = .{ 0, 0.75, 1 } },
    .{ .texture = "neb06", .fill = .{ 0.92, 0.66, 0.33 } },
    .{ .texture = "neb07", .fill = .{ 0, 1, 1 } },
};

/// The nebula `nebula_create` shows until a script picks one.
pub const default_nebula = 0;

/// The image the dome's colours come from, in `resource.hog`.
pub const dome_image_name = "starref12.tga";

/// The sky dome drawn by the hardware renderers (`nebula_dome`, `0x00498810`): a band of
/// `dome_columns` by `dome_rows` vertices around the camera, untextured and opaque, each vertex
/// coloured by a pixel of `starref12.tga`.
pub const dome_columns = 15;
pub const dome_rows = 8;
pub const dome_radius: f32 = 5000;
/// Half the band's height, against a horizontal radius of 1: it stops about 22 degrees short of
/// either pole.
pub const dome_half_height: f32 = 2.5;

pub const DomeVertex = struct {
    position: [3]f32,
    /// Red, green, blue and alpha.
    colour: [4]f32,
};

/// Vertex `column`, `row` of the dome: `u` and `v` run from 0 to 1 across its columns and rows,
/// `u` around the camera and `v` down it; the colour is the pixel at `u` and `v` times 255, over 256.
pub fn domeVertex(image: tga.Image, column: usize, row: usize) error{WrongSize}!DomeVertex {
    if (image.width != 256 or image.height != 256) return error.WrongSize;
    const u = @as(f32, @floatFromInt(column)) / (dome_columns - 1);
    const v = @as(f32, @floatFromInt(row)) / (dome_rows - 1);
    const pixel = image.pixel(@intFromFloat(u * 255), @intFromFloat(v * 255));
    const angle = u * 2 * std.math.pi;
    const direction = [3]f32{ @sin(angle), (v - 0.5) * 2 * dome_half_height, @cos(angle) };
    const length = @sqrt(direction[0] * direction[0] + direction[1] * direction[1] + direction[2] * direction[2]);
    var position: [3]f32 = undefined;
    for (&position, direction) |*p, d| p.* = d / length * dome_radius;
    return .{
        .position = position,
        .colour = .{
            @as(f32, @floatFromInt(pixel[0])) / 256,
            @as(f32, @floatFromInt(pixel[1])) / 256,
            @as(f32, @floatFromInt(pixel[2])) / 256,
            1,
        },
    };
}

/// The nebula: an 11 by 11 vertex patch of a sphere of `patch_radius` (`sky_patch_create`,
/// `0x00498EA0`), unlit and added, with the nebula's texture across it once. Nebula 5 uses the
/// smaller patch.
pub const patch_divisions = 10;
pub const patch_radius: f32 = 5000;
pub const patch_half_angles = [2]f32{ std.math.pi / 4.0, std.math.pi / 5.0 };

pub fn patchHalfAngle(nebula: usize) f32 {
    return patch_half_angles[@intFromBool(nebula == 5)];
}

pub const PatchVertex = struct {
    position: [3]f32,
    u: f32,
    v: f32,
};

/// Vertex `column`, `row` of a patch spanning `half_angle` each way: the columns turn about `X`, the
/// rows about `Y`.
pub fn patchVertex(half_angle: f32, column: usize, row: usize) PatchVertex {
    const u = @as(f32, @floatFromInt(column)) / patch_divisions;
    const v = @as(f32, @floatFromInt(row)) / patch_divisions;
    const pitch = -half_angle + u * 2 * half_angle;
    const yaw = -half_angle + v * 2 * half_angle;
    return .{
        .position = .{
            @sin(yaw) * @cos(pitch) * patch_radius,
            -@sin(pitch) * patch_radius,
            @cos(yaw) * @cos(pitch) * patch_radius,
        },
        .u = u,
        .v = v,
    };
}

test nebulae {
    // Nebula 5, the orange one, is the only one with a smaller patch.
    try std.testing.expectEqual(std.math.pi / 5.0, patchHalfAngle(5));
    try std.testing.expectEqual(std.math.pi / 4.0, patchHalfAngle(default_nebula));
    try std.testing.expectEqualStrings("neb06", nebulae[5].texture);
}

test domeVertex {
    const gpa = std.testing.allocator;
    const rgb = try gpa.alloc(u8, 256 * 256 * 3);
    defer gpa.free(rgb);
    @memset(rgb, 0);
    rgb[0..3].* = .{ 128, 64, 32 };
    rgb[(255 * 256 + 255) * 3 ..][0..3].* = .{ 255, 255, 255 };
    const image: tga.Image = .{ .width = 256, .height = 256, .rgb = rgb };

    const first = try domeVertex(image, 0, 0);
    try std.testing.expectEqual([4]f32{ 0.5, 0.25, 0.125, 1 }, first.colour);
    // The top row lies up the dome, at -Y, and every vertex on the sphere.
    try std.testing.expect(first.position[1] < 0);
    const length = @sqrt(first.position[0] * first.position[0] + first.position[1] * first.position[1] +
        first.position[2] * first.position[2]);
    try std.testing.expectApproxEqAbs(dome_radius, length, 0.5);

    const last = try domeVertex(image, dome_columns - 1, dome_rows - 1);
    try std.testing.expectEqual([4]f32{ 255.0 / 256.0, 255.0 / 256.0, 255.0 / 256.0, 1 }, last.colour);
    try std.testing.expect(last.position[1] > 0);

    const wrong: tga.Image = .{ .width = 1, .height = 1, .rgb = rgb[0..3] };
    try std.testing.expectError(error.WrongSize, domeVertex(wrong, 0, 0));
}

test patchVertex {
    const centre = patchVertex(std.math.pi / 4.0, patch_divisions / 2, patch_divisions / 2);
    try std.testing.expectApproxEqAbs(0, centre.position[0], 1e-3);
    try std.testing.expectApproxEqAbs(0, centre.position[1], 1e-3);
    try std.testing.expectApproxEqAbs(patch_radius, centre.position[2], 1e-3);
    try std.testing.expectEqual(0.5, centre.u);

    // The first column lies below the middle, at +Y, the last above it.
    try std.testing.expect(patchVertex(std.math.pi / 4.0, 0, 5).position[1] > 0);
    try std.testing.expect(patchVertex(std.math.pi / 4.0, patch_divisions, 5).position[1] < 0);
}
