//! A frame's scene as the driver is handed it: triangles, lines, points and sprites on the scene's
//! layers, in the camera's frame, lit and with their texture coordinates made.

const std = @import("std");
const Allocator = std.mem.Allocator;

const math = @import("../lancer/surrender/math.zig");
const srd3d = @import("../lancer/surrender/srd3d/srd3d.zig");
const Material = @import("../lancer/surrender/surrenderlib/srapiext.zig").Material;
const Texture = @import("texture.zig").Texture;
const Vector = math.Vector;

/// Where the scene is seen from. The world has `Y` down, as the models do.
pub const Camera = struct {
    position: Vector,
    /// Its columns are the camera's right, down and forward axes.
    orientation: math.Matrix,
    /// Pixels to a view unit: a point's position over its depth.
    scale: f32,
    width: u32,
    height: u32,

    /// A camera at `position` looking along `forward`, level.
    pub fn looking(position: Vector, forward: Vector, width: u32, height: u32, scale: f32) Camera {
        return .{
            .position = position,
            .orientation = math.lookAt(math.normalize(forward)),
            .scale = scale,
            .width = width,
            .height = height,
        };
    }

    /// A point of the world in the camera's frame: `x` right, `y` down, `z` forward.
    pub fn view(camera: Camera, point: Vector) Vector {
        return camera.turn(point - camera.position);
    }

    /// A direction in the world, in the camera's frame.
    pub fn turn(camera: Camera, direction: Vector) Vector {
        return math.transformTransposed(camera.orientation, direction);
    }

    /// Where a point in the camera's frame, in front of it, lies on the screen: pixels from its top
    /// left corner.
    pub fn project(camera: Camera, point: Vector) [2]f32 {
        return .{
            @as(f32, @floatFromInt(camera.width)) / 2 + camera.scale * point[0] / point[2],
            @as(f32, @floatFromInt(camera.height)) / 2 + camera.scale * point[1] / point[2],
        };
    }
};

pub const Vertex = struct {
    /// In the camera's frame.
    position: Vector,
    /// Red, green, blue and alpha: the lighting, or the colour of an object no light reaches.
    colour: [4]f32,
    /// Texture coordinates for each pass.
    uv: [2][2]f32 = @splat(.{ 0, 0 }),
};

pub const Pass = struct {
    texture: ?*const Texture,
    /// Coloured by the vertex colour, else by white.
    lit: bool,
    blend: Material.Blend,
};

pub const Triangle = struct {
    corners: [3]Vertex,
    first: Pass,
    /// Drawn over the first, with the second texture coordinates.
    second: ?Pass = null,
    /// Added to the mean depth blended triangles are sorted by.
    sort_bias: f32 = 0,
};

/// A line one pixel wide and untextured, as the driver draws a wire face's edges.
pub const Line = struct {
    ends: [2]Vertex,
    /// Coloured by the vertex colour, else by white.
    lit: bool,
    blend: Material.Blend,
};

/// A point one pixel across, as the driver draws a star.
pub const Point = struct {
    /// In the camera's frame.
    position: Vector,
    colour: [3]f32,
    blend: Material.Blend,
};

/// A textured rectangle facing the camera, the texture across it once.
pub const Sprite = struct {
    /// Its centre, in the camera's frame.
    position: Vector,
    /// How far it reaches from its centre across and down, in the camera's units.
    half_size: [2]f32,
    texture: *const Texture,
    colour: [3]f32,
    blend: Material.Blend,
};

pub const Layer = struct {
    triangles: std.ArrayList(Triangle) = .empty,
    lines: std.ArrayList(Line) = .empty,
    points: std.ArrayList(Point) = .empty,
    sprites: std.ArrayList(Sprite) = .empty,

    fn deinit(layer: *Layer, gpa: Allocator) void {
        layer.triangles.deinit(gpa);
        layer.lines.deinit(gpa);
        layer.points.deinit(gpa);
        layer.sprites.deinit(gpa);
    }
};

pub const Scene = struct {
    camera: Camera,
    layers: std.EnumArray(srd3d.Layer, Layer) = .initFill(.{}),

    pub fn deinit(scene: *Scene, gpa: Allocator) void {
        for (&scene.layers.values) |*each| each.deinit(gpa);
    }

    pub fn layer(scene: *Scene, which: srd3d.Layer) *Layer {
        return scene.layers.getPtr(which);
    }
};

fn expectVector(expected: Vector, actual: Vector) !void {
    inline for (0..3) |i| try std.testing.expectApproxEqAbs(expected[i], actual[i], 1e-5);
}

test Camera {
    // Looking along -X: right is +Z and down is +Y.
    const camera: Camera = .looking(.{ 10, 0, 0 }, .{ -1, 0, 0 }, 640, 480, 320);
    try expectVector(.{ 0, 0, 5 }, camera.view(.{ 5, 0, 0 }));
    try expectVector(.{ 2, 1, 5 }, camera.view(.{ 5, 1, 2 }));
    try std.testing.expectEqual([2]f32{ 320, 240 }, camera.project(.{ 0, 0, 5 }));
    const point = camera.project(camera.view(.{ 5, 1, 2 }));
    try std.testing.expectApproxEqAbs(448, point[0], 1e-3);
    try std.testing.expectApproxEqAbs(304, point[1], 1e-3);
}

test Scene {
    const gpa = std.testing.allocator;
    var scene: Scene = .{ .camera = .looking(.{ 0, 0, 0 }, .{ 0, 0, 1 }, 4, 4, 2) };
    defer scene.deinit(gpa);
    try scene.layer(.overlay).points.append(gpa, .{ .position = .{ 0, 0, 1 }, .colour = .{ 1, 1, 1 }, .blend = .add });
    try std.testing.expectEqual(1, scene.layers.get(.overlay).points.items.len);
    try std.testing.expectEqual(0, scene.layers.get(.world).points.items.len);
}
