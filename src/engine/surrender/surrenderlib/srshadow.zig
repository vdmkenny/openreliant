//! The port's: shadows from the key lights, which Surrender has none of. Each frame the view is
//! split by depth into cascades, each an orthographic box along the sun around its slice of the
//! view (`fit`), and the scene's solid meshes are gathered as casters whatever the camera sees of
//! them (`gather`). A device that lights each pixel draws the casters into a map for each cascade
//! and scales a shadowed light's share of each pixel by what it finds there
//! (`device.Device.shadows`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const math = @import("../math.zig");
const Vector = math.Vector;
const srapi = @import("srapi.zig");
const srapiext = @import("srapiext.zig");
const srcore = @import("srcore.zig");
const srlight = @import("srlight.zig");

pub const cascade_count = 4;

/// How far from the camera each cascade reaches, in view depth: the first from the near plane.
/// Past the last, nothing is shadowed.
pub const reaches = [cascade_count]f32{ 1500, 6000, 20000, 60000 };

/// The frame's shadows as a device takes them, in the camera's frame.
pub const Frame = struct {
    cascades: [cascade_count]Cascade,
    /// The casters' corners, and their triangles, three indices each.
    positions: []const [3]f32,
    indices: []const u32,
    /// The triangles in runs, each drawn into the cascades it can reach alone.
    runs: []const Run,
};

/// A set of cascades.
pub const Cascades = std.bit_set.IntegerBitSet(cascade_count);

/// A run of the frame's indices and the cascades it is drawn into.
pub const Run = struct {
    first: u32,
    count: u32,
    cascades: Cascades,
};

/// A cascade's box along the sun.
pub const Cascade = struct {
    /// Where a point of the camera's frame falls in the cascade's map, each row dotted with the
    /// point and 1: across and up from -1 to 1, and its depth from 0 on the sun's side to 1.
    rows: [3][4]f32,
    /// The view depth up to which a pixel takes its shadow from this cascade.
    far: f32,
    /// A texel's width in the world.
    texel: f32,
    /// How far the box reaches across from its centre, in the world.
    half: f32,

    /// Where `point`, in the camera's frame, falls in the map.
    pub fn place(cascade: Cascade, point: Vector) Vector {
        var at: Vector = undefined;
        inline for (cascade.rows, 0..) |row, axis| {
            at[axis] = row[0] * point[0] + row[1] * point[1] + row[2] * point[2] + row[3];
        }
        return at;
    }

    /// Whether a sphere of `radius` at `centre`, in the camera's frame, can throw a shadow into the
    /// box: it overlaps the box across, and does not lie wholly beyond it from the sun.
    pub fn reachedBy(cascade: Cascade, centre: Vector, radius: f32) bool {
        const at = cascade.place(centre);
        const across = radius / cascade.half;
        return @abs(at[0]) <= 1 + across and @abs(at[1]) <= 1 + across and at[2] <= 1 + across * 0.5;
    }
};

/// The world's axes of the maps for light shining along `toward`, toward the sun: across, up and
/// away from the sun. They follow the world, not the camera, so that turning the camera does not
/// turn the texels under the shadows.
fn axes(toward: Vector) [3]Vector {
    const away = -toward;
    const helper: Vector = if (@abs(toward[1]) < 0.9) .{ 0, 1, 0 } else .{ 1, 0, 0 };
    const across = math.normalize(math.cross(helper, away));
    const up = math.cross(away, across);
    return .{ across, up, away };
}

/// The cascades for maps `size` texels across, lit along `toward` in the world: each the box along
/// the sun around the sphere that holds its slice of the view, its centre moved to a whole texel
/// of the world so that the shadows stay still as the camera moves.
pub fn fit(context: srapi.Context, toward: Vector, size: u32) [cascade_count]Cascade {
    const bounds = context.projection.bounds;
    const world_axes = axes(toward);
    // The axes in the camera's frame, which the rows are made of.
    var turned: [3]Vector = undefined;
    for (world_axes, &turned) |axis, *in_view| in_view.* = context.turn(axis);
    var cascades: [cascade_count]Cascade = undefined;
    var near = context.projection.near;
    for (reaches, &cascades) |far, *cascade| {
        const sphere = sliceSphere(bounds, near, far);
        const texel = 2 * sphere.radius / @as(f32, @floatFromInt(size));
        const centre_world = math.transform(context.camera.orientation, sphere.centre) + context.camera.position;
        var offsets: [3]f32 = undefined;
        for (world_axes, &offsets, 0..) |axis, *offset, index| {
            // In doubles: the world's coordinates are large, and the snapping must not wander.
            const along = dot64(axis, centre_world);
            const origin = if (index < 2) @floor(along / texel) * texel else along - sphere.radius;
            offset.* = @floatCast(dot64(axis, context.camera.position) - origin);
        }
        const scales = [3]f32{ 1 / sphere.radius, 1 / sphere.radius, 1 / (2 * sphere.radius) };
        for (&cascade.rows, turned, offsets, scales) |*row, axis, offset, scale| {
            row.* = .{ axis[0] * scale, axis[1] * scale, axis[2] * scale, offset * scale };
        }
        cascade.far = far;
        cascade.texel = texel;
        cascade.half = sphere.radius;
        near = far;
    }
    return cascades;
}

/// The dot product of `a` and `b` in doubles.
fn dot64(a: Vector, b: Vector) f64 {
    const Wide = @Vector(3, f64);
    return @reduce(.Add, @as(Wide, @floatCast(a)) * @as(Wide, @floatCast(b)));
}

const Sphere = struct { centre: Vector, radius: f32 };

/// The sphere around the slice of the view from depth `near` to `far`: centred on its corners'
/// mean, reaching the farthest. It depends on the view's shape alone, so its size holds still.
fn sliceSphere(bounds: [4]f32, near: f32, far: f32) Sphere {
    var corners: [8]Vector = undefined;
    var index: usize = 0;
    for ([2]f32{ near, far }) |depth| {
        for ([2]f32{ bounds[0], bounds[2] }) |x| {
            for ([2]f32{ bounds[1], bounds[3] }) |y| {
                corners[index] = .{ x * depth, y * depth, depth };
                index += 1;
            }
        }
    }
    var sum: Vector = @splat(0);
    for (corners) |corner| sum += corner;
    const centre = sum / @as(Vector, @splat(corners.len));
    var radius: f32 = 0;
    for (corners) |corner| radius = @max(radius, math.distance(corner, centre));
    return .{ .centre = centre, .radius = radius };
}

/// The direction toward the first light of `lights` that casts shadows, a directional one, in the
/// world; null where none does.
pub fn sunward(lights: []const srlight.Light) ?Vector {
    for (lights) |light| {
        if (!light.shadowed) continue;
        switch (light.kind) {
            .directional => |forward| return math.normalize(forward),
            .ambient, .point => {},
        }
    }
    return null;
}

/// Whether `object` casts: a lit mesh, shown and of some size.
pub fn casts(object: *const srapiext.MeshObject) bool {
    return !object.flags.hidden and object.scale != 0 and object.flags.lit and object.levels.len > 0;
}

/// The frame's shadows: the cascades for maps `size` texels across, along the first light of
/// `lights` that casts shadows, and the triangles of each caster of the world's layer and of
/// `extra` that can reach one of them. Null where no light casts shadows.
pub fn gather(
    arena: Allocator,
    context: srapi.Context,
    lights: []const srlight.Light,
    world: []const srcore.Object,
    extra: []const *srapiext.MeshObject,
    size: u32,
) Allocator.Error!?Frame {
    const toward = sunward(lights) orelse return null;
    var casters: Casters = .{ .arena = arena, .context = context, .cascades = fit(context, toward, size) };
    for (world) |object| switch (object) {
        .mesh => |mesh| try casters.add(mesh),
        .sprites, .stars => {},
    };
    for (extra) |mesh| try casters.add(mesh);
    return .{
        .cascades = casters.cascades,
        .positions = casters.positions.items,
        .indices = casters.indices.items,
        .runs = casters.runs.items,
    };
}

/// The casters as they are gathered.
const Casters = struct {
    arena: Allocator,
    context: srapi.Context,
    cascades: [cascade_count]Cascade,
    positions: std.ArrayList([3]f32) = .empty,
    indices: std.ArrayList(u32) = .empty,
    runs: std.ArrayList(Run) = .empty,

    /// Adds `object`'s triangles, where it casts and can reach a cascade: its opaque surfaces at
    /// its current level of detail, each polygon a fan of its corners, turned into the camera's
    /// frame as the pipeline turns it. Lines cast nothing. A run of the cascades the last object
    /// reached takes them on.
    fn add(casters: *Casters, object: *const srapiext.MeshObject) Allocator.Error!void {
        if (!casts(object)) return;
        const context = casters.context;
        const relative = context.view(object.position);
        const reached = casters.reachedBy(relative, object.radius * object.scale);
        if (reached.count() == 0) return;
        const mesh = object.levels[@min(object.level, object.levels.len - 1)].mesh;
        var matrix = math.product(math.transpose(context.camera.orientation), object.orientation);
        if (object.scale != 1) {
            for (&matrix) |*m| m.* *= object.scale;
        }
        const base: u32 = @intCast(casters.positions.items.len);
        try casters.positions.ensureUnusedCapacity(casters.arena, mesh.positions.len);
        for (mesh.positions) |position| casters.positions.appendAssumeCapacity(math.transform(matrix, position) + relative);
        const first: u32 = @intCast(casters.indices.items.len);
        var polygon: usize = 0;
        for (mesh.surfaces) |surface| {
            const run = mesh.polygons[polygon..][0..surface.polygons];
            polygon += surface.polygons;
            if (surface.material.blend[0] != .off) continue;
            for (run) |shape| {
                if (shape.kind == .lines or shape.count < 3) continue;
                const corners = mesh.indices[shape.first..][0..shape.count];
                for (1..corners.len - 1) |second| {
                    try casters.indices.appendSlice(casters.arena, &.{ base + corners[0], base + corners[second], base + corners[second + 1] });
                }
            }
        }
        const count = @as(u32, @intCast(casters.indices.items.len)) - first;
        if (count == 0) return;
        if (casters.runs.items.len > 0) {
            const last = &casters.runs.items[casters.runs.items.len - 1];
            if (last.cascades.eql(reached) and last.first + last.count == first) {
                last.count += count;
                return;
            }
        }
        try casters.runs.append(casters.arena, .{ .first = first, .count = count, .cascades = reached });
    }

    /// The cascades a sphere of `radius` at `centre`, in the camera's frame, can throw a shadow
    /// into.
    fn reachedBy(casters: Casters, centre: Vector, radius: f32) Cascades {
        var reached: Cascades = .initEmpty();
        for (casters.cascades, 0..) |cascade, index| reached.setValue(index, cascade.reachedBy(centre, radius));
        return reached;
    }
};

const testing = struct {
    /// A view a right angle wide, from the world's origin along its Z axis.
    fn context() srapi.Context {
        return .{ .projection = .init(640, 480, .{ 0, 0, 1, 1 }, .{ 0.5, 0.5 }) };
    }

    const sun = math.normalize(.{ 1, -2, 0.5 });

    fn keyLight(shadowed: bool) srlight.Light {
        return .{ .mask = 1, .intensity = 1, .colour = @splat(1), .kind = .{ .directional = sun }, .shadowed = shadowed };
    }
};

test fit {
    const context = testing.context();
    const cascades = fit(context, testing.sun, 2048);
    var near = context.projection.near;
    for (cascades, reaches) |cascade, far| {
        // The middle of its slice of the view lies in its map, and a point toward the sun nearer
        // the sun's side.
        const middle: Vector = .{ 0, 0, (near + far) / 2 };
        const at = cascade.place(middle);
        try std.testing.expect(@abs(at[0]) < 1 and @abs(at[1]) < 1);
        try std.testing.expect(at[2] > 0 and at[2] < 1);
        const toward = middle + context.turn(testing.sun) * @as(Vector, @splat(100));
        try std.testing.expect(cascade.place(toward)[2] < at[2]);
        try std.testing.expectEqual(far, cascade.far);
        near = far;
    }
    // The farther the cascade reaches, the wider its texels.
    for (cascades[0 .. cascade_count - 1], cascades[1..]) |nearer, farther| try std.testing.expect(nearer.texel < farther.texel);
}

test "the maps' texels follow the world, not the camera" {
    var context = testing.context();
    const point: Vector = .{ 300, 200, 900 };
    const size = 2048;
    const before = fit(context, testing.sun, size)[0].place(context.view(point));
    // However the camera moves, a point of the world moves across the map by whole texels.
    context.camera.position += .{ 7.3, -2.1, 11.9 };
    const after = fit(context, testing.sun, size)[0].place(context.view(point));
    const texels = (after - before) * @as(Vector, @splat(size / 2));
    for ([2]f32{ texels[0], texels[1] }) |moved| try std.testing.expectApproxEqAbs(@round(moved), moved, 1e-2);
}

test sunward {
    const ambient: srlight.Light = .{ .mask = 4, .intensity = 1, .colour = @splat(0.1), .kind = .ambient };
    try std.testing.expectEqual(null, sunward(&.{ ambient, testing.keyLight(false) }));
    const found = sunward(&.{ ambient, testing.keyLight(true) }).?;
    try std.testing.expectApproxEqAbs(1, math.length(found), 1e-6);
}

test gather {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const context = testing.context();
    var square = try @import("srmesh.zig").testing.square(gpa);
    defer square.deinit(gpa);
    const levels = [_]srapiext.Level{.{ .mesh = &square, .until = std.math.inf(f32) }};
    var ahead: srapiext.MeshObject = .{ .flags = .{ .lit = true }, .position = .{ 0, 0, 1000 }, .radius = square.radius, .levels = &levels };
    var hidden = ahead;
    hidden.flags.hidden = true;
    var unlit = ahead;
    unlit.flags.lit = false;
    var far_off = ahead;
    far_off.position = .{ 0, 0, 1e7 };
    var extra = ahead;
    const world = [_]srcore.Object{ .{ .mesh = &ahead }, .{ .mesh = &hidden }, .{ .mesh = &unlit }, .{ .mesh = &far_off } };

    // Without a light that casts shadows, there are none.
    try std.testing.expectEqual(null, try gather(arena, context, &.{testing.keyLight(false)}, &world, &.{}, 1024));

    // A lit mesh in reach casts its two triangles, in the camera's frame; the hidden, the unlit
    // and the one out of reach cast nothing; one cast without being drawn casts as well.
    const lights = [_]srlight.Light{testing.keyLight(true)};
    const frame = (try gather(arena, context, &lights, &world, &.{&extra}, 1024)).?;
    try std.testing.expectEqual(8, frame.positions.len);
    try std.testing.expectEqual(12, frame.indices.len);
    try std.testing.expectEqual([3]f32{ -100, -100, 1000 }, frame.positions[0]);
    try std.testing.expectEqualSlices(u32, &.{ 0, 2, 1, 0, 3, 2 }, frame.indices[0..6]);
    try std.testing.expectEqual(4, frame.indices[6]);
    // Both reach the same cascades, one after the other, so they go in one run; a square 1000
    // ahead lies within the first cascade's reach and the second's.
    try std.testing.expectEqual(1, frame.runs.len);
    try std.testing.expectEqual(12, frame.runs[0].count);
    try std.testing.expect(frame.runs[0].cascades.isSet(0) and frame.runs[0].cascades.isSet(1));

    // A blended surface casts nothing.
    square.surfaces[0].material.blend[0] = .add;
    const blended = (try gather(arena, context, &lights, &world, &.{}, 1024)).?;
    try std.testing.expectEqual(0, blended.indices.len);
}
