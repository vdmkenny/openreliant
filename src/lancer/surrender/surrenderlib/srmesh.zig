//! `C:\lancer\surrender\surrenderlib\srMesh.cpp`: the pipeline `SR_meshpipe_init` (`0x004C75C0`)
//! runs a mesh object through each frame: cull, project, light, and make texture coordinates.
//! **Unverified:** the stages, `mesh_cull` (`0x004C6280`) to `mesh_generated_coordinates`
//! (`0x004C7590`), lie between `hog_file.cpp`'s code and `SR_meshpipe_init`; by what they do they
//! are this file's.

const std = @import("std");

const shp = @import("../../../formats/shp.zig");
const math = @import("../math.zig");
const srlight = @import("srlight.zig");
const Vector = math.Vector;

/// A polygon's normal, whose side is its front: `(v1 - v0) x (v2 - v0)`, with the last two corners
/// swapped for an odd strip member.
pub fn normal(corners: [3]Vector, polygon: shp.Face.Polygon) Vector {
    const a, const b = if (polygon == .strip_odd) .{ corners[2], corners[1] } else .{ corners[1], corners[2] };
    return math.cross(a - corners[0], b - corners[0]);
}

/// Whether a viewpoint lies on a polygon's front side (`mesh_cull`).
pub fn facing(polygon_normal: Vector, corner: Vector, viewpoint: Vector) bool {
    return math.dot(polygon_normal, viewpoint) >= math.dot(polygon_normal, corner);
}

/// The face mask a mesh object starts with (`mesh_object_create`).
pub const default_face_mask: u8 = 0xFF;

/// Whether a face is drawn: its flags against the object's face mask decide whether it is hidden or
/// never culled; `culling` is off for objects flagged `0x800`.
pub fn shown(flags: shp.Face.Flags, face_mask: u8, faces_viewpoint: bool, culling: bool) bool {
    const masked: shp.Face.Flags = @bitCast(@as(u32, @bitCast(flags)) & face_mask);
    if (masked.cap) return false;
    return !culling or masked.two_sided or faces_viewpoint;
}

/// A vertex's colour (`mesh_light`, `0x004C7060`): `base`, the object's colour and any baked colour,
/// plus what each light reaching the object adds, each channel clamped to 1. Lights add no alpha.
pub fn light(base: [4]f32, lights: []const srlight.Light, object_mask: u32, position: Vector, vertex_normal: Vector) [4]f32 {
    var sum: Vector = .{ base[0], base[1], base[2] };
    for (lights) |l| {
        if (l.reaches(object_mask)) sum += l.at(position, vertex_normal);
    }
    const clamped = @min(sum, @as(Vector, @splat(1)));
    return .{ clamped[0], clamped[1], clamped[2], @min(base[3], 1) };
}

/// Texture coordinates from a vertex normal turned into the camera's frame (`mesh_sphere_map`,
/// `0x004C7360`).
pub fn sphereMap(normal_in_camera: Vector) [2]f32 {
    return .{ 0.5 + 0.5 * normal_in_camera[0], 0.5 + 0.5 * normal_in_camera[1] };
}

test normal {
    const corners = [3]Vector{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 0, 1, 0 } };
    try std.testing.expectEqual(@as(Vector, .{ 0, 0, 1 }), normal(corners, .triangle));
    try std.testing.expectEqual(@as(Vector, .{ 0, 0, -1 }), normal(corners, .strip_odd));
    try std.testing.expect(facing(normal(corners, .triangle), corners[0], .{ 0, 0, 5 }));
    try std.testing.expect(!facing(normal(corners, .triangle), corners[0], .{ 0, 0, -5 }));
}

test shown {
    const plain: shp.Face.Flags = .{};
    const cap: shp.Face.Flags = .{ .cap = true };
    const two_sided: shp.Face.Flags = .{ .two_sided = true };
    try std.testing.expect(shown(plain, default_face_mask, true, true));
    try std.testing.expect(!shown(plain, default_face_mask, false, true));
    try std.testing.expect(!shown(cap, default_face_mask, true, true));
    try std.testing.expect(shown(cap, 0xFE, true, true));
    try std.testing.expect(shown(two_sided, default_face_mask, false, true));
    try std.testing.expect(!shown(two_sided, 0xFD, false, true));
    try std.testing.expect(shown(plain, default_face_mask, false, false));
}

test light {
    const lights = [_]srlight.Light{
        .{ .mask = 1, .intensity = 1, .colour = .{ 1, 1, 0.8 }, .kind = .{ .directional = .{ 0, 0, 1 } } },
        .{ .mask = 2, .intensity = 1, .colour = .{ 0.5, 0.5, 0.5 }, .kind = .ambient },
    };
    // Both reach an object with mask 4, and the sum clamps to 1.
    try std.testing.expectEqual([4]f32{ 1, 1, 1, 0 }, light(.{ 0, 0, 0, 0 }, &lights, 4, .{ 0, 0, 0 }, .{ 0, 0, 1 }));
    // Mask 1 keeps the directional light out.
    try std.testing.expectEqual([4]f32{ 0.5, 0.5, 0.5, 1 }, light(.{ 0, 0, 0, 1 }, &lights, 1, .{ 0, 0, 0 }, .{ 0, 0, 1 }));
}

test sphereMap {
    try std.testing.expectEqual([2]f32{ 0.5, 0.5 }, sphereMap(.{ 0, 0, -1 }));
    try std.testing.expectEqual([2]f32{ 1, 0 }, sphereMap(.{ 1, -1, 0 }));
}
