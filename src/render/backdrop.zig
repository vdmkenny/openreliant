//! The backdrop as `nebula_frame` and `backdrop_frame` add it to the scene, centred on the camera:
//! the dome, the nebula, the stars and the sun. The dust, placed at random, is left out.

const std = @import("std");
const Allocator = std.mem.Allocator;

const tga = @import("../formats/tga.zig");
const math = @import("../lancer/surrender/math.zig");
const srstars = @import("../lancer/surrender/surrenderlib/srstars.zig");
const backdrop = @import("../lancer/game/backdrop.zig");
const nebula = @import("../lancer/game/nebula.zig");
const scene = @import("scene.zig");
const texture = @import("texture.zig");
const Vector = math.Vector;

/// The dome's vertices, by `column + nebula.dome_columns * row`.
pub const Dome = [nebula.dome_rows * nebula.dome_columns]nebula.DomeVertex;

pub fn dome(image: tga.Image) error{WrongSize}!Dome {
    var vertices: Dome = undefined;
    for (0..nebula.dome_rows) |row| {
        for (0..nebula.dome_columns) |column| {
            vertices[column + nebula.dome_columns * row] = try nebula.domeVertex(image, column, row);
        }
    }
    return vertices;
}

/// Adds the dome, opaque and untextured. No light reaches it: each vertex keeps its own colour.
pub fn addDome(gpa: Allocator, target: *scene.Scene, vertices: *const Dome) Allocator.Error!void {
    const layer = target.layer(.background);
    for (nebula.dome_faces) |face| {
        var triangle: scene.Triangle = .{ .corners = undefined, .first = .{ .texture = null, .lit = true, .blend = .off } };
        for (&triangle.corners, face) |*corner, index| {
            const vertex = vertices[index];
            corner.* = .{ .position = target.camera.turn(vertex.position), .colour = vertex.colour };
        }
        try layer.triangles.append(gpa, triangle);
    }
}

/// Adds nebula `which`'s patch, turned by `orientation`, its texture unlit and added.
pub fn addNebula(
    gpa: Allocator,
    target: *scene.Scene,
    image: *const texture.Texture,
    which: usize,
    orientation: math.Matrix,
) Allocator.Error!void {
    const half_angle = nebula.patchHalfAngle(which);
    const side = nebula.patch_divisions + 1;
    var vertices: [side * side]scene.Vertex = undefined;
    for (0..side) |row| {
        for (0..side) |column| {
            const vertex = nebula.patchVertex(half_angle, column, row);
            vertices[column + side * row] = .{
                .position = target.camera.turn(math.transform(orientation, vertex.position)),
                .colour = .{ 1, 1, 1, 1 },
                .uv = .{ .{ vertex.u, vertex.v }, .{ 0, 0 } },
            };
        }
    }
    const layer = target.layer(.background);
    for (nebula.patch_faces) |face| {
        try layer.triangles.append(gpa, .{
            .corners = .{ vertices[face[0]], vertices[face[1]], vertices[face[2]] },
            .first = .{ .texture = image, .lit = false, .blend = .add },
        });
    }
}

/// Adds the stars in view, each a point in its own colour, added, as a still camera sees them:
/// this frame's directions stand in for the last's.
pub fn addStars(gpa: Allocator, target: *scene.Scene, fields: []const backdrop.Field) Allocator.Error!void {
    const layer = target.layer(.background);
    for (fields) |field| {
        const sign: Vector = switch (srstars.fieldView(target.camera.turn(field.axis)[2])) {
            .hidden => continue,
            .ahead => @splat(1),
            .mirrored => @splat(-1),
        };
        for (field.stars) |star| {
            const direction = target.camera.turn(math.transform(field.orientation, star.position)) * sign;
            const cosine = direction[2] / math.length(direction);
            if (!srstars.starShown(cosine, cosine)) continue;
            const brightness = srstars.skyBrightness(0);
            var colour: [3]f32 = undefined;
            for (&colour, star.colour) |*c, pixel| c.* = @as(f32, @floatFromInt(pixel)) / 255 * brightness;
            try layer.points.append(gpa, .{ .position = direction, .colour = colour, .blend = .add });
        }
    }
}

pub const Error = Allocator.Error || error{TextureNotFound};

/// Adds the sun's sprites toward `direction`, and the lens flares when `flares`, as a still camera
/// sees them: the sun's visibility this frame stands in for the last's, and nothing covers it.
/// Where the flares are dim or gone, `sunlayer3` takes the grey it has at brightness 0.
pub fn addSun(
    gpa: Allocator,
    target: *scene.Scene,
    library: *texture.Library,
    direction: Vector,
    flares: bool,
) Error!void {
    const camera = target.camera;
    const sun = camera.turn(direction);
    // Behind the camera the sprite pipeline draws none of them.
    if (!(sun[2] > 0)) return;
    const offset = math.length(.{ sun[0] / sun[2], sun[1] / sun[2], 0 });
    const visibility = backdrop.sunVisibility(
        camera.project(sun),
        @floatFromInt(camera.width),
        @floatFromInt(camera.height),
    );
    const brightness = backdrop.flareBrightness(visibility, offset);

    for (std.enums.values(backdrop.SunLayer)) |layer| {
        if (!layer.shown(visibility, brightness)) continue;
        const image = try library.find(layer.texture()) orelse return error.TextureNotFound;
        try target.layer(.background).sprites.append(gpa, sprite(sun, image, layer.size(), layer.grey(@max(brightness, 0))));
    }

    if (!flares or !(brightness > 0)) return;
    for (backdrop.flares) |flare| {
        const image = try library.find(flare.texture) orelse return error.TextureNotFound;
        const position: Vector = .{ sun[0] * flare.along, sun[1] * flare.along, sun[2] };
        try target.layer(.overlay).sprites.append(gpa, sprite(position, image, 1, brightness));
    }
}

/// A sprite at `position`, in the camera's frame, sized as `backdrop_frame` sizes it.
fn sprite(position: Vector, image: *const texture.Texture, size: f32, grey: f32) scene.Sprite {
    const full = image.levels[0];
    const reach = backdrop.sprite_scale * position[2] * size;
    return .{
        .position = position,
        .half_size = .{ @as(f32, @floatFromInt(full.width)) * reach, @as(f32, @floatFromInt(full.height)) * reach },
        .texture = image,
        .colour = @splat(grey),
        .blend = .add,
    };
}

test dome {
    const gpa = std.testing.allocator;
    const rgb = try gpa.alloc(u8, 256 * 256 * 3);
    defer gpa.free(rgb);
    @memset(rgb, 64);
    const vertices = try dome(.{ .width = 256, .height = 256, .rgb = rgb });

    var target: scene.Scene = .{ .camera = .looking(.{ 0, 0, 0 }, .{ 0, 0, 1 }, 64, 48, 32) };
    defer target.deinit(gpa);
    try addDome(gpa, &target, &vertices);
    const layer = target.layers.get(.background);
    try std.testing.expectEqual(nebula.dome_faces.len, layer.triangles.items.len);
    try std.testing.expectEqual([4]f32{ 0.25, 0.25, 0.25, 1 }, layer.triangles.items[0].corners[0].colour);
    try std.testing.expectEqual(null, layer.triangles.items[0].first.texture);
}

test addNebula {
    const gpa = std.testing.allocator;
    const rgba = [_]u8{ 255, 255, 255, 255 };
    const levels = [_]texture.Level{.{ .width = 1, .height = 1, .rgba = &rgba }};
    const image: texture.Texture = .{ .levels = &levels };

    // The patch faces -X until a marker turns it; a camera looking that way sees its middle ahead.
    var target: scene.Scene = .{ .camera = .looking(.{ 0, 0, 0 }, .{ -1, 0, 0 }, 64, 48, 32) };
    defer target.deinit(gpa);
    try addNebula(gpa, &target, &image, nebula.default_nebula, nebula.patch_orientation);
    const layer = target.layers.get(.background);
    try std.testing.expectEqual(nebula.patch_faces.len, layer.triangles.items.len);
    const middle = layer.triangles.items[nebula.patch_faces.len / 2 + nebula.patch_divisions].corners[0];
    try std.testing.expectApproxEqAbs(nebula.patch_radius, middle.position[2], 1);
    try std.testing.expectEqual(.add, layer.triangles.items[0].first.blend);
}

test addStars {
    const gpa = std.testing.allocator;
    const stars = [_]backdrop.Star{
        .{ .position = .{ 0, 0, 1 }, .colour = .{ 255, 51, 0 } },
        .{ .position = .{ 1, 0, 0.1 }, .colour = .{ 255, 255, 255 } },
    };
    const ahead: backdrop.Field = .{ .axis = .{ 0, 0, 1 }, .orientation = math.identity, .stars = &stars };
    const aside: backdrop.Field = .{ .axis = .{ 1, 0, 0 }, .orientation = math.lookAt(.{ 1, 0, 0 }), .stars = &stars };
    const behind: backdrop.Field = .{ .axis = .{ 0, 0, 1 }, .orientation = math.identity, .stars = &stars };

    var target: scene.Scene = .{ .camera = .looking(.{ 0, 0, 0 }, .{ 0, 0, 1 }, 64, 48, 32) };
    defer target.deinit(gpa);
    try addStars(gpa, &target, &.{ ahead, aside });
    // One field in view, and of its stars only the one within the cosine.
    const points = target.layers.get(.background).points.items;
    try std.testing.expectEqual(1, points.len);
    try std.testing.expectEqual([3]f32{ 1, 0.2, 0 }, points[0].colour);

    // Looking the other way, the same field is drawn mirrored.
    var back: scene.Scene = .{ .camera = .looking(.{ 0, 0, 0 }, .{ 0, 0, -1 }, 64, 48, 32) };
    defer back.deinit(gpa);
    try addStars(gpa, &back, &.{behind});
    const mirrored = back.layers.get(.background).points.items;
    try std.testing.expectEqual(1, mirrored.len);
    try std.testing.expect(mirrored[0].position[2] > 0);
}

test addSun {
    const gpa = std.testing.allocator;
    const tcache = @import("../formats/tcache.zig");
    var specs: [7]tcache.testing.Spec = undefined;
    const names = [_][]const u8{ "sunlayer1", "sunlayer2", "sunlayer3", "sunflare1", "sunflare2", "sunflare3", "sunflare4" };
    for (&specs, names) |*spec, name| spec.* = .{ .name = name, .encoding = .rgb565, .width = 64, .height = 64 };
    const bytes = try tcache.testing.build(gpa, &specs);
    defer gpa.free(bytes);
    const cache: tcache.Cache = try .parse(gpa, bytes);
    defer cache.deinit(gpa);
    var library: texture.Library = try .init(gpa, cache, @splat(.{ 0, 0, 0 }));
    defer library.deinit();

    // Looking straight at the sun: every layer, and the six flares at full brightness.
    var target: scene.Scene = .{ .camera = .looking(.{ 0, 0, 0 }, backdrop.sun_direction, 768, 768, 768) };
    defer target.deinit(gpa);
    try addSun(gpa, &target, &library, backdrop.sun_direction, true);
    const sprites = target.layers.get(.background).sprites.items;
    try std.testing.expectEqual(3, sprites.len);
    // `sunlayer1`: 64 texels at half size reach 32 pixels each way at a scale of 768.
    const reach = sprites[0].half_size[0] / sprites[0].position[2] * target.camera.scale;
    try std.testing.expectApproxEqAbs(32, reach, 1e-3);
    try std.testing.expectEqual(6, target.layers.get(.overlay).sprites.items.len);
    try std.testing.expectApproxEqAbs(1, target.layers.get(.overlay).sprites.items[0].colour[0], 1e-5);

    // Looking away: nothing.
    var away: scene.Scene = .{ .camera = .looking(.{ 0, 0, 0 }, -@as(Vector, backdrop.sun_direction), 768, 768, 768) };
    defer away.deinit(gpa);
    try addSun(gpa, &away, &library, backdrop.sun_direction, true);
    try std.testing.expectEqual(0, away.layers.get(.background).sprites.items.len);
}
