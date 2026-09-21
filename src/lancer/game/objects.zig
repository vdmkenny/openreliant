//! `C:\lancer\game\objects.cpp`: the hierarchy of nodes each live object embeds, one for each part
//! of its model.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const lancer = @import("../../lancer.zig");
const Pointer = lancer.Pointer;
const shp = @import("../../formats/shp.zig");
const math = @import("../surrender/math.zig");
const srapiext = @import("../surrender/surrenderlib/srapiext.zig");
const srcore = @import("../surrender/surrenderlib/srcore.zig");
const Frame = srapiext.Frame;
const GameObject = @import("gameobj.zig").GameObject;
const srofiles = @import("srofiles.zig");
const xtrabits = @import("xtrabits.zig");
const Vector = math.Vector;

/// A node of an object's model hierarchy (`objects.cpp`), allocated at `0x004991D0`: the object's
/// root, then a node for each part of its model.
pub const Node = extern struct {
    /// **Unknown.** 1 for the node of a model part.
    kind: u32,
    flags: Flags,
    /// The node's transform for the renderer, which holds the same place as `position` and
    /// `orientation`.
    frame: Pointer(Frame),
    _unknown_0c: u32,
    /// **Unknown.** -1 when allocated.
    _unknown_10: i32,
    /// Relative to the node it hangs from: a part's origin in its parent part. An object's root
    /// holds the object's place in the world.
    position: shp.Vec3,
    /// Row-major 3x3, relative like `position`.
    orientation: [9]f32,
    _unknown_44: [0x18]u8,
    /// Where `position` goes next: `object_move` puts the position plus the velocity here, and
    /// placing an object sets both. `object_link_part` copies it into `position` and the frame.
    next_position: shp.Vec3,
    /// Likewise for `orientation`: `object_move` puts the orientation times the rotation here.
    next_orientation: [9]f32,
    _unknown_8c: [0x18]u8,
    /// The model part the node stands for, as loaded.
    part: Pointer(shp.Part),
    /// The object the node belongs to.
    owner: Pointer(GameObject),
    _unknown_ac: [0x3C]u8,
    /// A component's counterpart of `GameObject.armor`, which `ship_damage_value` reads for it.
    armor: f32,
    /// The node it hangs from; null for a root. The root's `owner` is the object's.
    parent: Pointer(Node),
    _unknown_f0: u32,
    /// Children the list at `children` can hold: 100 once allocated.
    child_capacity: i32,
    child_count: i32,
    /// **Unknown.** -1 when allocated.
    _unknown_fc: i32,
    children: Pointer(Pointer(Node)),

    pub const Flags = packed struct(u32) {
        /// **Unknown.** `object_link_part` clears these four bits.
        _unknown_0: u4,
        /// **Unknown.** Set by `node_draw` (`0x0049A8C0`). Cycling subtargets passes over a component
        /// with it.
        _unknown_4: bool,
        /// Hidden, as a component's damaged parts are while it is intact.
        hidden: bool,
        /// Set on a component's holder once `component_damage` takes the component's armor below
        /// zero.
        destroyed: bool,
        /// **Unknown.** Set on the nodes that `0x004992D0`, `0x00499540`, `0x00499680` and
        /// `0x00499730` make.
        _unknown_7: bool,
        /// Listed among the object's components.
        component: bool,
        /// **Unknown.** `create_object` sets it on the root.
        _unknown_9: bool,
        _unknown_10: u3,
        /// A component the player can pick as a subtarget: set for parts with the `targetable`
        /// flag, and by `SetTargetable`.
        targetable: bool,
        _unknown_14: u18,
    };

    comptime {
        assert(@bitOffsetOf(Flags, "hidden") == 5);
        assert(@bitOffsetOf(Flags, "component") == 8);
        assert(@bitOffsetOf(Flags, "targetable") == 13);
        assert(@offsetOf(Node, "position") == 0x14);
        assert(@offsetOf(Node, "orientation") == 0x20);
        assert(@offsetOf(Node, "part") == 0xA4);
        assert(@offsetOf(Node, "armor") == 0xE8);
        assert(@offsetOf(Node, "child_count") == 0xF8);
        assert(@offsetOf(Node, "children") == 0x100);
        assert(@sizeOf(Node) == 0x104);
    }
};

/// The light mask `node_add_part` gives a part's Surrender object: a light reaches the object unless
/// their masks share a bit (`docs/engine/rendering.md`).
pub fn lightMask(model_lists_components: bool) u32 {
    return if (model_lists_components) 0x18 else 0x03;
}

/// A live object's model as the port holds it: its root's place in the world, and a node for each
/// part of its model hanging from the root (`object_add_part`, `0x004760C0`), each with its part's
/// scene object. Every part sits at its origin in the model, whatever its parent.
///
/// Not yet ported: hanging each part's node from its parent part's (`object_link_parts`,
/// `0x00476130`), which leaves every part where it is; the moment of inertia `object_bounds` sums;
/// what `node_add_part` mounts on the attachment points.
pub const Model = struct {
    /// The object's `hidden` flag: none of its parts is drawn.
    hidden: bool = false,
    /// The root's place (`object_set_position`, `object_set_orientation`).
    position: Vector = @splat(0),
    orientation: math.Matrix = math.identity,
    parts: []Part,
    /// Where the model's origin lies from the object's, less (`GameObject + 0x524`): the centres
    /// of mass `recentre` moved the origin to.
    centre: Vector = @splat(0),
    /// Its farthest vertex from its origin, and its bounding box (`GameObject.radius`,
    /// `bounds_min`, `bounds_max`), as `recentre` leaves them.
    radius: f32 = 0,
    bounds: [2]Vector = .{ @splat(0), @splat(0) },

    pub const Part = struct {
        /// The node's `hidden` flag.
        hidden: bool,
        /// The part's origin in the model, from the root.
        origin: Vector,
        /// The node's frame: a scene object showing the part's meshes.
        object: srapiext.MeshObject,
    };

    /// A node for each part of `model` (`node_add_part`, `0x00499430`), its object flagged as
    /// `model_load` left the part (`loaded`), reached by the lights `lightMask` lets through, and as
    /// far across as its largest level. A part of a component's damaged model is hidden.
    pub fn create(gpa: Allocator, model: *const shp.Model, loaded: *const srofiles.Loaded) Allocator.Error!Model {
        const parts = try gpa.alloc(Part, model.parts.len);
        for (parts, model.parts, loaded.parts) |*node, source, part| {
            var radius: f32 = 0;
            for (part.meshes) |mesh| radius = @max(radius, mesh.radius);
            const origin = source.part.position;
            node.* = .{
                .hidden = source.part.flags.damaged,
                .origin = .{ origin.x, origin.y, origin.z },
                .object = .{
                    .flags = part.flags,
                    .position = .{ origin.x, origin.y, origin.z },
                    .radius = radius,
                    .light_mask = lightMask(model.header.flags.components),
                    .levels = part.levels,
                },
            };
        }
        return .{ .parts = parts };
    }

    pub fn deinit(model: Model, gpa: Allocator) void {
        gpa.free(model.parts);
    }

    /// Moves the object's origin to its parts' centre of mass, as `object_link_parts` ends
    /// (`object_recentre`, `0x004769F0`). `node_mass_add` (`0x004764A0`) sums, over the shown
    /// parts, the density times the part's first moment about the root, its origin times its
    /// volume plus its own first moment; over the parts' masses, density times volume, that is the
    /// centre. `object_bounds` (`0x00476680`) takes it off each part's origin, then finds the
    /// object's radius and bounding box over the vertices of each part's current level, hidden ones
    /// too. `source` is the model the parts come from.
    pub fn recentre(model: *Model, source: *const shp.Model) void {
        var moment: [3]f32 = @splat(0);
        var mass: f32 = 0;
        for (model.parts, source.parts) |part, data| {
            if (part.hidden) continue;
            const p = data.part;
            const origin: [3]f32 = part.origin;
            for (&moment, origin, p.first_moments) |*m, o, first| m.* = (o * p.volume + first) * p.density + m.*;
            mass = p.density * p.volume + mass;
        }
        if (mass > 0) {
            const scale = 1 / mass;
            for (&moment) |*m| m.* = scale * m.*;
        }
        const centre: Vector = moment;
        model.centre += centre;
        for (model.parts) |*part| part.origin -= centre;

        model.radius = 0;
        model.bounds = .{ @splat(std.math.floatMax(f32)), @splat(-std.math.floatMax(f32)) };
        for (model.parts) |part| {
            if (part.object.levels.len == 0) continue;
            for (part.object.levels[part.object.level].mesh.positions) |position| {
                const at = position + part.origin;
                model.bounds = .{ @min(model.bounds[0], at), @max(model.bounds[1], at) };
                model.radius = @max(model.radius, math.length(at));
            }
        }
    }

    /// Puts the object's root at `position`, turned by `orientation`, and each part's object with
    /// it: the root's turn applied to the part's origin, and no turn of its own
    /// (`SR_object_concate_parents`, `0x004C3490`, for each part's frame).
    pub fn place(model: *Model, position: Vector, orientation: math.Matrix) void {
        model.position = position;
        model.orientation = orientation;
        for (model.parts) |*part| {
            part.object.position = math.transform(orientation, part.origin) + position;
            part.object.orientation = orientation;
        }
    }

    /// Adds each shown part's object to `layer`, the world's or, for a cockpit, the overlay
    /// (`node_draw`, `0x0049A8C0`, for the model's part nodes), none while the object is hidden.
    /// Not yet ported: what else it draws (lights, engine glows, the cloak) and its leaving out an
    /// object too far away to see.
    pub fn draw(model: *Model, gpa: Allocator, scene: *srcore.Scene, layer: srcore.Layer) Allocator.Error!void {
        if (model.hidden) return;
        for (model.parts) |*part| {
            if (part.hidden) continue;
            try xtrabits.sceneAdd(gpa, scene, .{ .mesh = &part.object }, layer);
        }
    }
};

test lightMask {
    try std.testing.expectEqual(0x18, lightMask(true));
    try std.testing.expectEqual(0x03, lightMask(false));
}

test {
    std.testing.refAllDecls(@This());
}

test Model {
    const gpa = std.testing.allocator;
    const srmesh = @import("../surrender/surrenderlib/srmesh.zig");
    const mesh = try srmesh.testing.square(gpa);
    defer mesh.deinit(gpa);
    const levels = [_]srapiext.Level{.{ .mesh = &mesh, .until = std.math.inf(f32) }};
    var parts = [_]Model.Part{.{
        .hidden = false,
        .origin = .{ 0, 0, 100 },
        .object = .{ .flags = .{}, .position = @splat(0), .radius = mesh.radius, .levels = &levels },
    }};
    var model: Model = .{ .parts = &parts };
    // A part hangs at its origin, turned with the root.
    model.place(.{ 1000, 0, 0 }, math.rotation(.y, std.math.pi / 2.0));
    try std.testing.expectApproxEqAbs(1100, parts[0].object.position[0], 1e-3);

    var scene: srcore.Scene = .{};
    defer scene.deinit(gpa);
    try model.draw(gpa, &scene, .world);
    try std.testing.expectEqual(1, scene.layers.get(.world).items.len);
    // Recentred on its one part's mass, its origin moves to the part's centre: 100 along Z, plus
    // the part's own first moment over its volume.
    var data = std.mem.zeroes(shp.PartData);
    data.part.volume = 2;
    data.part.density = 3;
    data.part.first_moments = .{ 0, 0, 20 };
    const source: shp.Model = .{ .header = std.mem.zeroes(shp.Header), .parts = (&data)[0..1], .tail_count = 0, .trailing_bytes = 0 };
    model.recentre(&source);
    try std.testing.expectEqual(@as(Vector, .{ 0, 0, 110 }), model.centre);
    try std.testing.expectEqual(@as(Vector, .{ 0, 0, -10 }), parts[0].origin);
    try std.testing.expectApproxEqAbs(@sqrt(100.0 * 100.0 * 2.0 + 10.0 * 10.0), model.radius, 1e-3);

    // Hidden, as from its own cockpit, it adds nothing.
    scene.clear();
    model.hidden = true;
    try model.draw(gpa, &scene, .world);
    try std.testing.expectEqual(0, scene.layers.get(.world).items.len);
}
