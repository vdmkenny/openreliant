//! `C:\lancer\game\xtrabits.cpp`: odds and ends of the game's frame. `scene_add` (`0x004ADB30`)
//! puts an object in the scene for the frame.

const std = @import("std");
const Allocator = std.mem.Allocator;

const srapiext = @import("../surrender/surrenderlib/srapiext.zig");
const srcore = @import("../surrender/surrenderlib/srcore.zig");
const srlight = @import("../surrender/surrenderlib/srlight.zig");
const srstars = @import("../surrender/surrenderlib/srstars.zig");

/// A scene object of any kind `scene_add` takes.
pub const Object = union(enum) {
    mesh: *srapiext.MeshObject,
    light: *const srlight.Light,
    sprites: *srapiext.SpriteSet,
    stars: *srstars.Field,
};

/// Puts `object` in the scene for the frame (`scene_add`): at the head of `layer`'s list, or of the
/// lights' for a light, whatever the layer. A hidden object is left out, as is a mesh object whose
/// level has no polygons. `mission_frame` empties the lists each frame.
pub fn sceneAdd(gpa: Allocator, scene: *srcore.Scene, object: Object, layer: srcore.Layer) Allocator.Error!void {
    const list = scene.layers.getPtr(layer);
    switch (object) {
        .mesh => |mesh| {
            if (mesh.flags.hidden) return;
            if (mesh.levels.len == 0 or mesh.levels[mesh.level].mesh.polygons.len == 0) return;
            try list.append(gpa, .{ .mesh = mesh });
        },
        .light => |light| try scene.lights.append(gpa, light.*),
        .sprites => |sprites| if (!sprites.flags.hidden) try list.append(gpa, .{ .sprites = sprites }),
        .stars => |field| if (!field.flags.hidden) try list.append(gpa, .{ .stars = field }),
    }
}

test sceneAdd {
    const gpa = std.testing.allocator;
    var scene: srcore.Scene = .{};
    defer scene.deinit(gpa);

    const empty: srapiext.Mesh = .{
        .positions = &.{},
        .normals = &.{},
        .polygons = &.{},
        .indices = &.{},
        .uv = .{ null, null },
        .planes = &.{},
        .biases = &.{},
        .surfaces = &.{},
        .bounds = .{ @splat(0), @splat(0) },
        .radius = 0,
    };
    const levels = [_]srapiext.Level{.{ .mesh = &empty, .until = std.math.inf(f32) }};
    var nothing: srapiext.MeshObject = .{ .flags = .{}, .position = @splat(0), .radius = 0, .levels = &levels };
    try sceneAdd(gpa, &scene, .{ .mesh = &nothing }, .world);
    try std.testing.expectEqual(0, scene.layers.get(.world).items.len);

    var sprites: srapiext.SpriteSet = .{ .sprites = &.{} };
    try sceneAdd(gpa, &scene, .{ .sprites = &sprites }, .overlay);
    sprites.flags.hidden = true;
    try sceneAdd(gpa, &scene, .{ .sprites = &sprites }, .overlay);
    try std.testing.expectEqual(1, scene.layers.get(.overlay).items.len);

    // A light goes to the lights' list, whatever the layer.
    const light: srlight.Light = .{ .mask = 1, .intensity = 1, .colour = .{ 1, 1, 1 }, .kind = .ambient };
    try sceneAdd(gpa, &scene, .{ .light = &light }, .background);
    try std.testing.expectEqual(1, scene.lights.items.len);
    try std.testing.expectEqual(0, scene.layers.get(.background).items.len);
}
