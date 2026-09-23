//! `C:\lancer\game\xtrabits.cpp`: odds and ends of the game's frame. `scene_add` (`0x004ADB30`)
//! puts an object in the scene for the frame, and `object_random15` (`0x004ADCE0`) draws an
//! object's own random numbers.

const std = @import("std");
const Allocator = std.mem.Allocator;

const srapiext = @import("../surrender/surrenderlib/srapiext.zig");
const srcore = @import("../surrender/surrenderlib/srcore.zig");
const srlight = @import("../surrender/surrenderlib/srlight.zig");
const srstars = @import("../surrender/surrenderlib/srstars.zig");
const libcmt = @import("../libcmt.zig");
const GameObject = @import("gameobj.zig").GameObject;
const create = @import("create.zig");

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

/// `object_random15` (`0x004ADCE0`): the object's own random number from 0 to 32767, which steps
/// its seed (`GameObject.random_seed`) as the C runtime's `rand` steps its own. **Unverified:** it
/// lies after this file's known code, before `deathmatch.cpp`'s.
pub fn objectRandom15(object: *GameObject) u15 {
    var random: libcmt.Rand = .{ .seed = object.random_seed };
    defer object.random_seed = random.seed;
    return random.rand();
}

/// `object_random` (`0x004ADD10`): the object's own random number from 0 to 1, which is
/// `objectRandom15` over 32767. **Unverified:** it lies after this file's known code, before
/// `deathmatch.cpp`'s.
pub fn objectRandom(object: *GameObject) f32 {
    return @as(f32, @floatFromInt(objectRandom15(object))) / 32767;
}

/// `ship_type_first_levels` (`0x004AE190`): a ship type's model, loaded where none of its objects
/// has yet, one more object of it counted, and its first part's levels of detail. Null where the
/// game has no model for it. **Unverified:** it lies after this file's known code.
pub fn firstLevels(all: *create.Objects, types: create.Types, ship_type: u8) ?[]const srapiext.Level {
    const loaded = all.useType(types, ship_type) orelse return null;
    const parts = loaded.loaded.parts;
    return if (parts.len > 0) parts[0].levels else null;
}

test firstLevels {
    var random: libcmt.Rand = .{};
    const all = try create.Objects.create(std.testing.allocator, &random);
    defer all.destroy();

    // A type without a model has no levels, but is counted as used all the same.
    try std.testing.expectEqual(null, firstLevels(all, create.testing.no_models, 0x4E));
    try std.testing.expectEqual(1, all.types[0x4E].objects);

    // One with a model gives its first part's.
    var model: create.testing.Model = undefined;
    try model.init(std.testing.allocator);
    defer model.deinit(std.testing.allocator);
    const levels = firstLevels(all, model.types(), 0x4F).?;
    try std.testing.expectEqual(&model.mesh, levels[0].mesh);
    try std.testing.expectEqual(1, all.types[0x4F].objects);
}

test objectRandom {
    var object = std.mem.zeroes(GameObject);
    object.random_seed = 1;
    try std.testing.expectApproxEqAbs(41.0 / 32767.0, objectRandom(&object), 1e-9);
    // Every number it gives lies between 0 and 1.
    for (0..100) |_| {
        const number = objectRandom(&object);
        try std.testing.expect(number >= 0 and number <= 1);
    }
}

test objectRandom15 {
    // From the seed the runtime starts on, the runtime's first number, and the seed stepped on.
    var object = std.mem.zeroes(GameObject);
    object.random_seed = 1;
    try std.testing.expectEqual(41, objectRandom15(&object));
    try std.testing.expectEqual(1 *% 214013 +% 2531011, object.random_seed);
}
