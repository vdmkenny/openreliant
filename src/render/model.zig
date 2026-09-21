//! A model's object as the payload's mesh pipeline hands it to the driver (`SR_meshpipe_init`,
//! `0x004C75C0`): each part's faces culled, lit and given their looks, on the world layer. Baked
//! colours from static lights are left out.

const std = @import("std");
const Allocator = std.mem.Allocator;

const shp = @import("../formats/shp.zig");
const tcache = @import("../formats/tcache.zig");
const math = @import("../lancer/surrender/math.zig");
const srlight = @import("../lancer/surrender/surrenderlib/srlight.zig");
const srmesh = @import("../lancer/surrender/surrenderlib/srmesh.zig");
const objects = @import("../lancer/game/objects.zig");
const srofiles = @import("../lancer/game/srofiles.zig");
const scene = @import("scene.zig");
const texture = @import("texture.zig");
const Vector = math.Vector;

pub const Object = struct {
    model: shp.Model,
    position: Vector,
    /// Its columns are the model's right, down and forward axes in the world.
    orientation: math.Matrix = math.identity,
    /// The level of detail each part draws, or the part's last where it has fewer.
    level: usize = 0,
    face_mask: u8 = srmesh.default_face_mask,
    /// The object's own colour, which the lights add to.
    colour: [4]f32 = .{ 0, 0, 0, 1 },
};

pub const Settings = struct {
    /// `Lmaps` in the settings' `Device` section.
    light_maps: bool = true,
};

pub const Error = Allocator.Error || error{TextureNotFound};

/// What `add` could not find.
pub const Diagnostics = struct {
    /// The material whose texture the cache lacks.
    material: []const u8 = "",
    /// Whether it was the material's light map.
    light_map: bool = false,
};

/// A part's origin in the model's frame: its position plus each of its ancestors'. Parts are not
/// turned: `node_add_part` (`0x00499430`) copies a part's position into its node and leaves the
/// node's orientation the identity it was allocated with.
pub fn partOrigin(model: shp.Model, index: usize) Vector {
    var origin: Vector = @splat(0);
    var at: ?usize = index;
    // A parent chain is never longer than the parts, which also stops a loop.
    for (0..model.parts.len) |_| {
        const i = at orelse break;
        if (i >= model.parts.len) break;
        const part = model.parts[i].part;
        origin += vector(part.position);
        at = std.math.cast(usize, part.parent);
    }
    return origin;
}

fn vector(v: shp.Vec3) Vector {
    return .{ v.x, v.y, v.z };
}

/// A vertex of the level being drawn.
const Prepared = struct {
    /// In the model's frame, for culling.
    local: Vector,
    /// In the camera's frame.
    view: Vector,
    colour: [4]f32,
    /// Texture coordinates from the normal.
    sphere: [2]f32,
};

/// Adds `object` to `target`'s world layer, lit by `lights`.
pub fn add(
    gpa: Allocator,
    target: *scene.Scene,
    library: *texture.Library,
    object: Object,
    lights: []const srlight.Light,
    settings: Settings,
    diagnostics: ?*Diagnostics,
) Error!void {
    const camera = target.camera;
    const mask = objects.lightMask(object.model.header.flags.components);
    // The camera's place in the model's frame, where the faces are culled.
    const viewpoint = math.transformTransposed(object.orientation, camera.position - object.position);
    const world = target.layer(.world);

    for (object.model.parts, 0..) |part, index| {
        // `node_add_part` hides a component's damaged parts while it is intact.
        if (part.part.flags.damaged or part.meshes.len == 0) continue;
        const mesh = part.meshes[@min(object.level, part.meshes.len - 1)];
        const origin = partOrigin(object.model, index);

        const vertices = try gpa.alloc(Prepared, mesh.vertices.len);
        defer gpa.free(vertices);
        for (vertices, mesh.vertices) |*prepared, vertex| {
            const local = vector(vertex.position) + origin;
            const position = math.transform(object.orientation, local) + object.position;
            const normal = math.transform(object.orientation, vector(vertex.normal));
            prepared.* = .{
                .local = local,
                .view = camera.view(position),
                .colour = srmesh.light(object.colour, lights, mask, position, normal),
                .sphere = srmesh.sphereMap(camera.turn(normal)),
            };
        }

        const conditions: srofiles.Conditions = .{
            .light_maps = settings.light_maps,
            .part_lightmap = part.part.flags.lightmap,
        };
        faces: for (mesh.faces) |face| {
            var corners: [3]Prepared = undefined;
            for (&corners, face.vertices) |*corner, i| {
                if (i >= vertices.len) continue :faces;
                corner.* = vertices[i];
            }
            const local = [3]Vector{ corners[0].local, corners[1].local, corners[2].local };
            const facing = srmesh.facing(srmesh.normal(local, face.polygon), local[0], viewpoint);
            if (!srmesh.shown(face.flags, object.face_mask, facing, true)) continue;

            const look = srofiles.look(face.shading, conditions);
            const name = if (face.material < mesh.materials.len) mesh.materials[face.material].name() else "";
            const first = try pass(library, look.first, name, diagnostics);
            const second: ?scene.Pass = if (look.second) |p| try pass(library, p, name, diagnostics) else null;

            var triangle: scene.Triangle = .{
                .corners = undefined,
                .first = first,
                .second = second,
                .sort_bias = face.sort_bias / 3,
            };
            for (&triangle.corners, corners, 0..) |*vertex, corner, k| {
                vertex.* = .{
                    .position = corner.view,
                    .colour = corner.colour,
                    .uv = .{
                        coordinates(look.first.texture, face, k, corner),
                        if (look.second) |p| coordinates(p.texture, face, k, corner) else .{ 0, 0 },
                    },
                };
            }

            if (look.lines) {
                inline for (0..3) |edge| {
                    if (face.edge_mask & (1 << edge) == 0) try world.lines.append(gpa, .{
                        .ends = .{ triangle.corners[edge], triangle.corners[(edge + 1) % 3] },
                        .lit = first.lit,
                        .blend = first.blend,
                    });
                }
            } else {
                try world.triangles.append(gpa, triangle);
            }
        }
    }
}

fn pass(library: *texture.Library, source: srofiles.Pass, material: []const u8, diagnostics: ?*Diagnostics) Error!scene.Pass {
    const found: ?*const texture.Texture = switch (source.texture) {
        .none => null,
        .material => try library.find(material) orelse return missing(diagnostics, material, false),
        .light_map => try library.findLightMap(material) orelse return missing(diagnostics, material, true),
        .highlight => |index| library.highlight(index),
    };
    return .{ .texture = found, .lit = source.lit, .blend = source.blend };
}

fn missing(diagnostics: ?*Diagnostics, material: []const u8, light_map: bool) error{TextureNotFound} {
    if (diagnostics) |d| d.* = .{ .material = material, .light_map = light_map };
    return error.TextureNotFound;
}

fn coordinates(source: srofiles.Texture, face: shp.Face, corner: usize, prepared: Prepared) [2]f32 {
    return switch (source) {
        .none => .{ 0, 0 },
        .material, .light_map => .{ face.u[corner], face.v[corner] },
        .highlight => prepared.sphere,
    };
}

const testing = struct {
    fn face(mode: shp.Face.Shading.Mode, vertices: [3]u32) shp.Face {
        var f = std.mem.zeroes(shp.Face);
        f.vertices = vertices;
        f.shading.mode = mode;
        f.u = .{ 0, 1, 0 };
        f.v = .{ 0, 0, 1 };
        return f;
    }

    fn vertex(x: f32, y: f32, z: f32) shp.Vertex {
        return .{
            .position = .{ .x = x, .y = y, .z = z },
            .normal = .{ .x = 0, .y = 0, .z = -1 },
            .unknown_18 = 0,
            .next_lod_vertex = -1,
        };
    }

    fn part(name: []const u8, parent: i32, position: shp.Vec3) shp.Part {
        var p = std.mem.zeroes(shp.Part);
        @memcpy(p.name_bytes[0..name.len], name);
        p.parent = parent;
        p.position = position;
        return p;
    }
};

test partOrigin {
    var parts = [_]shp.PartData{
        .{ .part = testing.part("Body", -1, .{ .x = 1, .y = 0, .z = 0 }), .meshes = &.{}, .attachments = &.{}, .node_count = 0, .clip_count = 0, .group_count = 0, .trigger_count = 0 },
        .{ .part = testing.part("Turret", 0, .{ .x = 0, .y = 2, .z = 0 }), .meshes = &.{}, .attachments = &.{}, .node_count = 0, .clip_count = 0, .group_count = 0, .trigger_count = 0 },
        .{ .part = testing.part("Loop", 2, .{ .x = 0, .y = 0, .z = 3 }), .meshes = &.{}, .attachments = &.{}, .node_count = 0, .clip_count = 0, .group_count = 0, .trigger_count = 0 },
    };
    const model: shp.Model = .{ .header = std.mem.zeroes(shp.Header), .parts = &parts, .tail_count = 0, .trailing_bytes = 0 };
    try std.testing.expectEqual(Vector{ 1, 2, 0 }, partOrigin(model, 1));
    // A part that is its own parent is counted once for each part the model has.
    try std.testing.expectEqual(Vector{ 0, 0, 9 }, partOrigin(model, 2));
}

test add {
    const gpa = std.testing.allocator;
    const cache_bytes = try tcache.testing.build(gpa, &.{
        .{ .name = "Yank_1", .encoding = .index8, .width = 2, .height = 2 },
    });
    defer gpa.free(cache_bytes);
    const cache: tcache.Cache = try .parse(gpa, cache_bytes);
    defer cache.deinit(gpa);
    var library: texture.Library = try .init(gpa, cache, @splat(.{ 0, 0, 0 }));
    defer library.deinit();

    // Four faces toward a camera looking along +Z from the origin: plain, a cap, one wound away and
    // a highlight; and one wire face with its middle edge masked.
    var vertices = [_]shp.Vertex{ testing.vertex(0, 0, 0), testing.vertex(1, 0, 0), testing.vertex(0, 1, 0) };
    var faces = [_]shp.Face{
        testing.face(.lit, .{ 0, 2, 1 }),
        testing.face(.lit, .{ 0, 2, 1 }),
        testing.face(.lit, .{ 0, 1, 2 }),
        testing.face(.lit_highlight, .{ 0, 2, 1 }),
        testing.face(.wire, .{ 0, 2, 1 }),
    };
    faces[1].flags.cap = true;
    faces[3].shading.sub_mode = 2;
    faces[4].edge_mask = 0b010;
    var materials = [_]shp.Material{std.mem.zeroes(shp.Material)};
    @memcpy(materials[0].name_bytes[0..6], "Yank_1");
    var meshes = [_]shp.Mesh{.{ .lod = .{ .switch_distance = 0 }, .vertices = &vertices, .faces = &faces, .materials = &materials }};
    var parts = [_]shp.PartData{.{
        .part = testing.part("Body", -1, shp.Vec3.zero),
        .meshes = &meshes,
        .attachments = &.{},
        .node_count = 0,
        .clip_count = 0,
        .group_count = 0,
        .trigger_count = 0,
    }};
    const model: shp.Model = .{ .header = std.mem.zeroes(shp.Header), .parts = &parts, .tail_count = 0, .trailing_bytes = 0 };

    var target: scene.Scene = .{ .camera = .looking(.{ 0, 0, 0 }, .{ 0, 0, 1 }, 64, 64, 32) };
    defer target.deinit(gpa);
    const ambient = [_]srlight.Light{.{ .mask = 0x04, .intensity = 1, .colour = .{ 0.25, 0.25, 0.25 }, .kind = .ambient }};
    try add(gpa, &target, &library, .{ .model = model, .position = .{ 0, 0, 10 } }, &ambient, .{}, null);

    const world = target.layers.get(.world);
    try std.testing.expectEqual(2, world.triangles.items.len);
    const plain = world.triangles.items[0];
    try std.testing.expectEqual(Vector{ 0, 0, 10 }, plain.corners[0].position);
    try std.testing.expectEqual([4]f32{ 0.25, 0.25, 0.25, 1 }, plain.corners[0].colour);
    try std.testing.expectEqual([2]f32{ 1, 0 }, plain.corners[1].uv[0]);
    try std.testing.expect(plain.first.texture != null);
    try std.testing.expectEqual(null, plain.second);

    // The highlight's second pass: highlight texture 2, by coordinates from the normal, which
    // faces the camera.
    const shiny = world.triangles.items[1];
    try std.testing.expectEqual(library.highlight(2), shiny.second.?.texture.?);
    try std.testing.expectEqual([2]f32{ 0.5, 0.5 }, shiny.corners[0].uv[1]);

    try std.testing.expectEqual(2, world.lines.items.len);
    try std.testing.expectEqual(Vector{ 0, 1, 10 }, world.lines.items[0].ends[1].position);
    try std.testing.expectEqual(Vector{ 1, 0, 10 }, world.lines.items[1].ends[0].position);

    // A material the cache lacks stops the object, naming the material.
    @memcpy(materials[0].name_bytes[0..6], "Kiev_1");
    var diagnostics: Diagnostics = .{};
    try std.testing.expectError(
        error.TextureNotFound,
        add(gpa, &target, &library, .{ .model = model, .position = .{ 0, 0, 10 } }, &ambient, .{}, &diagnostics),
    );
    try std.testing.expectEqualStrings("Kiev_1", diagnostics.material);
}
