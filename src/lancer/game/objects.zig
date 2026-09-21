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
/// Not yet ported: hanging each part's node from its parent part's, and moving the object's origin
/// to its parts' centre of mass (`object_link_parts`, `0x00476130`); what `node_add_part` mounts
/// on the attachment points.
pub const Model = struct {
    /// The root's place (`object_set_position`, `object_set_orientation`).
    position: Vector = @splat(0),
    orientation: math.Matrix = math.identity,
    parts: []Part,

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
    /// (`node_draw`, `0x0049A8C0`, for the model's part nodes). Not yet ported: what else it draws
    /// (lights, engine glows, the cloak) and its leaving out an object too far away to see.
    pub fn draw(model: *Model, gpa: Allocator, scene: *srcore.Scene, layer: srcore.Layer) Allocator.Error!void {
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
