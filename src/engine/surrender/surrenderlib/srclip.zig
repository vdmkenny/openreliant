//! `C:\lancer\surrender\surrenderlib\srClip.cpp`: the clipper, which the driver links in; the port
//! follows `srd3d.dll`'s copy. `clip_triangle` (`0x1000BEB0`) cuts a polygon in the camera's frame
//! by the planes of the view volume it crosses, the near plane, then left, right, top and bottom.
//! A vertex a cut makes gets clip flags of its own (`SR_clip_vertex_set_clip_flags`,
//! `0x1000C700`), against the sides as well as the near plane, and each plane they name joins
//! those still to cut by: a cut through the near plane that lands off the screen is cut again by
//! the sides it lies beyond. An object's portal cuts last (`portal_clip`, `0x004CCF30`).

const std = @import("std");

const math = @import("../math.zig");
const srapi = @import("srapi.zig");
const srapiext = @import("srapiext.zig");
const Outcode = srapi.Outcode;
const Portal = srapiext.Portal;
const Projection = srapi.Projection;
const Vector = math.Vector;

/// The most vertices a clipped polygon holds. Each plane adds at most one vertex to a triangle, so
/// the five leave it eight at most; the game's list holds 64 (`clip_list->count < 64`).
pub const capacity = 16;

/// A vertex as the clipper carries it: in the camera's frame, with everything interpolated.
pub const Vertex = struct {
    view: Vector,
    colour: [4]f32,
    mesh_uv: [2][2]f32,
    generated: [2][2]f32,
    /// The port's: its normal in the camera's frame, for a device that lights each pixel.
    normal: Vector = @splat(0),

    /// `clip_vertex_between` (`0x1000C5E0`): the vertex `t` of the way from `a` to `b`, each
    /// attribute alike.
    fn between(a: Vertex, b: Vertex, t: f32) Vertex {
        var c = a;
        c.view = a.view + (b.view - a.view) * @as(Vector, @splat(t));
        c.normal = a.normal + (b.normal - a.normal) * @as(Vector, @splat(t));
        for (&c.colour, a.colour, b.colour) |*x, p, q| x.* = p + (q - p) * t;
        for (0..2) |pass| {
            for (0..2) |axis| {
                c.mesh_uv[pass][axis] = a.mesh_uv[pass][axis] + (b.mesh_uv[pass][axis] - a.mesh_uv[pass][axis]) * t;
                c.generated[pass][axis] = a.generated[pass][axis] + (b.generated[pass][axis] - a.generated[pass][axis]) * t;
            }
        }
        return c;
    }
};

/// The planes of the view volume and the object's portal, in the order the clipper cuts by them.
pub const Plane = enum {
    near,
    left,
    right,
    top,
    bottom,
    portal,

    fn in(plane: Plane, code: Outcode) bool {
        return switch (plane) {
            .near => code.near,
            .left => code.left,
            .right => code.right,
            .top => code.top,
            .bottom => code.bottom,
            .portal => code.portal,
        };
    }

    /// How far inside the plane a point lies: negative outside. With no portal, a point is inside
    /// it.
    fn inside(plane: Plane, projection: Projection, portal: ?Portal.View, p: Vector) f32 {
        const bounds = projection.bounds;
        return switch (plane) {
            .near => p[2] - projection.near,
            .left => p[0] - bounds[0] * p[2],
            .right => bounds[2] * p[2] - p[0],
            .top => p[1] - bounds[1] * p[2],
            .bottom => bounds[3] * p[2] - p[1],
            .portal => if (portal) |view| view.inside(p) else 1,
        };
    }
};

/// `SR_clip_vertex_set_clip_flags` (`0x1000C700`): the planes a vertex the clipper made lies
/// outside. Unlike a transformed vertex's outcode (`Projection.outcode`), a point short of the near
/// plane is tested against the sides too.
pub fn flags(projection: Projection, point: Vector) Outcode {
    const bounds = projection.bounds;
    var code: Outcode = .{ .near = point[2] < projection.near };
    if (point[0] < bounds[0] * point[2]) {
        code.left = true;
    } else if (bounds[2] * point[2] < point[0]) {
        code.right = true;
    }
    if (point[1] < bounds[1] * point[2]) {
        code.top = true;
    } else if (bounds[3] * point[2] < point[1]) {
        code.bottom = true;
    }
    return code;
}

/// `clip_triangle` (`0x1000BEB0`): cuts the first `count` vertices of `polygon` by `planes`, the
/// planes its corners lie outside, and by those the vertices each cut makes lie outside, if their
/// turn has not passed, and last by `portal` where `planes` names it. Returns how many vertices
/// are left.
pub fn clip(projection: Projection, planes: Outcode, portal: ?Portal.View, polygon: *[capacity]Vertex, count: usize) usize {
    var n = count;
    var crossed = planes;
    for (std.enums.values(Plane)) |plane| {
        if (!plane.in(crossed) or n == 0) continue;
        var out: [capacity]Vertex = undefined;
        var m: usize = 0;
        for (0..n) |i| {
            const a = polygon[i];
            const b = polygon[(i + 1) % n];
            const da = plane.inside(projection, portal, a.view);
            const db = plane.inside(projection, portal, b.view);
            if (da >= 0 and m < out.len) {
                out[m] = a;
                m += 1;
            }
            if ((da >= 0) != (db >= 0) and m < out.len) {
                out[m] = a.between(b, da / (da - db));
                crossed = crossed.either(flags(projection, out[m].view));
                m += 1;
            }
        }
        polygon.* = out;
        n = m;
    }
    return n;
}

fn corner(view: Vector) Vertex {
    return .{ .view = view, .colour = @splat(0), .mesh_uv = @splat(.{ 0, 0 }), .generated = @splat(.{ 0, 0 }) };
}

test flags {
    const projection: Projection = .init(64, 48, srapi.full_screen, .{ 0.6, 0.8 });
    // Short of the near plane, a transformed vertex notes that plane alone; one the clipper made
    // notes the sides as well.
    try std.testing.expectEqual(Outcode{ .near = true }, projection.outcode(.{ -1000, 0, 50 }));
    try std.testing.expectEqual(Outcode{ .near = true, .left = true }, flags(projection, .{ -1000, 0, 50 }));
    try std.testing.expectEqual(Outcode{ .right = true, .bottom = true }, flags(projection, .{ 1000, 1000, 1000 }));
    try std.testing.expectEqual(Outcode{}, flags(projection, .{ 0, 0, 1000 }));
}

test clip {
    const projection: Projection = .init(64, 48, srapi.full_screen, .{ 0.6, 0.8 });
    // Two corners ahead on the screen and one behind the camera, high above it: only the near
    // plane is crossed at first, but the cut lands above the top of the screen, and the top cuts it
    // again.
    var polygon: [capacity]Vertex = undefined;
    polygon[0] = corner(.{ 0, 0, 1000 });
    polygon[1] = corner(.{ 100, 100, 1000 });
    polygon[2] = corner(.{ 0, -2000, -500 });
    var planes: Outcode = .{};
    for (polygon[0..3]) |v| planes = planes.either(projection.outcode(v.view));
    try std.testing.expectEqual(Outcode{ .near = true }, planes);

    const count = clip(projection, planes, null, &polygon, 3);
    try std.testing.expectEqual(4, count);
    var on_top: usize = 0;
    for (polygon[0..count]) |v| {
        for (std.enums.values(Plane)) |plane| try std.testing.expect(plane.inside(projection, null, v.view) > -1e-3);
        on_top += @intFromBool(@abs(Plane.top.inside(projection, null, v.view)) < 1e-3);
    }
    try std.testing.expectEqual(2, on_top);

    // A triangle wholly inside is left as it is.
    polygon[0] = corner(.{ 0, 0, 1000 });
    polygon[1] = corner(.{ 100, 0, 1000 });
    polygon[2] = corner(.{ 0, 100, 1000 });
    try std.testing.expectEqual(3, clip(projection, .{}, null, &polygon, 3));
    try std.testing.expectEqual(Vector{ 100, 0, 1000 }, polygon[1].view);

    // Wholly behind the near plane, nothing is left.
    polygon[0] = corner(.{ 0, 0, 50 });
    polygon[1] = corner(.{ 100, 0, 50 });
    polygon[2] = corner(.{ 0, 100, -50 });
    try std.testing.expectEqual(0, clip(projection, .{ .near = true }, null, &polygon, 3));

    // A portal across the triangle, keeping what lies nearer than 1000 along X: its far corner is
    // cut away. Without the portal's clip code, the portal is left alone.
    polygon[0] = corner(.{ 0, 0, 1000 });
    polygon[1] = corner(.{ 200, 0, 1000 });
    polygon[2] = corner(.{ 0, 200, 1000 });
    const portal: Portal.View = .{ .normal = .{ 1, 0, 0 }, .point = .{ 100, 0, 0 } };
    try std.testing.expectEqual(3, clip(projection, .{}, portal, &polygon, 3));
    try std.testing.expectEqual(4, clip(projection, .{ .portal = true }, portal, &polygon, 3));
    for (polygon[0..4]) |v| try std.testing.expect(v.view[0] <= 100 + 1e-3);
}

test "Vertex.between" {
    const a: Vertex = .{ .view = .{ 0, 0, 100 }, .colour = .{ 0, 0.5, 1, 1 }, .mesh_uv = @splat(.{ 0, 0 }), .generated = @splat(.{ 0, 0 }), .normal = .{ 0, 0, -1 } };
    const b: Vertex = .{ .view = .{ 40, 0, 200 }, .colour = .{ 1, 0.5, 0, 1 }, .mesh_uv = @splat(.{ 1, 2 }), .generated = @splat(.{ 0, 0 }), .normal = .{ 1, 0, 0 } };
    // A quarter of the way along, each attribute alike, the port's normal among them.
    const c = a.between(b, 0.25);
    try std.testing.expectEqual(Vector{ 10, 0, 125 }, c.view);
    try std.testing.expectEqual([4]f32{ 0.25, 0.5, 0.75, 1 }, c.colour);
    try std.testing.expectEqual([2]f32{ 0.25, 0.5 }, c.mesh_uv[1]);
    try std.testing.expectEqual(Vector{ 0.25, 0, -0.75 }, c.normal);
}
