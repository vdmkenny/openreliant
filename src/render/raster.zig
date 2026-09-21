//! Draws a scene as `sr_draw_layers` (`0x004C7960`) and the Direct3D driver do: layer by layer,
//! into a colour buffer cleared to black and a depth buffer cleared to 0. In each layer the opaque
//! triangles and lines are drawn as they come, each triangle's passes together, then the blended
//! triangles farthest first, every first pass and then the second passes, then the points and
//! sprites, which the backdrop adds.

const std = @import("std");
const Allocator = std.mem.Allocator;

const math = @import("../lancer/surrender/math.zig");
const srd3d = @import("../lancer/surrender/srd3d/srd3d.zig");
const Material = @import("../lancer/surrender/surrenderlib/srapiext.zig").Material;
const scene = @import("scene.zig");
const Level = @import("texture.zig").Level;
const Texture = @import("texture.zig").Texture;
const Vector = math.Vector;

/// Where polygons and lines are clipped, in front of the camera. **Unknown:** Surrender's own near
/// plane.
pub const near: f32 = 1;

/// Screen positions are kept in sixteenths of a pixel, as the hardware of the time kept them, so
/// that triangles sharing an edge cover each pixel along it once.
const subpixel = 16;

/// Farthest a screen position is taken to be, in pixels, which keeps the edge sums in range.
const guard_band = 1 << 26;

pub const Frame = struct {
    width: u32,
    height: u32,
    /// Red, green and blue, row by row from the top.
    colour: [][3]f32,
    /// Reversed: nearer is greater.
    depth: []f32,

    pub fn init(gpa: Allocator, width: u32, height: u32) Allocator.Error!Frame {
        const count = @as(usize, width) * height;
        const colour = try gpa.alloc([3]f32, count);
        errdefer gpa.free(colour);
        return .{ .width = width, .height = height, .colour = colour, .depth = try gpa.alloc(f32, count) };
    }

    pub fn deinit(frame: Frame, gpa: Allocator) void {
        gpa.free(frame.colour);
        gpa.free(frame.depth);
    }

    /// Black, at depth 0.
    pub fn clear(frame: Frame) void {
        @memset(frame.colour, .{ 0, 0, 0 });
        @memset(frame.depth, 0);
    }

    /// The frame as 8-bit red, green, blue and alpha, opaque, row by row from the top.
    pub fn rgba(frame: Frame, gpa: Allocator) Allocator.Error![]u8 {
        const out = try gpa.alloc(u8, frame.colour.len * 4);
        for (frame.colour, 0..) |colour, i| {
            for (colour, 0..) |c, channel| out[i * 4 + channel] = std.math.lossyCast(u8, @round(std.math.clamp(c, 0, 1) * 255));
            out[i * 4 + 3] = 0xFF;
        }
        return out;
    }

    fn at(frame: Frame, x: usize, y: usize) usize {
        return y * frame.width + x;
    }

    /// The pixel a point on the screen falls in, or null off the screen.
    fn pixel(frame: Frame, point: [2]f32) ?usize {
        const x = @floor(point[0]);
        const y = @floor(point[1]);
        if (!(x >= 0 and y >= 0 and x < @as(f32, @floatFromInt(frame.width)) and y < @as(f32, @floatFromInt(frame.height)))) return null;
        return frame.at(std.math.lossyCast(usize, x), std.math.lossyCast(usize, y));
    }
};

/// Draws `target` into `frame`, which is the camera's size.
pub fn draw(gpa: Allocator, frame: Frame, target: *const scene.Scene) Allocator.Error!void {
    frame.clear();
    const camera = target.camera;
    for (std.enums.values(srd3d.Layer)) |which| {
        const layer = target.layers.getPtrConst(which);

        var blended: std.ArrayList(Deferred) = .empty;
        defer blended.deinit(gpa);
        for (layer.triangles.items) |*triangle| {
            if (triangle.first.blend == .off) {
                drawTriangle(frame, camera, which, triangle.corners, 0, triangle.first);
                if (triangle.second) |second| drawTriangle(frame, camera, which, triangle.corners, 1, second);
            } else {
                try blended.append(gpa, .{ .triangle = triangle, .key = sortKey(triangle.*) });
            }
        }
        for (layer.lines.items) |line| drawLine(frame, camera, which, line);

        std.mem.sort(Deferred, blended.items, {}, Deferred.farther);
        for (blended.items) |entry| drawTriangle(frame, camera, which, entry.triangle.corners, 0, entry.triangle.first);
        for (blended.items) |entry| {
            if (entry.triangle.second) |second| drawTriangle(frame, camera, which, entry.triangle.corners, 1, second);
        }

        for (layer.points.items) |point| drawPoint(frame, camera, which, point);
        for (layer.sprites.items) |sprite| drawSprite(frame, camera, which, sprite);
    }
}

const Deferred = struct {
    triangle: *const scene.Triangle,
    key: f32,

    fn farther(_: void, a: Deferred, b: Deferred) bool {
        return a.key > b.key;
    }
};

/// A blended triangle's sort key: the mean depth of its corners along the view, plus its bias.
pub fn sortKey(triangle: scene.Triangle) f32 {
    var sum: f32 = 0;
    for (triangle.corners) |corner| sum += corner.position[2];
    return sum / 3 + triangle.sort_bias;
}

/// A corner on the screen.
const Screen = struct {
    /// In sixteenths of a pixel.
    x: i64,
    y: i64,
    /// One over the depth, by which attributes are interpolated in perspective.
    w: f32,
    /// The driver's depth, `sqrt(1 / z)`, interpolated straight across the screen.
    depth: f32,

    fn of(camera: scene.Camera, position: Vector) Screen {
        const point = camera.project(position);
        const w = 1 / position[2];
        return .{ .x = fixed(point[0]), .y = fixed(point[1]), .w = w, .depth = @sqrt(w) };
    }
};

fn fixed(pixels: f32) i64 {
    return std.math.lossyCast(i64, @round(std.math.clamp(pixels, -guard_band, guard_band) * subpixel));
}

/// Twice the signed area of `a`, `b` and the point, positive on the side that is the inside of a
/// triangle wound as the edges are once put right.
fn edge(a: Screen, b: Screen, x: i64, y: i64) i64 {
    return (b.x - a.x) * (y - a.y) - (b.y - a.y) * (x - a.x);
}

/// Whether a pixel centre exactly on an edge belongs to the triangle: on its top or left edges, as
/// Direct3D's rule has it.
fn topLeft(a: Screen, b: Screen) bool {
    return b.y < a.y or (b.y == a.y and b.x > a.x);
}

fn lerp(a: scene.Vertex, b: scene.Vertex, t: f32) scene.Vertex {
    var out: scene.Vertex = .{
        .position = a.position + (b.position - a.position) * @as(Vector, @splat(t)),
        .colour = undefined,
    };
    for (&out.colour, a.colour, b.colour) |*c, x, y| c.* = x + (y - x) * t;
    for (&out.uv, a.uv, b.uv) |*stage, x, y| {
        for (stage, x, y) |*c, p, q| c.* = p + (q - p) * t;
    }
    return out;
}

/// A triangle cut to the part in front of the near plane: none, a triangle or a quad.
fn clip(corners: [3]scene.Vertex) struct { [4]scene.Vertex, usize } {
    var out: [4]scene.Vertex = undefined;
    var count: usize = 0;
    for (corners, 0..) |a, i| {
        const b = corners[(i + 1) % 3];
        const a_in = a.position[2] >= near;
        if (a_in) {
            out[count] = a;
            count += 1;
        }
        if (a_in != (b.position[2] >= near)) {
            out[count] = lerp(a, b, (near - a.position[2]) / (b.position[2] - a.position[2]));
            count += 1;
        }
    }
    return .{ out, count };
}

fn drawTriangle(frame: Frame, camera: scene.Camera, which: srd3d.Layer, corners: [3]scene.Vertex, stage: u1, pass: scene.Pass) void {
    const polygon, const count = clip(corners);
    if (count < 3) return;
    fill(frame, camera, srd3d.depth(which, pass.blend), .{ polygon[0], polygon[1], polygon[2] }, stage, pass);
    if (count == 4) fill(frame, camera, srd3d.depth(which, pass.blend), .{ polygon[0], polygon[2], polygon[3] }, stage, pass);
}

/// Fills a triangle wholly in front of the near plane.
fn fill(frame: Frame, camera: scene.Camera, depth: srd3d.Depth, corners: [3]scene.Vertex, stage: u1, pass: scene.Pass) void {
    var vertices = corners;
    var screen: [3]Screen = undefined;
    for (&screen, vertices) |*s, v| s.* = .of(camera, v.position);
    var area = edge(screen[0], screen[1], screen[2].x, screen[2].y);
    if (area == 0) return;
    // The driver culls nothing: turn the triangle round so its inside is positive.
    if (area < 0) {
        std.mem.swap(Screen, &screen[1], &screen[2]);
        std.mem.swap(scene.Vertex, &vertices[1], &vertices[2]);
        area = -area;
    }

    const x_range = pixelRange(@min(screen[0].x, screen[1].x, screen[2].x), @max(screen[0].x, screen[1].x, screen[2].x), frame.width) orelse return;
    const y_range = pixelRange(@min(screen[0].y, screen[1].y, screen[2].y), @max(screen[0].y, screen[1].y, screen[2].y), frame.height) orelse return;

    // Edge `i` is the one facing corner `i`; its sum at a point is corner `i`'s weight there.
    const edges = [3][2]usize{ .{ 1, 2 }, .{ 2, 0 }, .{ 0, 1 } };
    const size: f32 = @floatFromInt(area);
    var step: [2][3]f32 = undefined;
    for (edges, 0..) |e, i| {
        step[0][i] = @as(f32, @floatFromInt(screen[e[0]].y - screen[e[1]].y)) * subpixel / size;
        step[1][i] = @as(f32, @floatFromInt(screen[e[1]].x - screen[e[0]].x)) * subpixel / size;
    }

    var py = y_range[0];
    while (py < y_range[1]) : (py += 1) {
        const cy = @as(i64, py) * subpixel + subpixel / 2;
        var px = x_range[0];
        pixels: while (px < x_range[1]) : (px += 1) {
            const cx = @as(i64, px) * subpixel + subpixel / 2;
            var weights: [3]f32 = undefined;
            for (edges, &weights) |e, *weight| {
                const a = screen[e[0]];
                const b = screen[e[1]];
                const sum = edge(a, b, cx, cy);
                if (sum < 0 or (sum == 0 and !topLeft(a, b))) continue :pixels;
                weight.* = @as(f32, @floatFromInt(sum)) / size;
            }

            const index = frame.at(px, py);
            var z: f32 = 0;
            for (weights, screen) |weight, s| z += weight * s.depth;
            if (depth.testing and z < frame.depth[index]) continue;

            const perspective = perspectiveWeights(weights, screen);
            var colour: [4]f32 = @splat(0);
            for (perspective, vertices) |weight, v| {
                for (&colour, v.colour) |*c, x| c.* += weight * x;
            }
            const texel: ?[4]f32 = if (pass.texture) |texture| blk: {
                const uv = coordinates(perspective, vertices, stage);
                const level = mipLevel(texture, uv, .{
                    coordinates(perspectiveWeights(add(weights, step[0]), screen), vertices, stage),
                    coordinates(perspectiveWeights(add(weights, step[1]), screen), vertices, stage),
                });
                break :blk texture.sample(level, uv[0], uv[1]);
            } else null;

            frame.colour[index] = srd3d.blend(pass.blend, srd3d.shade(texel, colour, pass.lit), frame.colour[index]);
            if (depth.writing) frame.depth[index] = z;
        }
    }
}

/// The pixels whose centres can lie between `low` and `high`, in sixteenths of a pixel, cut to
/// `size`; null when none can.
fn pixelRange(low: i64, high: i64, size: u32) ?[2]u32 {
    const first = std.math.lossyCast(u32, @divFloor(low, subpixel));
    const last = std.math.lossyCast(u32, @min(@divFloor(high, subpixel) + 1, size));
    if (first >= last) return null;
    return .{ first, last };
}

fn add(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[0] + b[0], a[1] + b[1], a[2] + b[2] };
}

/// Screen weights made into weights for the attributes, which vary in perspective.
fn perspectiveWeights(weights: [3]f32, screen: [3]Screen) [3]f32 {
    var w: f32 = 0;
    for (weights, screen) |weight, s| w += weight * s.w;
    var out: [3]f32 = undefined;
    for (&out, weights, screen) |*o, weight, s| o.* = weight * s.w / w;
    return out;
}

fn coordinates(weights: [3]f32, vertices: [3]scene.Vertex, stage: u1) [2]f32 {
    var uv: [2]f32 = @splat(0);
    for (weights, vertices) |weight, v| {
        uv[0] += weight * v.uv[stage][0];
        uv[1] += weight * v.uv[stage][1];
    }
    return uv;
}

/// The mip level the driver samples: the nearest to the texels a pixel spans, from the texture
/// coordinates at the pixel and one pixel across and down.
fn mipLevel(texture: *const Texture, uv: [2]f32, neighbours: [2][2]f32) usize {
    const full = texture.levels[0];
    const width: f32 = @floatFromInt(full.width);
    const height: f32 = @floatFromInt(full.height);
    var widest: f32 = 0;
    for (neighbours) |n| {
        const du = (n[0] - uv[0]) * width;
        const dv = (n[1] - uv[1]) * height;
        widest = @max(widest, du * du + dv * dv);
    }
    const lod = 0.5 * std.math.log2(widest);
    if (!(lod > 0.5)) return 0;
    return @min(std.math.lossyCast(usize, @floor(lod + 0.5)), texture.levels.len - 1);
}

fn drawLine(frame: Frame, camera: scene.Camera, which: srd3d.Layer, line: scene.Line) void {
    var ends = line.ends;
    const in = [2]bool{ ends[0].position[2] >= near, ends[1].position[2] >= near };
    if (!in[0] and !in[1]) return;
    if (in[0] != in[1]) {
        const t = (near - ends[0].position[2]) / (ends[1].position[2] - ends[0].position[2]);
        ends[@intFromBool(in[0])] = lerp(ends[0], ends[1], t);
    }
    const depth = srd3d.depth(which, line.blend);
    const a = camera.project(ends[0].position);
    const b = camera.project(ends[1].position);
    const w = [2]f32{ 1 / ends[0].position[2], 1 / ends[1].position[2] };
    const span = @max(@abs(b[0] - a[0]), @abs(b[1] - a[1]));
    if (!(span < guard_band)) return;
    const steps = @max(std.math.lossyCast(usize, @ceil(span)), 1);
    for (0..steps + 1) |i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
        const index = frame.pixel(.{ a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t }) orelse continue;
        const z = @sqrt(w[0]) + (@sqrt(w[1]) - @sqrt(w[0])) * t;
        if (depth.testing and z < frame.depth[index]) continue;
        // Across the screen `t`, along the line in perspective `far`.
        const far = t * w[1] / (w[0] + (w[1] - w[0]) * t);
        var colour: [4]f32 = undefined;
        for (&colour, ends[0].colour, ends[1].colour) |*c, p, q| c.* = p + (q - p) * far;
        frame.colour[index] = srd3d.blend(line.blend, srd3d.shade(null, colour, line.lit), frame.colour[index]);
        if (depth.writing) frame.depth[index] = z;
    }
}

/// Points and sprites are projected as they are, without the near plane: the backdrop's lie a unit
/// from the camera, in its direction.
fn drawPoint(frame: Frame, camera: scene.Camera, which: srd3d.Layer, point: scene.Point) void {
    if (!(point.position[2] > 0)) return;
    const index = frame.pixel(camera.project(point.position)) orelse return;
    const depth = srd3d.depth(which, point.blend);
    const z = @sqrt(1 / point.position[2]);
    if (depth.testing and z < frame.depth[index]) return;
    // Untextured and lit: the point's own colour.
    const colour = [4]f32{ point.colour[0], point.colour[1], point.colour[2], 1 };
    frame.colour[index] = srd3d.blend(point.blend, srd3d.shade(null, colour, true), frame.colour[index]);
    if (depth.writing) frame.depth[index] = z;
}

fn drawSprite(frame: Frame, camera: scene.Camera, which: srd3d.Layer, sprite: scene.Sprite) void {
    if (!(sprite.position[2] > 0)) return;
    const colour = [4]f32{ sprite.colour[0], sprite.colour[1], sprite.colour[2], 1 };
    const pass: scene.Pass = .{ .texture = sprite.texture, .lit = true, .blend = sprite.blend };
    var corners: [4]scene.Vertex = undefined;
    for (&corners, [4][2]f32{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } }) |*corner, uv| {
        const offset: Vector = .{ (uv[0] * 2 - 1) * sprite.half_size[0], (uv[1] * 2 - 1) * sprite.half_size[1], 0 };
        corner.* = .{ .position = sprite.position + offset, .colour = colour, .uv = .{ uv, uv } };
    }
    const depth = srd3d.depth(which, pass.blend);
    fill(frame, camera, depth, .{ corners[0], corners[1], corners[2] }, 0, pass);
    fill(frame, camera, depth, .{ corners[0], corners[2], corners[3] }, 0, pass);
}

const testing = struct {
    const camera: scene.Camera = .looking(.{ 0, 0, 0 }, .{ 0, 0, 1 }, 8, 8, 4);

    /// A corner at pixel `x`, `y` of `camera`, at depth `z`.
    fn corner(x: f32, y: f32, z: f32, colour: [4]f32) scene.Vertex {
        return .{ .position = .{ (x - 4) * z / 4, (y - 4) * z / 4, z }, .colour = colour };
    }

    fn untextured(blend: Material.Blend) scene.Pass {
        return .{ .texture = null, .lit = true, .blend = blend };
    }

    fn expectColour(expected: [3]f32, actual: [3]f32) !void {
        for (expected, actual) |e, a| try std.testing.expectApproxEqAbs(e, a, 1e-5);
    }
};

test "triangles sharing an edge cover each pixel once" {
    const gpa = std.testing.allocator;
    const frame: Frame = try .init(gpa, 8, 8);
    defer frame.deinit(gpa);
    var target: scene.Scene = .{ .camera = testing.camera };
    defer target.deinit(gpa);
    // A quad over the middle four by four pixels, added at half brightness, in two triangles.
    const grey = [4]f32{ 0.5, 0.5, 0.5, 1 };
    const a = testing.corner(2, 2, 10, grey);
    const b = testing.corner(6, 2, 10, grey);
    const c = testing.corner(6, 6, 10, grey);
    const d = testing.corner(2, 6, 10, grey);
    try target.layer(.background).triangles.append(gpa, .{ .corners = .{ a, b, c }, .first = testing.untextured(.add) });
    try target.layer(.background).triangles.append(gpa, .{ .corners = .{ a, c, d }, .first = testing.untextured(.add) });
    try draw(gpa, frame, &target);
    for (0..8) |y| {
        for (0..8) |x| {
            const inside = x >= 2 and x < 6 and y >= 2 and y < 6;
            try testing.expectColour(if (inside) .{ 0.5, 0.5, 0.5 } else .{ 0, 0, 0 }, frame.colour[frame.at(x, y)]);
        }
    }
}

test "the nearer opaque triangle stays in front" {
    const gpa = std.testing.allocator;
    const frame: Frame = try .init(gpa, 8, 8);
    defer frame.deinit(gpa);
    var target: scene.Scene = .{ .camera = testing.camera };
    defer target.deinit(gpa);
    const red = [4]f32{ 1, 0, 0, 1 };
    const blue = [4]f32{ 0, 0, 1, 1 };
    const world = target.layer(.world);
    try world.triangles.append(gpa, .{ .corners = .{ testing.corner(0, 0, 5, red), testing.corner(8, 0, 5, red), testing.corner(0, 8, 5, red) }, .first = testing.untextured(.off) });
    try world.triangles.append(gpa, .{ .corners = .{ testing.corner(0, 0, 50, blue), testing.corner(8, 0, 50, blue), testing.corner(0, 8, 50, blue) }, .first = testing.untextured(.off) });
    try draw(gpa, frame, &target);
    try testing.expectColour(.{ 1, 0, 0 }, frame.colour[frame.at(1, 1)]);
    try std.testing.expectApproxEqAbs(@sqrt(@as(f32, 1) / 5), frame.depth[frame.at(1, 1)], 1e-6);
}

test "blended triangles are drawn farthest first" {
    const gpa = std.testing.allocator;
    const frame: Frame = try .init(gpa, 8, 8);
    defer frame.deinit(gpa);
    var target: scene.Scene = .{ .camera = testing.camera };
    defer target.deinit(gpa);
    const near_red = [4]f32{ 1, 0, 0, 0.5 };
    const far_blue = [4]f32{ 0, 0, 1, 0.5 };
    const world = target.layer(.world);
    // Given nearest first; half-transparent red must end over blue.
    try world.triangles.append(gpa, .{ .corners = .{ testing.corner(0, 0, 5, near_red), testing.corner(8, 0, 5, near_red), testing.corner(0, 8, 5, near_red) }, .first = testing.untextured(.alpha) });
    try world.triangles.append(gpa, .{ .corners = .{ testing.corner(0, 0, 50, far_blue), testing.corner(8, 0, 50, far_blue), testing.corner(0, 8, 50, far_blue) }, .first = testing.untextured(.alpha) });
    try draw(gpa, frame, &target);
    try testing.expectColour(.{ 0.5, 0, 0.25 }, frame.colour[frame.at(1, 1)]);
    // Blended passes leave the depth alone.
    try std.testing.expectEqual(0, frame.depth[frame.at(1, 1)]);
}

test "a triangle through the near plane draws its front" {
    const gpa = std.testing.allocator;
    const frame: Frame = try .init(gpa, 8, 8);
    defer frame.deinit(gpa);
    var target: scene.Scene = .{ .camera = testing.camera };
    defer target.deinit(gpa);
    const white = [4]f32{ 1, 1, 1, 1 };
    // A floor below the camera, from behind it to far ahead.
    try target.layer(.background).triangles.append(gpa, .{
        .corners = .{
            .{ .position = .{ -100, 5, -10 }, .colour = white },
            .{ .position = .{ 100, 5, -10 }, .colour = white },
            .{ .position = .{ 0, 5, 1000 }, .colour = white },
        },
        .first = testing.untextured(.off),
    });
    try draw(gpa, frame, &target);
    // Below the horizon it shows, above it nothing.
    try testing.expectColour(.{ 1, 1, 1 }, frame.colour[frame.at(4, 7)]);
    try testing.expectColour(.{ 0, 0, 0 }, frame.colour[frame.at(4, 2)]);
}

test "points, lines and sprites" {
    const gpa = std.testing.allocator;
    const frame: Frame = try .init(gpa, 8, 8);
    defer frame.deinit(gpa);
    var target: scene.Scene = .{ .camera = testing.camera };
    defer target.deinit(gpa);

    const rgba = [_]u8{ 255, 255, 255, 255 };
    const levels = [_]Level{.{ .width = 1, .height = 1, .rgba = &rgba }};
    const white: Texture = .{ .levels = &levels };

    const background = target.layer(.background);
    // A star, a direction less than a unit ahead.
    try background.points.append(gpa, .{ .position = testing.corner(1.5, 1.5, 0.8, undefined).position, .colour = .{ 0.25, 0.5, 1 }, .blend = .add });
    // A sprite two pixels either way of the middle, at half grey, a unit ahead like the sun's.
    try background.sprites.append(gpa, .{ .position = .{ 0, 0, 1 }, .half_size = .{ 0.5, 0.5 }, .texture = &white, .colour = .{ 0.5, 0.5, 0.5 }, .blend = .add });
    const green = [4]f32{ 0, 1, 0, 1 };
    try target.layer(.world).lines.append(gpa, .{ .ends = .{ testing.corner(0.5, 7.5, 10, green), testing.corner(7.5, 7.5, 10, green) }, .lit = true, .blend = .off });
    try draw(gpa, frame, &target);

    try testing.expectColour(.{ 0.25, 0.5, 1 }, frame.colour[frame.at(1, 1)]);
    try testing.expectColour(.{ 0.5, 0.5, 0.5 }, frame.colour[frame.at(3, 3)]);
    try testing.expectColour(.{ 0.5, 0.5, 0.5 }, frame.colour[frame.at(5, 5)]);
    try testing.expectColour(.{ 0, 0, 0 }, frame.colour[frame.at(6, 6)]);
    for (0..8) |x| try testing.expectColour(.{ 0, 1, 0 }, frame.colour[frame.at(x, 7)]);

    const out = try frame.rgba(gpa);
    defer gpa.free(out);
    try std.testing.expectEqualSlices(u8, &.{ 64, 128, 255, 255 }, out[frame.at(1, 1) * 4 ..][0..4]);
}

test sortKey {
    const white = [4]f32{ 1, 1, 1, 1 };
    const triangle: scene.Triangle = .{
        .corners = .{ testing.corner(0, 0, 10, white), testing.corner(1, 0, 20, white), testing.corner(0, 1, 30, white) },
        .first = testing.untextured(.add),
        .sort_bias = 5,
    };
    try std.testing.expectEqual(25, sortKey(triangle));
}

test mipLevel {
    const rgba = [_]u8{0} ** (16 * 16 * 4);
    const levels = [_]Level{
        .{ .width = 16, .height = 16, .rgba = &rgba },
        .{ .width = 8, .height = 8, .rgba = &rgba },
        .{ .width = 4, .height = 4, .rgba = &rgba },
    };
    const texture: Texture = .{ .levels = &levels };
    // A texel a pixel, two, four, and many.
    try std.testing.expectEqual(0, mipLevel(&texture, .{ 0, 0 }, .{ .{ 1.0 / 16.0, 0 }, .{ 0, 1.0 / 16.0 } }));
    try std.testing.expectEqual(1, mipLevel(&texture, .{ 0, 0 }, .{ .{ 2.0 / 16.0, 0 }, .{ 0, 1.0 / 16.0 } }));
    try std.testing.expectEqual(2, mipLevel(&texture, .{ 0, 0 }, .{ .{ 4.0 / 16.0, 0 }, .{ 0, 0 } }));
    try std.testing.expectEqual(2, mipLevel(&texture, .{ 0, 0 }, .{ .{ 1, 0 }, .{ 0, 0 } }));
}
