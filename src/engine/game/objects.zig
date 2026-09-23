//! `C:\lancer\game\objects.cpp`: the hierarchy of nodes each live object embeds, one for each part
//! of its model.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const engine = @import("../../engine.zig");
const Pointer = engine.Pointer;
const shp = @import("../../formats/shp.zig");
const math = @import("../surrender/math.zig");
const srapiext = @import("../surrender/surrenderlib/srapiext.zig");
const srcore = @import("../surrender/surrenderlib/srcore.zig");
const srlight = @import("../surrender/surrenderlib/srlight.zig");
const Frame = srapiext.Frame;
const gameobj = @import("gameobj.zig");
const GameObject = gameobj.GameObject;
const srofiles = @import("srofiles.zig");
const srtexture = @import("../surrender/surrenderlib/srtexture.zig");
const matmanager = @import("matmanager.zig");
const create = @import("create.zig");
const environfx = @import("environfx.zig");
const libcmt = @import("../libcmt.zig");
const xtrabits = @import("xtrabits.zig");
const Clock = @import("main.zig").Clock;
const Vector = math.Vector;

/// A node of an object's model hierarchy (`objects.cpp`), allocated at `0x004991D0`: the object's
/// root, then a node for each part of its model.
pub const Node = extern struct {
    /// What the node draws (`node_draw`, `0x0049A8C0`, switches on it): 1 a model part, 2 an
    /// engine glow, which brightens with the throttle, 3 a light's two sprites, 5 the point light a
    /// blinking light casts (`Model.Light`). **Unknown:** 4 and 6.
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
    /// The pose `node_place` placed a part's node by, committed with its place.
    pose: Pose,
    /// Where `position` goes next: `object_move` puts the position plus the velocity here, and
    /// placing an object sets both. `node_tree_update` (`updateTree`) and `object_link_part` copy
    /// it into `position`, and `node_place` works it out for a part's node.
    next_position: shp.Vec3,
    /// Likewise for `orientation`: `object_move` puts the orientation times the rotation here.
    next_orientation: [9]f32,
    /// The pose `node_place` worked the next place of a part's node out from: the animation's
    /// angles plus the turret's, and the animation's offset.
    next_pose: Pose,
    /// The model part the node stands for, as loaded.
    part: Pointer(shp.Part),
    /// The object the node belongs to.
    owner: Pointer(GameObject),
    _unknown_ac: [8]u8,
    /// How the node plays its animation track.
    mode: Model.Mode,
    /// Which of the part's animation tracks the node runs, and where `node_animate` reads its
    /// keyframes; past the part's tracks, the node is not animated.
    animation: i32,
    /// Where the node is in its track, and how far it moves on each simulation step.
    time: f32,
    speed: f32,
    /// Where the animation has the node turned, added to the part's own angles (`node_animate`).
    animated_angles: shp.Vec3,
    /// Where the animation has the node moved, added to its part's origin.
    animated_offset: shp.Vec3,
    /// The angles the node is turned by besides the animation's, which the turrets steer.
    angles: shp.Vec3,
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
        /// Set while the node's next place is waiting to be committed. `object_move` sets it on an
        /// object's root; `node_tree_update` commits the place and clears it (`commitNext`), and
        /// `object_link_part` clears it along with the next three bits.
        next_pending: bool,
        /// Set when `node_tree_update` commits a new place for the node, and cleared the next time
        /// it visits the node. While it's set, `node_frame_update` draws the node between that
        /// place and the next.
        committed: bool,
        /// Set with `committed`, and cleared by `node_frame_update`.
        unframed: bool,
        /// Set by `node_place`, and cleared each time `node_tree_update` visits the node: the next
        /// place comes from a pose, which `node_frame_update` draws the node between the poses by.
        posed: bool,
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
        _unknown_10: bool,
        /// Set while the node or one hanging from it plays an animation track: `node_play` sets it
        /// up to the root, and `node_tree_update` descends only into children that have it.
        animating: bool,
        _unknown_12: bool,
        /// A component the player can pick as a subtarget: set for parts with the `targetable`
        /// flag, and by `SetTargetable`.
        targetable: bool,
        _unknown_14: u18,
    };

    /// The first step of `node_tree_update` for a node: clears flag bits 1 and 3, and if the
    /// node's next place is pending, commits it. The game copies the whole block from
    /// `next_position` to the end of `next_pose` over the block from `position` to the end of
    /// `pose`, then clears `next_pending` and sets `committed` and `unframed`.
    pub fn commitNext(node: *Node) void {
        node.flags.committed = false;
        node.flags.posed = false;
        if (!node.flags.next_pending) return;
        node.position = node.next_position;
        node.orientation = node.next_orientation;
        node.pose = node.next_pose;
        node.flags.next_pending = false;
        node.flags.committed = true;
        node.flags.unframed = true;
    }

    /// A part node's pose: the animation's angles, plus the turret's, and its offset.
    pub const Pose = extern struct {
        angles: shp.Vec3,
        offset: shp.Vec3,
    };

    /// `node_frame_update` (`0x0049A460`) for an object's root, once a frame before it is drawn,
    /// `fraction` of the way through the simulation's step: where the object is drawn and what
    /// the camera follows. Once a step has committed a new place, the root is drawn between that
    /// place and the next, along the straight line between them and turned by that share of the
    /// turn between; at the start of a step, at the committed place. Null where the frame stays
    /// where it was, until the first step moves the object. A root is never posed, since
    /// `node_place` places part nodes alone.
    ///
    /// Not ported: in a multiplayer game, another player's ship, whose root has flag bit 9, is
    /// drawn between the places its last two messages gave it (`+0x768`, `+0x798`).
    pub fn framePlace(node: *Node, fraction: f32) ?Model.Local {
        if (!node.flags.committed and !node.flags.unframed) return null;
        node.flags.unframed = false;
        const now: Model.Local = .{ .position = .{ node.position.x, node.position.y, node.position.z }, .orientation = node.orientation };
        if (fraction == 0) return now;
        const next: Model.Local = .{ .position = .{ node.next_position.x, node.next_position.y, node.next_position.z }, .orientation = node.next_orientation };
        return between(now, next, fraction);
    }

    comptime {
        assert(@offsetOf(Node, "next_position") - @offsetOf(Node, "position") == 0x48);
        assert(@offsetOf(Node, "part") - @offsetOf(Node, "next_position") == 0x48);
        assert(@bitOffsetOf(Flags, "hidden") == 5);
        assert(@bitOffsetOf(Flags, "component") == 8);
        assert(@bitOffsetOf(Flags, "targetable") == 13);
        assert(@bitOffsetOf(Flags, "posed") == 3);
        assert(@bitOffsetOf(Flags, "animating") == 11);
        assert(@offsetOf(Node, "position") == 0x14);
        assert(@offsetOf(Node, "pose") == 0x44);
        assert(@offsetOf(Node, "next_pose") == 0x8C);
        assert(@offsetOf(Node, "mode") == 0xB4);
        assert(@offsetOf(Node, "time") == 0xBC);
        assert(@offsetOf(Node, "speed") == 0xC0);
        assert(@offsetOf(Node, "animated_angles") == 0xC4);
        assert(@offsetOf(Node, "orientation") == 0x20);
        assert(@offsetOf(Node, "part") == 0xA4);
        assert(@offsetOf(Node, "armor") == 0xE8);
        assert(@offsetOf(Node, "child_count") == 0xF8);
        assert(@offsetOf(Node, "children") == 0x100);
        assert(@sizeOf(Node) == 0x104);
    }
};

/// `object_set_position` (`0x0049B600`): places the object's root at `at`: its frame, which the
/// port keeps as `frame` (`frameTree`), where it is and where it goes next, so that it doesn't
/// move from where it was. The game also sets the two places a multiplayer game draws another
/// player's ship between (`+0x768`, `+0x798`), which the port doesn't keep (#55).
/// **Unverified:** it and the functions after it lie after this file's known code, before
/// `particles.cpp`'s.
pub fn setPosition(object: *GameObject, frame: *Model.Local, at: Vector) void {
    const position = gameobj.vec3(at);
    frame.position = at;
    object.root.next_position = position;
    object.root.position = position;
}

/// `object_set_orientation` (`0x0049B650`): turns the object's root to `orientation`, as
/// `setPosition` places it.
pub fn setOrientation(object: *GameObject, frame: *Model.Local, orientation: math.Matrix) void {
    frame.orientation = orientation;
    object.root.next_orientation = orientation;
    object.root.orientation = orientation;
}

/// What a sphere meets on a model.
pub const Hit = struct {
    part: usize,
    face: usize,
    /// The nearest point of the face, and the face's normal, both in the part's frame.
    point: Vector,
    normal: Vector,
    /// How far the sphere's centre stands from that point.
    distance: f32,
};

/// How many boxes of a part's tree wait to be tested at once. The trees the game ships are far
/// shallower than this; a node past it is passed over rather than tested.
const hit_stack = 100;

/// `object_hit_test` (`0x0049BEF0`) with `node_hit_test` (`0x0049BD30`): the nearest face of the
/// model to a sphere, or null where it meets none. Each part's collision tree is descended to the
/// leaves, and the faces of a leaf the sphere reaches are tested. A part with no tree is passed
/// over, as is a hidden one. `place` must have run for the frame the sphere is given in.
pub fn hitSphere(model: *const Model, source: *const shp.Model, at: Vector, radius: f32) ?Hit {
    var best = radius * radius;
    var hit: ?Hit = null;
    for (model.parts, source.parts, 0..) |part, data, index| {
        if (part.hidden or data.nodes.len == 0 or data.meshes.len == 0) continue;
        const level = data.meshes[0];
        // The sphere in the part's frame, which the tree's boxes and the faces are given in.
        const local = math.transformTransposed(part.object.orientation, at - part.object.position);

        var stack: [hit_stack]u32 = undefined;
        var top: usize = 1;
        stack[0] = 0;
        // A well formed tree holds each node once, so a file that names one twice cannot keep the
        // descent going.
        var left = data.nodes.len;
        while (top > 0 and left > 0) {
            left -= 1;
            top -= 1;
            const at_node = stack[top];
            if (at_node >= data.nodes.len) continue;
            const node = data.nodes[at_node];
            const inside = math.transformTransposed(node.orientation, local - gameobj.vector(node.centre));
            const half = gameobj.vector(node.half_size);
            if (@abs(inside[0]) > half[0] + radius) continue;
            if (@abs(inside[1]) > half[1] + radius) continue;
            if (@abs(inside[2]) > half[2] + radius) continue;

            const faces = data.node_faces[at_node];
            if (faces.len == 0) {
                for (node.children) |child| {
                    if (child < 0 or top >= stack.len) continue;
                    stack[top] = @intCast(child);
                    top += 1;
                }
                continue;
            }
            for (faces) |face| {
                if (face >= level.faces.len) continue;
                const record = level.faces[face];
                const triangle: [3]Vector = .{
                    corner(level, record.vertices[0]) orelse continue,
                    corner(level, record.vertices[1]) orelse continue,
                    corner(level, record.vertices[2]) orelse continue,
                };
                const normal = gameobj.vector(record.normal);
                // Only a sphere in front of the face, and near enough, is worth the triangle.
                const ahead = math.dot(local - triangle[0], normal);
                if (ahead < 0 or ahead * ahead > best) continue;
                const point = closestOnTriangle(local, triangle);
                const away = math.lengthSquared(local - point);
                if (away >= best) continue;
                best = away;
                hit = .{ .part = index, .face = face, .point = point, .normal = normal, .distance = @sqrt(away) };
            }
        }
    }
    return hit;
}

/// A face's corner, or null where the file names a vertex the level does not hold.
fn corner(level: shp.Mesh, vertex: u32) ?Vector {
    if (vertex >= level.vertices.len) return null;
    return gameobj.vector(level.vertices[vertex].position);
}

/// The point of a triangle nearest `from`.
///
/// **Improvement:** the game reaches the same point through a general routine for the nearest point
/// of a simplex (`0x00478360`), which also serves points, lines and tetrahedra.
fn closestOnTriangle(from: Vector, triangle: [3]Vector) Vector {
    const ab = triangle[1] - triangle[0];
    const ac = triangle[2] - triangle[0];
    const ap = from - triangle[0];
    const d1 = math.dot(ab, ap);
    const d2 = math.dot(ac, ap);
    if (d1 <= 0 and d2 <= 0) return triangle[0];

    const bp = from - triangle[1];
    const d3 = math.dot(ab, bp);
    const d4 = math.dot(ac, bp);
    if (d3 >= 0 and d4 <= d3) return triangle[1];

    const vc = d1 * d4 - d3 * d2;
    if (vc <= 0 and d1 >= 0 and d3 <= 0) return triangle[0] + ab * @as(Vector, @splat(d1 / (d1 - d3)));

    const cp = from - triangle[2];
    const d5 = math.dot(ab, cp);
    const d6 = math.dot(ac, cp);
    if (d6 >= 0 and d5 <= d6) return triangle[2];

    const vb = d5 * d2 - d1 * d6;
    if (vb <= 0 and d2 >= 0 and d6 <= 0) return triangle[0] + ac * @as(Vector, @splat(d2 / (d2 - d6)));

    const va = d3 * d6 - d5 * d4;
    if (va <= 0 and (d4 - d3) >= 0 and (d5 - d6) >= 0) {
        const along = (d4 - d3) / ((d4 - d3) + (d5 - d6));
        return triangle[1] + (triangle[2] - triangle[1]) * @as(Vector, @splat(along));
    }

    const denominator = 1 / (va + vb + vc);
    return triangle[0] + ab * @as(Vector, @splat(vb * denominator)) + ac * @as(Vector, @splat(vc * denominator));
}

test hitSphere {
    const gpa = std.testing.allocator;
    var model: create.testing.Model = undefined;
    try model.init(gpa);
    defer model.deinit(gpa);
    model.withHull();

    var live = try Model.create(gpa, &model.source, &model.loaded, .{});
    defer live.deinit(gpa);
    live.place(@splat(0), math.identity);

    // The part is a square in the XY plane facing -Z; a sphere in front of it meets it.
    const hit = hitSphere(&live, &model.source, .{ 0, 0, -60 }, 100) orelse return error.TestExpectedHit;
    try std.testing.expectEqual(0, hit.part);
    try std.testing.expectApproxEqAbs(60, hit.distance, 1e-3);
    try std.testing.expectEqual(math.Vector{ 0, 0, -1 }, hit.normal);

    // Behind the face, and too far off to the side, it meets nothing.
    try std.testing.expectEqual(null, hitSphere(&live, &model.source, .{ 0, 0, 60 }, 100));
    try std.testing.expectEqual(null, hitSphere(&live, &model.source, .{ 900, 0, -60 }, 100));
}

/// `node_tree_frames` (`0x0049A880`) for an object, once a frame before it is drawn and before the
/// camera's frame: its root's frame (`Node.framePlace`), which `drawn` keeps, then each of its
/// part nodes' (`Model.frame`), and the model placed where the root's frame has it.
pub fn frameTree(root: *Node, model: ?*Model, drawn: *Model.Local, fraction: f32) void {
    if (root.framePlace(fraction)) |place| drawn.* = place;
    const parts = model orelse return;
    parts.frame(fraction);
    parts.place(drawn.position, drawn.orientation);
}

/// The light mask `node_add_part` gives a part's Surrender object: a light reaches the object unless
/// their masks share a bit (`docs/engine/rendering.md`).
pub fn lightMask(model_lists_components: bool) u32 {
    return if (model_lists_components) 0x18 else 0x03;
}

/// A live object's model as the port holds it: its root's place in the world, and a node for each
/// part of its model, each with its part's scene object. A part hangs from the part it names
/// (`object_link_parts`, `0x00476130`), so a part carries what stands on it; a part naming none
/// hangs from the root.
///
/// Not yet ported: the moment of inertia `object_bounds` sums, which nothing reads yet; the
/// animation a node's track holds (`node_animate`); what `node_add_part` mounts on the attachment
/// points besides the lights and the engine glows.
pub const Model = struct {
    /// The root's place (`object_set_position`, `object_set_orientation`).
    position: Vector = @splat(0),
    orientation: math.Matrix = math.identity,
    parts: []Part,
    /// The parts in the order `place` walks them: each after the one it hangs from.
    order: []const usize,
    lights: []Light,
    glows: []Glow,
    mounts: []Mount,
    /// Where the model's origin lies from the object's, less (`GameObject + 0x524`): the centres
    /// of mass `recentre` moved the origin to.
    centre: Vector = @splat(0),
    /// The sum of its shown parts' masses (`GameObject.mass`), as `recentre` leaves it.
    mass: f32 = 0,
    /// The root node's `destroyed` flag, which `component_damage` sets where a component hanging
    /// from the root runs out of armour.
    destroyed: bool = false,
    /// Its farthest vertex from its origin, and its bounding box (`GameObject.radius`,
    /// `bounds_min`, `bounds_max`), as `recentre` leaves them.
    radius: f32 = 0,
    /// The inverse of the inertia tensor its parts sum to, which turns an angular impulse into the
    /// turn it gives the object (`GameObject.angular_response`), as `recentre` leaves it. Zero for
    /// a model whose parts have no volume, which nothing can turn.
    angular_response: math.Matrix = @splat(0),
    /// How far off it stays worth drawing, over what its radius alone gives it
    /// (`GameObject.visibility`). Nothing in the shipped game moves it off 1.
    visibility: f32 = 1,
    bounds: [2]Vector = .{ @splat(0), @splat(0) },

    /// A light a model carries: what `node_mount_light` (`0x00499730`) makes of an attachment of
    /// kind `light`, which `node_draw` draws for node kinds 3 and 5. Its sprites are a flare that
    /// grows with how far off it is and a small lamp at its heart, and a light that blinks casts a
    /// point light on what stands near it as well. All three blink by the attachment's timing.
    ///
    /// Not ported: in the software renderer, `node_mount_light` makes no point light for an
    /// object of type 13, the Yamato. The port draws as the hardware renderer does.
    pub const Light = struct {
        /// The part that carries it, whose node `node_draw` walks to reach it.
        part: usize,
        /// Its place on that part, which is where the model's attachment point stands.
        origin: Vector,
        blink: Blink,
        /// Its sprites (node kind 3), for an attachment with a width (`size[0]`).
        sprites: ?Sprites,
        /// The point light it casts (node kind 5): its id's colour, its brightness and its range,
        /// reaching every object that takes lights. Only a light that blinks, with a brightness,
        /// casts one: the loader bakes a steady light into the meshes instead
        /// (`static_lights_bake`). Its place is set as it is drawn.
        cast: ?srlight.Light,

        /// A light's sprites and what they are drawn with.
        pub const Sprites = struct {
            /// The flare's colour, which the attachment's id picks, and the lamp's paler one.
            colour: [3]f32,
            lamp_colour: [3]f32,
            /// The attachment's height (`size[1]`), which both sprites are sized by.
            size: f32,
            set: srapiext.SpriteSet,
            /// The flare, then the lamp: the set's two sprites.
            sprite: [2]srapiext.Sprite,
            /// The lamp's own material: lit, added and textured with the sprite attachment kind 4
            /// id 1 names. The flare takes the set's.
            lamp: srapiext.Surface,

            pub const flare = 0;
            pub const lamp_sprite = 1;

            /// Sizes and colours the sprites for a light `blink` bright in its blink, seen from
            /// `away` (`node_draw`).
            fn show(sprites: *Sprites, blink: f32, away: f32) void {
                // The lamp goes out as soon as the light starts to fade.
                sprites.sprite[lamp_sprite].colour = if (blink < lamp_least) @splat(0) else sprites.lamp_colour;
                var shown = blink;
                if (away <= faded_at) {
                    if (full_at < away) shown = math.lerp(1, faded, (away - full_at) * (1.0 / (faded_at - full_at))) * blink;
                } else {
                    shown = blink * faded;
                }
                // The flare grows up to `grown_at` off: `lerp(0, 1, ...)`, which is the share alone.
                const grown = if (grown_at <= away) sprites.size else away * (1.0 / grown_at) * sprites.size;
                sprites.sprite[flare].half_size = @splat(grown * flare_scale);
                sprites.sprite[lamp_sprite].half_size = @splat(sprites.size * lamp_scale);
                // Held between 0 and 1, where anything short of 0, or no number, is 0.
                if (shown >= 0) {
                    if (shown > 1) shown = 1;
                } else {
                    shown = 0;
                }
                for (&sprites.sprite[flare].colour, sprites.colour) |*channel, c| {
                    channel.* = shown * c * flare_share;
                }
            }
        };
    };

    /// How a light blinks (`node_draw`): the attachment's `blink`, ticks on and then off, and its
    /// `blink_phase`, where in that it starts.
    pub const Blink = struct {
        times: [2]i32 = .{ 0, 0 },
        phase: i32 = 0,

        /// How bright the light stands in its blink at the object's own `tick`, the mission's clock
        /// plus its `blink_offset`: 1 while it is on, then falling away over `blink_fade` of its
        /// clock, which runs ten to the tick, and nothing or less once out. The clock wraps as the
        /// game's unsigned arithmetic does. A light with no blink is always on.
        pub fn brightness(blink: Blink, tick: i32) f32 {
            const period = blink.times[0] +% blink.times[1];
            if (period == 0) return 1;
            const clock: u32 = @bitCast(tick *% 10 -% blink.phase);
            const at: i32 = @bitCast(clock % @as(u32, @bitCast(period)));
            var shown: f32 = 1;
            if (blink.times[0] < at) shown = @as(f32, @floatFromInt(blink.times[0] -% at +% blink_fade)) * (1.0 / @as(f32, blink_fade));
            if (period < at) shown = @as(f32, @floatFromInt(at -% period +% blink_fade)) * (1.0 / @as(f32, blink_fade));
            return shown;
        }
    };

    /// An engine glow a model carries, which `node_draw` draws for node kind 2: an attachment of
    /// kind `engine_glow`, drawn as the mesh its id names (`node_mount_glow`, `0x00499540`), scaled
    /// by the attachment's size and stretched along the plume by the throttle.
    ///
    /// Not ported: the Ripper's own rule, which draws its thrusters only while it flies forward and
    /// its back pincers only while it backs up, their plumes burning the other way. It knows them
    /// by their parts' names, and needs the motion it is not ported to tell apart.
    pub const Glow = struct {
        /// The part that carries it, whose node `node_draw` walks to reach it.
        part: usize,
        /// Its place on that part, which is where the model's attachment point stands.
        origin: Vector,
        /// How the attachment stands on the part: the plume burns along its Z axis.
        orientation: math.Matrix,
        /// How far the plume reaches across, up, and along, before the throttle stretches its
        /// length.
        size: Vector,
        /// Burning against the way the throttle pushes: its plume points the way the model faces,
        /// so it is a retro thruster, lit by reverse thrust alone.
        retro: bool,
        /// Burning at its full length whatever the throttle, as the last of the glows does.
        steady: bool,
        /// The one mesh it draws, which every glow of its kind shares.
        level: [1]srapiext.Level,
        object: srapiext.MeshObject,

        /// How far along its length the plume burns, or null while it burns nothing. Every glow but
        /// a steady one flickers a little each frame (`node_draw`).
        pub fn plume(glow: Glow, throttle: f32, random: ?*libcmt.Rand) ?f32 {
            if (glow.steady) return 1;
            const lit = if (glow.retro) -throttle else throttle;
            if (!(lit > 0)) return null;
            return lit * flicker(random);
        }
    };

    /// A model an attachment point holds: a gun or a pod, which `node_mount` (`0x00499A10`) mounts
    /// as an object of its own, hung from the node of the part that carries the attachment. Its own
    /// parts, lights, glows and mounts come with it.
    pub const Mount = struct {
        /// The part that carries the attachment.
        part: usize,
        /// Where the attachment stands on that part, and how it is turned there.
        origin: Vector,
        orientation: math.Matrix,
        model: Model,
    };

    pub const Part = struct {
        /// The node's `hidden` flag.
        hidden: bool,
        /// What its part's record says of it, which the components are collected by.
        flags: shp.Part.Flags = std.mem.zeroes(shp.Part.Flags),
        /// Its part's attachment points, which the guns are fitted from. The model they belong to
        /// outlives the object.
        attachments: []const shp.Attachment = &.{},
        /// Its node's `component` flag: the object lists the part among its components
        /// (`create.collectComponents`).
        component: bool = false,
        /// What it has left before it is destroyed, from its part's `component_armor`
        /// (`node_add_part`). Only a component's is read.
        armor: f32 = 0,
        /// What its part's record holds for a component: how much armour it starts with, and the
        /// assembly it belongs to, such as a turret and its barrels.
        component_armor: i32 = 0,
        link_id: u32 = 0,
        /// Its node's `destroyed` flag, which `component_damage` sets on the holder of a component
        /// whose armour has run out.
        destroyed: bool = false,
        /// Its node's `targetable` flag, which cycling subtargets requires and `SetTargetable`
        /// changes.
        targetable: bool = false,
        /// What its part is (part `+0x40`), which the target display names a subtarget by.
        class: shp.Part.Class = @enumFromInt(0),
        /// The part its node hangs from (`object_link_part`), or null for one hanging from the
        /// root. A part names its parent by index, or -1 for none.
        parent: ?usize,
        /// Where its frame stands in the frame of the part it hangs from, or in the model's for one
        /// hanging from the root, and how it's turned there. A model gives every part its origin in
        /// the model whatever its parent, so hanging one from another takes the parent's origin
        /// off it and leaves it where it stood: linking the part places it so (`node_place`), in
        /// the pose its first track has at its start, and an animated part moves on from there
        /// (`frame`).
        origin: Vector,
        turn: math.Matrix = math.identity,
        /// The node's frame: a scene object showing the part's meshes. `place` fills it in.
        object: srapiext.MeshObject,
        /// Its node's animation, and what `node_place` reads of its part.
        animation: Animation = .{},
    };

    /// How a node plays its animation track (node `+0xB4`).
    pub const Mode = shp.PlayMode(i32);

    /// The tracks the loader files by name, for the game to start by it (`node_play`).
    pub const Slot = enum { startup, fire, deploy };

    /// A part node's place in the frame it hangs from.
    pub const Local = math.Place;

    /// A part node's pose: the animation's angles, plus the turret's, and the animation's offset.
    pub const Pose = struct {
        angles: Vector = @splat(0),
        offset: Vector = @splat(0),
    };

    /// A place, and the pose `node_place` worked it out from.
    pub const Posed = struct {
        place: Local = .{},
        pose: Pose = .{},
    };

    /// A part's node as its animation has it: what `node_place` reads of the part, the part's
    /// tracks, which of them the node plays, how and where in it (node `+0xB4` to `+0xD8`), and the
    /// place and pose of the last step and of the next, which the frames drawn between the steps
    /// fall between (`frame`).
    pub const Animation = struct {
        /// The part's origin in the model, its mount point, which it turns about, and its
        /// orientation, in whose frame it turns (part `+0x44`, `+0x98`, `+0xA4`); and the axes it
        /// doesn't turn about whatever the track says (part `+0xC8`).
        position: Vector = @splat(0),
        mount: Vector = @splat(0),
        orientation: math.Matrix = math.identity,
        still: [3]bool = @splat(false),
        /// The part's tracks, and which the loader filed under each name the game starts by.
        tracks: []const shp.Track = &.{},
        slots: std.EnumArray(Slot, ?usize) = .initFill(null),
        mode: Mode = .none,
        track: usize = 0,
        /// Where the node is in its track, and how far it moves on each simulation step.
        time: f32 = 0,
        speed: f32 = 0,
        /// Where the track has the part (node `+0xC4`, `+0xD0`), which `node_animate` sets.
        angles: Vector = @splat(0),
        offset: Vector = @splat(0),
        /// The place `node_place` worked out for the next step, and its pose (node `+0x5C` to
        /// `+0xA3`), and the ones `node_tree_update` committed from them (`+0x14` to `+0x5B`).
        next: Posed = .{},
        now: Posed = .{},
        /// The node's flags this keeps (`Node.Flags`): `next_pending`, `committed`, `unframed`,
        /// `posed` and `animating`.
        pending: bool = false,
        committed: bool = false,
        unframed: bool = false,
        posed: bool = false,
        animating: bool = false,
    };

    /// The part `index` hangs from, or null where it hangs from the root: the index a part names,
    /// unless it names none or one no model part answers to.
    fn parentOf(model: *const shp.Model, index: usize) ?usize {
        const named = model.parts[index].part.parent;
        if (named < 0 or named == index) return null;
        const parent: usize = @intCast(named);
        return if (parent < model.parts.len) parent else null;
    }

    /// The part hanging from the root that `part` hangs from, however deep, or `part` itself where
    /// it hangs from the root. Parents that run in a circle end the walk once it has taken as many
    /// steps as there are parts.
    pub fn topOf(model: *const Model, part: *const Part) *const Part {
        var top = part;
        for (model.parts) |_| top = &model.parts[top.parent orelse break];
        return top;
    }

    /// The part the root holds `child` of, counting only the parts hanging from the root, in the
    /// order they were linked. **Unverified:** the root lists nothing else before them.
    pub fn rootChild(model: *const Model, child: usize) ?*const Part {
        var seen: usize = 0;
        for (model.parts) |*part| {
            if (part.parent != null) continue;
            if (seen == child) return part;
            seen += 1;
        }
        return null;
    }

    /// The parts in an order that puts each after the one it hangs from, so that placing them in
    /// it needs only one pass: by how far each stands from the root, which a part's parent is
    /// always nearer than. A part whose parents run in a circle is taken as standing at the root,
    /// which keeps a broken model from looping here.
    fn linkOrder(gpa: Allocator, model: *const shp.Model) Allocator.Error![]usize {
        const depths = try gpa.alloc(usize, model.parts.len);
        defer gpa.free(depths);
        for (depths, 0..) |*depth, index| {
            depth.* = 0;
            var at = parentOf(model, index);
            while (at) |parent| : (at = parentOf(model, parent)) {
                depth.* += 1;
                if (depth.* > model.parts.len) {
                    depth.* = 0;
                    break;
                }
            }
        }
        const order = try gpa.alloc(usize, model.parts.len);
        var at: usize = 0;
        for (0..model.parts.len + 1) |depth| {
            for (depths, 0..) |part_depth, index| {
                if (part_depth != depth) continue;
                order[at] = index;
                at += 1;
            }
        }
        assert(at == order.len);
        return order;
    }

    /// A node for each part of `model` (`node_add_part`, `0x00499430`), its object flagged as
    /// `model_load` left the part (`loaded`), reached by the lights `lightMask` lets through, and as
    /// far across as its largest level. A part of a component's damaged model is hidden. The parts
    /// hang from nothing yet: `gameobj.linkParts` hangs them, once whatever the model plays from
    /// the start is playing (`create_object`).
    pub fn create(gpa: Allocator, model: *const shp.Model, loaded: *const srofiles.Loaded, effects: Effects) Allocator.Error!Model {
        return build(gpa, model, loaded, effects, 0);
    }

    /// `create`, with how many mounts deep this model already stands.
    fn build(gpa: Allocator, model: *const shp.Model, loaded: *const srofiles.Loaded, effects: Effects, depth: usize) Allocator.Error!Model {
        const parts = try gpa.alloc(Part, model.parts.len);
        errdefer gpa.free(parts);
        for (parts, model.parts, loaded.parts, 0..) |*node, source, part, index| {
            var radius: f32 = 0;
            for (part.meshes) |mesh| radius = @max(radius, mesh.radius);
            const at = source.part.position;
            const still = source.part.unknown_c8;
            node.* = .{
                .hidden = source.part.flags.damaged,
                .flags = source.part.flags,
                .attachments = source.attachments,
                .armor = @floatFromInt(source.part.component_armor),
                .component_armor = source.part.component_armor,
                .class = source.part.class,
                .link_id = source.part.link_id,
                .parent = parentOf(model, index),
                .origin = @splat(0),
                .object = .{
                    .flags = part.flags,
                    .position = .{ at.x, at.y, at.z },
                    .radius = radius,
                    .light_mask = lightMask(model.header.flags.components),
                    .levels = part.levels,
                },
                .animation = .{
                    .position = .{ at.x, at.y, at.z },
                    .mount = .{ source.part.mount_point.x, source.part.mount_point.y, source.part.mount_point.z },
                    .orientation = source.part.orientation,
                    // Three whole numbers, which the game tests as floats against zero.
                    .still = .{ @as(u32, @bitCast(still.x)) != 0, @as(u32, @bitCast(still.y)) != 0, @as(u32, @bitCast(still.z)) != 0 },
                    .tracks = source.tracks,
                    .slots = slotsOf(source.tracks),
                },
            };
        }
        const order = try linkOrder(gpa, model);
        errdefer gpa.free(order);
        var built: Model = .{ .parts = parts, .order = order, .lights = &.{}, .glows = &.{}, .mounts = &.{} };
        const lights = try createLights(gpa, model, effects.light_sprites);
        errdefer gpa.free(lights);
        const glows = try createGlows(gpa, model, effects.glows);
        errdefer gpa.free(glows);
        built.lights = lights;
        built.glows = glows;
        built.mounts = try createMounts(gpa, model, effects, depth);
        return built;
    }

    /// Which of `tracks` the loader files under each name it knows (`model_load`): the last of
    /// each name, whatever its case.
    fn slotsOf(tracks: []const shp.Track) std.EnumArray(Slot, ?usize) {
        var slots: std.EnumArray(Slot, ?usize) = .initFill(null);
        for (tracks, 0..) |track, index| {
            for (std.enums.values(Slot)) |slot| {
                if (std.ascii.eqlIgnoreCase(track.clip.name(), @tagName(slot))) slots.set(slot, index);
            }
        }
        return slots;
    }

    /// `node_animate` (`0x00499F40`): poses part `index` as its track has it at time `at`, between
    /// the keyframes either side of it, or as the last where `at` runs past them all, then places
    /// it by that pose (`node_place`). Before its first keyframe it moves from no pose at time
    /// zero. A node whose track is past the part's has no pose.
    pub fn animate(model: *Model, index: usize, at: f32) void {
        const a = &model.parts[index].animation;
        if (a.track >= a.tracks.len) {
            a.angles = @splat(0);
            a.offset = @splat(0);
            return model.pose(index);
        }
        var before: Pose = .{};
        var when: f32 = 0;
        var key: Pose = .{};
        for (a.tracks[a.track].keyframes) |keyframe| {
            key = .{
                .angles = .{ keyframe.angles.x, keyframe.angles.y, keyframe.angles.z },
                .offset = .{ keyframe.offset.x, keyframe.offset.y, keyframe.offset.z },
            };
            const time: f32 = @floatFromInt(keyframe.time);
            if (at <= time) {
                if (when == time) break;
                const t = (at - when) / (time - when);
                const s: Vector = @splat(1 - t);
                const u: Vector = @splat(t);
                a.angles = before.angles * s + key.angles * u;
                a.offset = before.offset * s + key.offset * u;
                return model.pose(index);
            }
            before = key;
            when = time;
        }
        a.angles = key.angles;
        a.offset = key.offset;
        model.pose(index);
    }

    /// `node_place` (`0x0049A140`): works part `index`'s next place out from its animation's
    /// angles, less those about the axes it doesn't turn about, and its offset, and marks it
    /// pending and posed. Its pose adds the turret's angles, which the port doesn't steer yet.
    fn pose(model: *Model, index: usize) void {
        const a = &model.parts[index].animation;
        inline for (0..3) |axis| {
            if (a.still[axis]) a.angles[axis] = 0;
        }
        const posed: Pose = .{ .angles = a.angles, .offset = a.offset };
        a.next = .{ .place = model.placeFor(index, posed), .pose = posed };
        a.pending = true;
        a.posed = true;
    }

    /// Where a pose puts part `index` in the frame it hangs from (`node_place`): its origin in the
    /// model plus the pose's offset, less the origin of the part it hangs from, or less the
    /// object's centre for one at the root, turned about its mount point by the pose's angles in
    /// the part's own frame, which is its orientation transposed, times the angles' turn, times
    /// its orientation. No angles leave it unturned.
    fn placeFor(model: *const Model, index: usize, posed: Pose) Local {
        const part = &model.parts[index];
        const a = &part.animation;
        const turn = math.product(math.product(math.transpose(a.orientation), math.fromAngleVector(posed.angles)), a.orientation);
        const from = if (part.parent) |parent| model.parts[parent].animation.position else model.centre;
        var at = a.position + posed.offset;
        at -= from;
        var lever = a.mount - posed.offset;
        at += lever;
        lever = math.transform(turn, lever);
        at -= lever;
        return .{ .position = at, .orientation = turn };
    }

    /// `node_play` (`0x0049A2D0`): plays on part `index`'s node the track the loader filed under
    /// `slot`, from `time` unless that is below zero, in `mode`, or the track's own where null, at
    /// `speed` a step. Nothing, where the part has no such track.
    pub fn play(model: *Model, index: usize, slot: Slot, time: f32, mode: ?Mode, speed: f32) void {
        const track = model.parts[index].animation.slots.get(slot) orelse return;
        model.start(index, track, time, mode, speed);
    }

    /// `node_play_named` (`0x0049A340`): likewise for the first of the part's tracks named `name`,
    /// whatever its case.
    pub fn playNamed(model: *Model, index: usize, name: []const u8, time: f32, mode: ?Mode, speed: f32) void {
        for (model.parts[index].animation.tracks, 0..) |track, found| {
            if (!std.ascii.eqlIgnoreCase(track.clip.name(), name)) continue;
            return model.start(index, found, time, mode, speed);
        }
    }

    fn start(model: *Model, index: usize, track: usize, time: f32, mode: ?Mode, speed: f32) void {
        const a = &model.parts[index].animation;
        const chosen = mode orelse @as(Mode, @enumFromInt(@intFromEnum(a.tracks[track].clip.mode)));
        a.track = track;
        a.mode = chosen;
        if (time >= 0) a.time = time;
        a.speed = speed;
        if (chosen != .none) model.markAnimating(index);
    }

    /// `0x0049A2A0`: marks part `index`'s node as animating, and every node it hangs from up to
    /// the root, unless it is marked already.
    fn markAnimating(model: *Model, index: usize) void {
        if (model.parts[index].animation.animating) return;
        var at: ?usize = index;
        while (at) |part| : (at = model.parts[part].parent) model.parts[part].animation.animating = true;
    }

    /// `node_frame_update` (`0x0049A460`) for each part node, and each mounted object's, once a
    /// frame before it is drawn, `fraction` of the way through the simulation's step: a node
    /// that the last step committed a new place for is drawn between that place and the next.
    /// One the step posed moves between the two poses, which turns it the short way round; one
    /// that moved otherwise moves in a straight line and turns by a share of the turn between.
    /// Hidden parts, and all that hangs from them, keep their frames. The models the parts mount
    /// are drawn between their steps along with them.
    pub fn frame(model: *Model, fraction: f32) void {
        var walked: std.StaticBitSet(gameobj.walk_room) = .initEmpty();
        for (model.order) |index| {
            const part = &model.parts[index];
            if (index >= gameobj.walk_room or part.hidden) continue;
            if (part.parent) |parent| {
                if (!walked.isSet(parent)) continue;
            }
            walked.set(index);
            const a = &part.animation;
            if (!a.committed and !a.unframed) continue;
            a.unframed = false;
            const local: Local = if (fraction == 0) a.now.place else if (!a.posed) between(a.now.place, a.next.place, fraction) else posed: {
                const f: Vector = @splat(fraction);
                const offset = (a.next.pose.offset - a.now.pose.offset) * f + a.now.pose.offset;
                var turned = a.next.pose.angles - a.now.pose.angles;
                inline for (0..3) |axis| {
                    if (std.math.pi < turned[axis]) turned[axis] -= std.math.tau;
                    if (turned[axis] < -std.math.pi) turned[axis] += std.math.tau;
                }
                const angles = turned * f + a.now.pose.angles;
                break :posed model.placeFor(index, .{ .angles = angles, .offset = offset });
            };
            part.origin = local.position;
            part.turn = local.orientation;
        }
        for (model.mounts) |*mount| mount.model.frame(fraction);
    }

    /// One light for each attachment of kind `light` a part carries, at its place in the model
    /// (`node_mount_light`), with its sprites or the light it casts, or both.
    fn createLights(gpa: Allocator, model: *const shp.Model, images: LightSprites) Allocator.Error![]Light {
        var count: usize = 0;
        for (model.parts) |part| {
            for (part.attachments) |attachment| {
                if (attachment.kind == .light) count += 1;
            }
        }
        const lights = try gpa.alloc(Light, count);
        var made: usize = 0;
        for (model.parts, 0..) |part, index| {
            for (part.attachments) |attachment| {
                if (attachment.kind != .light) continue;
                const light = &lights[made];
                made += 1;
                light.* = .{
                    .part = index,
                    .origin = .{ attachment.position.x, attachment.position.y, attachment.position.z },
                    .blink = .{ .times = attachment.blink, .phase = attachment.blink_phase },
                    .sprites = null,
                    .cast = null,
                };
                if (attachment.size[0] > 0) {
                    light.sprites = .{
                        .colour = lightColour(attachment.id),
                        .lamp_colour = lampColour(attachment.id),
                        .size = attachment.size[1],
                        .set = .{ .flags = .{ ._unknown_6 = 1 }, .surface = lightSurface(images.flare), .sprites = &.{} },
                        .sprite = @splat(.{ .bias = attachment.size[0] * 9 * sprite_bias }),
                        .lamp = lightSurface(images.lamp),
                    };
                    // The set and its lamp point into the light itself, which does not move again.
                    const sprites = &light.sprites.?;
                    sprites.sprite[Light.Sprites.lamp_sprite].surface = &sprites.lamp;
                    sprites.set.sprites = &sprites.sprite;
                    // A sprite whose image the game lacks is left out.
                    sprites.sprite[Light.Sprites.flare].hidden = images.flare == null;
                    sprites.sprite[Light.Sprites.lamp_sprite].hidden = images.lamp == null;
                }
                const blinks = attachment.blink[0] +% attachment.blink[1] != 0;
                if (attachment.light_brightness > 0 and blinks) {
                    light.cast = .{
                        .mask = 0,
                        .intensity = attachment.light_brightness,
                        .colour = lightColour(attachment.id),
                        .kind = .{ .point = .{ .position = @splat(0), .range = attachment.light_range } },
                    };
                }
            }
        }
        return lights;
    }

    /// One glow for each attachment of kind `engine_glow` a part carries, at its place in the model
    /// (`node_mount_glow`). A model carries none while the glows' meshes are not built.
    fn createGlows(gpa: Allocator, model: *const shp.Model, glows: ?*const environfx.Glows) Allocator.Error![]Glow {
        const built = glows orelse return gpa.alloc(Glow, 0);
        var count: usize = 0;
        for (model.parts) |part| {
            for (part.attachments) |attachment| {
                if (attachment.kind == .engine_glow) count += 1;
            }
        }
        const made = try gpa.alloc(Glow, count);
        var at: usize = 0;
        for (model.parts, 0..) |part, index| {
            for (part.attachments) |attachment| {
                if (attachment.kind != .engine_glow) continue;
                const glow = &made[at];
                at += 1;
                const size: Vector = attachment.size;
                glow.* = .{
                    .part = index,
                    .origin = .{ attachment.position.x, attachment.position.y, attachment.position.z },
                    .orientation = attachment.orientation,
                    .size = size,
                    // Its plume burns the way the attachment's Z axis points, so a plume that
                    // reaches forward pushes the ship back.
                    .retro = size[2] * attachment.orientation[8] > 0,
                    .steady = attachment.id == steady_glow,
                    .level = .{.{ .mesh = built.mesh(attachment.id), .until = std.math.inf(f32) }},
                    .object = .{
                        // Neither culled nor given a level of detail by how far off it is.
                        .flags = .{ .not_culled = true, .always_drawn = true },
                        .position = @splat(0),
                        .radius = @reduce(.Max, @abs(size)),
                        .levels = &.{},
                    },
                };
                // The object shows the one mesh its kind shares, which does not change again.
                glow.object.levels = glow.level[0..1];
            }
        }
        return made;
    }

    pub fn deinit(model: Model, gpa: Allocator) void {
        for (model.mounts) |mount| mount.model.deinit(gpa);
        gpa.free(model.mounts);
        gpa.free(model.parts);
        gpa.free(model.order);
        gpa.free(model.lights);
        gpa.free(model.glows);
    }

    /// The model each gun and pod attachment holds, mounted on the part that carries it
    /// (`node_mount`). A mount is left out where nothing answers for its model, and a model that
    /// mounts itself stops at `shp.max_mount_depth`.
    fn createMounts(gpa: Allocator, model: *const shp.Model, effects: Effects, depth: usize) Allocator.Error![]Mount {
        const mounts = effects.mounts orelse return gpa.alloc(Mount, 0);
        if (depth >= shp.max_mount_depth) return gpa.alloc(Mount, 0);
        var made: std.ArrayList(Mount) = .empty;
        errdefer {
            for (made.items) |mount| mount.model.deinit(gpa);
            made.deinit(gpa);
        }
        for (model.parts, 0..) |part, index| {
            for (part.attachments) |attachment| {
                const mounted = mounts.of(attachment) orelse continue;
                try made.append(gpa, .{
                    .part = index,
                    .origin = .{ attachment.position.x, attachment.position.y, attachment.position.z },
                    .orientation = attachment.orientation,
                    .model = try build(gpa, mounted.model, mounted.loaded, effects, depth + 1),
                });
                // A mounted model's parts hang as an object's own do, and it stands on its own
                // centre of mass.
                gameobj.linkParts(&made.items[made.items.len - 1].model, mounted.model);
            }
        }
        return made.toOwnedSlice(gpa);
    }

    /// Puts the object's root at `position`, turned by `orientation`, and each part's object with
    /// it: a part standing at the root stands in the root's frame, and one hanging from another
    /// stands in that part's frame, so a part carries what hangs from it
    /// (`SR_object_concate_parents`, `0x004C3490`, for each part's frame).
    pub fn place(model: *Model, position: Vector, orientation: math.Matrix) void {
        model.position = position;
        model.orientation = orientation;
        for (model.order) |index| {
            const part = &model.parts[index];
            const from = if (part.parent) |parent| model.parts[parent].object else null;
            const at = if (from) |carrier| carrier.position else position;
            const turn = if (from) |carrier| carrier.orientation else orientation;
            part.object.position = math.transform(turn, part.origin) + at;
            // A frame whose turn has ones down its diagonal takes its parent's as it is.
            const unturned = part.turn[0] == 1 and part.turn[4] == 1 and part.turn[8] == 1;
            part.object.orientation = if (unturned) turn else math.product(turn, part.turn);
        }
        for (model.mounts) |*mount| {
            const carrier = model.parts[mount.part].object;
            // The attachment where the part that carries it stands.
            const on = (math.Place{ .position = mount.origin, .orientation = mount.orientation })
                .within(.{ .position = carrier.position, .orientation = carrier.orientation });
            // The mounted model stands on its own centre of mass, so its origin goes back by it.
            mount.model.place(math.transform(on.orientation, mount.model.centre) + on.position, on.orientation);
        }
    }

    /// Adds each shown part's object to `layer`, the world's or, for a cockpit, the overlay
    /// (`node_draw`, `0x0049A8C0`, for the model's part nodes), then the lights, unless the view
    /// leaves them out, and the engine glows its shown parts carry. Nothing, for an object too far
    /// off to see.
    ///
    /// Not yet ported: the cloak, and the nodes of kinds 4 and 6.
    pub fn draw(model: *Model, gpa: Allocator, scene: *srcore.Scene, layer: srcore.Layer, view: View) Allocator.Error!void {
        if (view.tooFarOff(model.position, model.radius * model.visibility)) return;
        for (model.parts) |*part| {
            if (part.hidden) continue;
            try xtrabits.sceneAdd(gpa, scene, .{ .mesh = &part.object }, layer);
        }
        for (model.lights) |*light| {
            if (!view.lights) break;
            // A light goes dark with the part that carries it, as a damaged part's does while the
            // part it belongs to is whole.
            if (model.parts[light.part].hidden) continue;
            const blink = light.blink.brightness(view.blink_offset +% view.frame_start);
            if (!(blink > 0)) continue;
            const carrier = model.parts[light.part].object;
            const world = math.transform(carrier.orientation, light.origin) + carrier.position;
            if (light.sprites) |*sprites| {
                sprites.set.position = world;
                sprites.show(blink, math.distance(world, view.camera));
                try xtrabits.sceneAdd(gpa, scene, .{ .sprites = &sprites.set }, layer);
            }
            if (light.cast) |*cast| {
                cast.kind.point.position = world;
                try xtrabits.sceneAdd(gpa, scene, .{ .light = cast }, layer);
            }
        }
        for (model.glows) |*glow| {
            // A glow goes out with the part that carries it, as a light does.
            if (model.parts[glow.part].hidden) continue;
            const burning = glow.plume(view.throttle, view.random) orelse continue;
            const carrier = model.parts[glow.part].object;
            glow.object.position = math.transform(carrier.orientation, glow.origin) + carrier.position;
            // The plume stands as its attachment does, drawn to the size it gives it.
            const scale: math.Matrix = .{ glow.size[0], 0, 0, 0, glow.size[1], 0, 0, 0, burning * glow.size[2] };
            glow.object.orientation = math.product(math.product(carrier.orientation, glow.orientation), scale);
            try xtrabits.sceneAdd(gpa, scene, .{ .mesh = &glow.object }, layer);
        }
        for (model.mounts) |*mount| {
            // What a hidden part carries is hidden with it, as a light and a glow are.
            if (model.parts[mount.part].hidden) continue;
            try mount.model.draw(gpa, scene, layer, view);
        }
    }
};

/// What a model draws its attachments with: the sprites every light draws, the meshes the engine
/// glows draw, and where the models a gun or a pod attachment holds come from. A model carries only
/// the ones it is given.
pub const Effects = struct {
    light_sprites: LightSprites = .{},
    glows: ?*const environfx.Glows = null,
    mounts: ?Mounts = null,
};

/// Where the model an attachment point holds comes from: a gun's or a pod's, parsed and built the
/// way the ship's own is, and living at least as long as the model that mounts it. Whoever has the
/// game's files answers; `load` returns null for a model the game lacks, which mounts nothing.
pub const Mounts = struct {
    context: *anyopaque,
    /// Null for a model the game lacks or cannot read; whoever answers says why.
    load: *const fn (context: *anyopaque, file: []const u8) ?Mounted,

    pub const Mounted = struct {
        model: *const shp.Model,
        loaded: *const srofiles.Loaded,
    };

    /// The model `attachment` mounts, or null where its kind mounts none, the table names none, or
    /// the game lacks the file (`node_mount`, `0x00499A10`).
    fn of(mounts: Mounts, attachment: shp.Attachment) ?Mounted {
        switch (attachment.kind) {
            .gun, .pod => {},
            else => return null,
        }
        const entry = create.models.attachment(attachment.kind, attachment.id) orelse return null;
        const file = entry.model orelse return null;
        return mounts.load(mounts.context, file);
    }
};

/// What a model's lights are drawn by: where the camera stands, since a light's size and brightness
/// follow how far off it is, and the frame's tick, which says where each light stands in its blink.
pub const View = struct {
    camera: Vector = @splat(0),
    /// `frame_start`, the mission tick the frame began on.
    frame_start: i32 = 0,
    /// The object's own offset into its lights' blinks (`GameObject.blink_offset`), which the
    /// lights of what it mounts share.
    blink_offset: i16 = 0,
    /// Whether its lights are drawn: `DisableLights` puts them out, for which `mission_frame` hands
    /// `node_draw` flag 8, which leaves out the nodes of kind 4 attachments.
    lights: bool = true,
    /// How hard the object is burning, between -1 and 1, which is how far its engine glows reach.
    /// `object_draw` is given the throttle of its last update, dimmed by the share of its engines
    /// still standing.
    throttle: f32 = 0,
    /// Where the glows' flicker comes from; without one they burn steady.
    random: ?*libcmt.Rand = null,
    /// Pixels to a view unit across the screen (`srapi.Projection.scale`), which says how far off
    /// an object stops being worth drawing. Zero draws one however far off it stands.
    scale: f32 = 0,

    /// Whether an object of `radius` standing at `at` is too far off to be worth drawing
    /// (`node_draw`): its radius no longer covers a pixel, since the radius over the distance,
    /// times the screen's scale, is how many pixels across it is drawn.
    pub fn tooFarOff(view: View, at: Vector, radius: f32) bool {
        if (!(view.scale > 0)) return false;
        const reach = view.scale * radius;
        const away = at - view.camera;
        return reach * reach < math.dot(away, away);
    }
};

/// The share of a simulation step each game tick takes, which `node_frame_update` counts in.
const tick_share: f32 = 1.0 / @as(f32, @import("gameobj.zig").ticks_per_step);

/// How far into its step the simulation is, which `node_frame_update` draws each object between
/// its last two places by: a quarter for each tick since the step (`simulation_counter`).
///
/// **Improvement:** with `smooth`, the time past the last tick counts as well, so that what
/// moves moves on every frame rather than every tick, and evenly at any display rate; the
/// original moves it on in hundredths of a second, which a display's frames fall between
/// unevenly. While the game is paused nothing moves, so the time past the tick doesn't count.
pub fn stepFraction(clock: *const Clock, smooth: bool) f32 {
    const ticks: f32 = @floatFromInt(clock.simulation_counter);
    return (ticks + pastTick(clock, smooth)) * tick_share;
}

/// How far past its last tick the frame is drawn, as a share of a tick: what the effects, which
/// move by their velocities a tick, are drawn that much further along by. None without `smooth`
/// or while the game is paused, as `stepFraction` counts it.
pub fn pastTick(clock: *const Clock, smooth: bool) f32 {
    return if (!smooth or clock.paused) 0 else clock.past_tick;
}

/// Where `node_frame_update` draws a node that moved rather than posed, `fraction` of the way from
/// `now` to `next`: along the straight line between, and turned from `now` by that share of the
/// angles that turn it to `next`.
fn between(now: Model.Local, next: Model.Local, fraction: f32) Model.Local {
    const f: Vector = @splat(fraction);
    const position = (next.position - now.position) * f + now.position;
    const angles = math.angles(math.product(math.transpose(now.orientation), next.orientation)) * f;
    return .{ .position = position, .orientation = math.product(now.orientation, math.fromAngleVector(angles)) };
}

/// The glow that burns at its full length whatever the throttle, the last of the seven
/// (`node_draw`).
const steady_glow = environfx.glow_kinds;

/// The least of its length a plume ever flickers down to, and how far above that it reaches.
const flicker_least: f32 = 0.8;
const flicker_range: f32 = 0.2;

comptime {
    assert(flicker_least + flicker_range == 1);
}

/// What a plume's length is scaled by this frame: somewhere between `flicker_least` and its whole
/// length, so that a burning engine is never quite still (`node_draw`).
fn flicker(random: ?*libcmt.Rand) f32 {
    const source = random orelse return 1;
    const share = @as(f32, @floatFromInt(source.rand())) * (1.0 / @as(f32, libcmt.Rand.max));
    return share * flicker_range + flicker_least;
}

/// The sprites every light draws, whatever its colour (`node_mount_light`): the flare, which
/// attachment kind 4 id 0 names, and the lamp, which id 1 names.
pub const LightSprites = struct {
    flare: ?*srtexture.Image = null,
    lamp: ?*srtexture.Image = null,

    pub fn load(textures: *srtexture.Table) matmanager.Error!LightSprites {
        return .{ .flare = try sprite(textures, 0), .lamp = try sprite(textures, 1) };
    }

    fn sprite(textures: *srtexture.Table, id: u32) matmanager.Error!?*srtexture.Image {
        const entry = create.models.attachment(.light, id) orelse return null;
        const name = entry.sprite orelse return null;
        return try matmanager.textureRequire(textures, name);
    }
};

/// The colour of a light of each attachment id: its flare's, and the light it casts
/// (`node_draw`, `node_mount_light`). Past the sixth it takes none.
fn lightColour(id: u32) [3]f32 {
    return switch (id) {
        0 => .{ 0, 0, 1 },
        1 => .{ 0, 1, 0 },
        2 => .{ 1, 1, 0 },
        3 => .{ 1, 0, 0 },
        4 => .{ 0, 1, 1 },
        5 => .{ 1, 1, 1 },
        else => .{ 0, 0, 0 },
    };
}

/// A light's sprite, added and lit by its own colour, as the sun's sprites are.
fn lightSurface(image: ?*srtexture.Image) srapiext.Surface {
    return .{
        .material = .onePass(.{ .coordinates = .mesh, .lit = true, .blend = .add }),
        .textures = .{ if (image) |texture| .{ .image = texture } else .none, .none },
    };
}

/// The paler colour of a light's lamp, for each attachment id (`node_draw`). Past the sixth it
/// takes none.
fn lampColour(id: u32) [3]f32 {
    return switch (id) {
        0 => .{ 0.2, 0.5, 1 },
        1 => .{ 0.5, 1, 0.5 },
        2 => .{ 1, 1, 0.5 },
        3 => .{ 1, 0.5, 0.2 },
        4 => .{ 0.5, 1, 1 },
        5 => .{ 1, 1, 1 },
        else => .{ 0, 0, 0 },
    };
}

/// How far a light's flare reaches at its largest, and its lamp, over the attachment's height.
const flare_scale: f32 = 7;
const lamp_scale: f32 = 0.3;

/// The share of its colour a light's flare takes.
const flare_share: f32 = 0.5;

/// What a light's two sprites add to their depth for sorting, over the attachment's width times 9
/// (`node_mount_light`): both sort a little nearer than they stand.
const sprite_bias: f32 = -0.25;

/// A light fades out over this much of its blink's clock.
const blink_fade = 200;

/// The least brightness in its blink at which a light still shows its lamp.
const lamp_least: f32 = 0.9;

/// A light's flare is at its brightest up to `full_at` units off and fades to `faded` of that by
/// `faded_at`, staying there beyond; it grows with how far off it is up to `grown_at`, so that it
/// stays worth seeing at a distance.
const full_at: f32 = 1000;
const faded_at: f32 = 15000;
const faded: f32 = 0.1;
const grown_at: f32 = 6000;

/// Hangs each part of `model` from its parent as `gameobj.linkParts` does, leaving its origin
/// where it is.
fn testingLink(model: *Model) void {
    for (0..model.parts.len) |index| gameobj.linkPart(model, index);
}

/// A part record for the tests: nothing in it but an orientation, which every model's part has.
fn testingPart() shp.PartData {
    var data = std.mem.zeroes(shp.PartData);
    data.part.orientation = math.identity;
    return data;
}

/// Fixtures for the tests here and in the modules that build models.
pub const testing = struct {
    /// A part with no mesh, no mass and no tracks, standing unturned at the model's origin.
    pub const part = testingPart;
};

test "Node.commitNext" {
    var node: Node = std.mem.zeroes(Node);
    node.next_position = .{ .x = 1, .y = 2, .z = 3 };
    node.next_orientation = .{ 0, 1, 0, 1, 0, 0, 0, 0, 1 };
    node.next_pose.offset.z = 7;
    node.flags.posed = true;
    // Nothing pending: only bits 1 and 3 are cleared.
    node.commitNext();
    try std.testing.expectEqual(0, node.position.x);
    try std.testing.expect(!node.flags.posed);
    // Pending: the whole next block is committed, and the flags say so.
    node.flags.next_pending = true;
    node.commitNext();
    try std.testing.expectEqual(node.next_position, node.position);
    try std.testing.expectEqual(node.next_orientation, node.orientation);
    try std.testing.expectEqual(7, node.pose.offset.z);
    try std.testing.expect(!node.flags.next_pending and node.flags.committed and node.flags.unframed);
    // The next visit clears bit 1 again but leaves bit 2.
    node.commitNext();
    try std.testing.expect(!node.flags.committed and node.flags.unframed);
}

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
        .parent = null,
        .origin = .{ 0, 0, 100 },
        .object = .{ .flags = .{}, .position = @splat(0), .radius = mesh.radius, .levels = &levels },
    }};
    // A light standing on that part, at its own place on it.
    var lights = [_]Model.Light{.{
        .part = 0,
        .origin = .{ 0, 0, 0 },
        .blink = .{},
        .sprites = .{
            .colour = .{ 1, 0, 0 },
            .lamp_colour = .{ 1, 0.5, 0.2 },
            .size = 10,
            .set = .{ .sprites = &.{} },
            .sprite = @splat(.{}),
            .lamp = lightSurface(null),
        },
        .cast = null,
    }};
    lights[0].sprites.?.set.sprites = &lights[0].sprites.?.sprite;
    var model: Model = .{ .parts = &parts, .order = &.{0}, .lights = &lights, .glows = &.{}, .mounts = &.{} };
    // A part hangs at its origin, turned with the root.
    model.place(.{ 1000, 0, 0 }, math.rotation(.y, std.math.pi / 2.0));
    try std.testing.expectApproxEqAbs(1100, parts[0].object.position[0], 1e-3);

    var scene: srcore.Scene = .{};
    defer scene.deinit(gpa);
    try model.draw(gpa, &scene, .world, .{});
    // Its one part and the light standing on it.
    try std.testing.expectEqual(2, scene.layers.get(.world).items.len);
    // Recentred on its one part's mass, its origin moves to the part's centre: 100 along Z, plus
    // the part's own first moment over its volume.
    var data = testingPart();
    data.part.volume = 2;
    data.part.density = 3;
    data.part.first_moments = .{ 0, 0, 20 };
    const source: shp.Model = .{ .header = std.mem.zeroes(shp.Header), .parts = (&data)[0..1], .tail_count = 0, .trailing_bytes = 0 };
    gameobj.recentre(&model, &source);
    try std.testing.expectEqual(@as(Vector, .{ 0, 0, 110 }), model.centre);
    try std.testing.expectEqual(@as(Vector, .{ 0, 0, -10 }), parts[0].origin);
    // A light hangs on the part that carries it, so recentring leaves it where it stood on the
    // hull: drawn, its sprite stands where the part does.
    model.place(@splat(0), math.identity);
    scene.clear();
    try model.draw(gpa, &scene, .world, .{});
    try std.testing.expectEqual(parts[0].object.position, lights[0].sprites.?.set.position);
    model.place(.{ 1000, 0, 0 }, math.rotation(.y, std.math.pi / 2.0));
    try std.testing.expectApproxEqAbs(@sqrt(100.0 * 100.0 * 2.0 + 10.0 * 10.0), model.radius, 1e-3);

    // The part and its light are both drawn; hidden, the part takes its light with it.
    scene.clear();
    try model.draw(gpa, &scene, .world, .{});
    try std.testing.expectEqual(2, scene.layers.get(.world).items.len);
    scene.clear();
    parts[0].hidden = true;
    try model.draw(gpa, &scene, .world, .{});
    try std.testing.expectEqual(0, scene.layers.get(.world).items.len);
    parts[0].hidden = false;

    // With its lights out, the part alone.
    scene.clear();
    try model.draw(gpa, &scene, .world, .{ .lights = false });
    try std.testing.expectEqual(1, scene.layers.get(.world).items.len);
}

test lightColour {
    // The six the drawing knows, and nothing beyond them.
    try std.testing.expectEqual([3]f32{ 0, 0, 1 }, lightColour(0));
    try std.testing.expectEqual([3]f32{ 1, 0, 0 }, lightColour(3));
    try std.testing.expectEqual([3]f32{ 0, 1, 1 }, lightColour(4));
    try std.testing.expectEqual([3]f32{ 1, 1, 1 }, lightColour(5));
    try std.testing.expectEqual([3]f32{ 0, 0, 0 }, lightColour(6));
}

test lampColour {
    // Paler than the light's own colour, and nothing past the sixth.
    try std.testing.expectEqual([3]f32{ 0.2, 0.5, 1 }, lampColour(0));
    try std.testing.expectEqual([3]f32{ 1, 0.5, 0.2 }, lampColour(3));
    try std.testing.expectEqual([3]f32{ 1, 1, 1 }, lampColour(5));
    try std.testing.expectEqual([3]f32{ 0, 0, 0 }, lampColour(6));
}

test "Model.Blink.brightness" {
    // A light that does not blink is always full on.
    var blink: Model.Blink = .{};
    try std.testing.expectEqual(1, blink.brightness(0));
    try std.testing.expectEqual(1, blink.brightness(12_345));

    // On for 1000 of its clock, then off for 1000; the clock runs ten to the tick.
    blink.times = .{ 1000, 1000 };
    try std.testing.expectEqual(1, blink.brightness(0));
    try std.testing.expectEqual(1, blink.brightness(100)); // at 1000, still on
    // Just past the on time it fades, and by 200 of its clock it is out.
    try std.testing.expectEqual(0.5, blink.brightness(110));
    try std.testing.expect(blink.brightness(120) <= 0);
    // Its phase shifts where it stands: the same light started later is still on.
    blink.phase = 1000;
    try std.testing.expectEqual(1, blink.brightness(110));
    // Before its phase has passed, its clock wraps as an unsigned number does: at 796 of the
    // 2000, still on, where a signed remainder would put it at 1500, out.
    blink.phase = 500;
    try std.testing.expectEqual(1, blink.brightness(0));
}

test "Model.Light.Sprites.show" {
    var sprites: Model.Light.Sprites = .{
        .colour = .{ 1, 0, 0 },
        .lamp_colour = .{ 1, 0.5, 0.2 },
        .size = 10,
        .set = .{ .sprites = &.{} },
        .sprite = @splat(.{}),
        .lamp = lightSurface(null),
    };
    const flare = &sprites.sprite[Model.Light.Sprites.flare];
    const lamp = &sprites.sprite[Model.Light.Sprites.lamp_sprite];

    // Near and full on: the flare takes half the colour and grows with how far off it is; the lamp
    // keeps its own size and its paler colour.
    sprites.show(1, 600);
    try std.testing.expectEqual([3]f32{ 0.5, 0, 0 }, flare.colour);
    try std.testing.expectApproxEqAbs(7, flare.half_size[0], 1e-5);
    try std.testing.expectEqual(flare.half_size[0], flare.half_size[1]);
    try std.testing.expectEqual([2]f32{ 3, 3 }, lamp.half_size);
    try std.testing.expectEqual([3]f32{ 1, 0.5, 0.2 }, lamp.colour);

    // Fading in its blink, the lamp goes out at once while the flare dims.
    sprites.show(0.5, 600);
    try std.testing.expectEqual([3]f32{ 0.25, 0, 0 }, flare.colour);
    try std.testing.expectEqual([3]f32{ 0, 0, 0 }, lamp.colour);

    // Past six thousand units the flare stops growing; from a thousand it fades, to a tenth by
    // fifteen thousand, and stays there beyond.
    sprites.show(1, 8000);
    try std.testing.expectEqual([2]f32{ 70, 70 }, flare.half_size);
    try std.testing.expectApproxEqAbs(0.275, flare.colour[0], 1e-6);
    sprites.show(1, 100_000);
    try std.testing.expectApproxEqAbs(0.05, flare.colour[0], 1e-6);

    // Brighter than full is held at full.
    sprites.show(2, 0);
    try std.testing.expectEqual([3]f32{ 0.5, 0, 0 }, flare.colour);
    try std.testing.expectEqual([2]f32{ 0, 0 }, flare.half_size);
}

test "a model's lights: their sprites, and the light a blinking one casts" {
    const gpa = std.testing.allocator;
    const srmesh = @import("../surrender/surrenderlib/srmesh.zig");
    const mesh = try srmesh.testing.square(gpa);
    defer mesh.deinit(gpa);
    var levels = [_]srapiext.Level{.{ .mesh = &mesh, .until = std.math.inf(f32) }};
    var loaded_parts = [1]srofiles.LoadedPart{.{ .flags = .{}, .levels = &levels, .meshes = &.{} }};
    const loaded: srofiles.Loaded = .{ .parts = &loaded_parts };

    // Three lights on one hull: a steady one with a width; a blinking red one with a brightness
    // but no width; a blinking one with a width but no brightness.
    var attachments: [3]shp.Attachment = @splat(.{
        .kind = .light,
        .position = .{ .x = 0, .y = 0, .z = 0 },
        .orientation = math.identity,
        .id = 0,
        ._unknown_38 = @splat(0),
        .size = .{ 2, 3, 0 },
        .blink = .{ 0, 0 },
        .blink_phase = 0,
        ._unknown_60 = @splat(0),
        .gun_type = 0,
        ._unknown_68 = @splat(0),
        .light_range = 50,
        .light_brightness = 1,
    });
    attachments[1].position = .{ .x = 40, .y = 0, .z = 0 };
    attachments[1].id = 3;
    attachments[1].size = .{ 0, 3, 0 };
    attachments[1].blink = .{ 1000, 1000 };
    attachments[1].light_brightness = 2;
    attachments[2].blink = .{ 1000, 1000 };
    attachments[2].light_brightness = 0;
    var hull = [1]shp.PartData{testingPart()};
    hull[0].part.parent = -1;
    hull[0].attachments = &attachments;
    const model: shp.Model = .{ .header = std.mem.zeroes(shp.Header), .parts = &hull, .tail_count = 0, .trailing_bytes = 0 };

    var flare: srtexture.Image = .{ .levels = &.{} };
    var lamp: srtexture.Image = .{ .levels = &.{} };
    var built: Model = try .create(gpa, &model, &loaded, .{ .light_sprites = .{ .flare = &flare, .lamp = &lamp } });
    defer built.deinit(gpa);
    testingLink(&built);

    // Sprites for the two with a width, sorting nearer by their width; the lamp drawn with its
    // own image, the flare with the set's.
    const steady = built.lights[0].sprites.?;
    try std.testing.expectEqual(-4.5, steady.sprite[Model.Light.Sprites.flare].bias);
    try std.testing.expectEqual(-4.5, steady.sprite[Model.Light.Sprites.lamp_sprite].bias);
    try std.testing.expectEqual(null, steady.sprite[Model.Light.Sprites.flare].surface);
    try std.testing.expectEqual(&built.lights[0].sprites.?.lamp, steady.sprite[Model.Light.Sprites.lamp_sprite].surface.?);
    try std.testing.expectEqual(&lamp, steady.lamp.textures[0].image);
    try std.testing.expectEqual(null, built.lights[1].sprites);
    try std.testing.expect(built.lights[2].sprites != null);
    // A light only for the blinking one with a brightness: its colour, reaching its brightness
    // times its range, and every object that takes lights.
    try std.testing.expectEqual(null, built.lights[0].cast);
    try std.testing.expectEqual(null, built.lights[2].cast);
    const cast = built.lights[1].cast.?;
    try std.testing.expectEqual([3]f32{ 1, 0, 0 }, cast.colour);
    try std.testing.expectEqual(2, cast.intensity);
    try std.testing.expectEqual(50, cast.kind.point.range);
    try std.testing.expect(cast.reaches(lightMask(false)) and cast.reaches(lightMask(true)));

    // Drawn, the hull and the two sets go to the layer and the cast light to the lights, where
    // the light stands on the hull.
    built.place(.{ 0, 0, 1000 }, math.identity);
    var scene: srcore.Scene = .{};
    defer scene.deinit(gpa);
    try built.draw(gpa, &scene, .world, .{});
    try std.testing.expectEqual(3, scene.layers.get(.world).items.len);
    try std.testing.expectEqual(1, scene.lights.items.len);
    try std.testing.expectEqual(@as(Vector, .{ 40, 0, 1000 }), scene.lights.items[0].kind.point.position);
    // Out in its blink, the blinking lights show nothing and cast nothing; the object's offset
    // moves them through it.
    scene.clear();
    try built.draw(gpa, &scene, .world, .{ .frame_start = 150 });
    try std.testing.expectEqual(2, scene.layers.get(.world).items.len);
    try std.testing.expectEqual(0, scene.lights.items.len);
    scene.clear();
    try built.draw(gpa, &scene, .world, .{ .frame_start = 150, .blink_offset = 60 });
    try std.testing.expectEqual(1, scene.lights.items.len);
}

test "an engine glow burns with the throttle" {
    const forward: Model.Glow = .{
        .part = 0,
        .origin = @splat(0),
        .orientation = math.identity,
        .size = .{ 10, 10, 40 },
        .retro = false,
        .steady = false,
        .level = undefined,
        .object = undefined,
    };
    var retro = forward;
    retro.retro = true;
    var steady = forward;
    steady.steady = true;

    // Without a source of flicker a plume burns at just the throttle it is given.
    try std.testing.expectEqual(0.5, forward.plume(0.5, null));
    try std.testing.expectEqual(null, forward.plume(0, null));
    try std.testing.expectEqual(null, forward.plume(-1, null));
    // A retro thruster burns the other way round, on reverse thrust alone.
    try std.testing.expectEqual(null, retro.plume(0.5, null));
    try std.testing.expectEqual(1, retro.plume(-1, null));
    // The steady glow burns full whatever the throttle, and never flickers.
    var random: libcmt.Rand = .{};
    try std.testing.expectEqual(1, steady.plume(0, &random));
    try std.testing.expectEqual(1, steady.plume(-1, &random));
    try std.testing.expectEqual(1, random.seed);

    // A flicker takes a burning plume down by at most a fifth, never past its full length.
    for (0..100) |_| {
        const burning = forward.plume(1, &random).?;
        try std.testing.expect(burning >= flicker_least and burning <= 1);
    }
    try std.testing.expect(random.seed != 1);
}

test "a model draws the glows its parts carry" {
    const gpa = std.testing.allocator;
    const srmesh = @import("../surrender/surrenderlib/srmesh.zig");
    const built: environfx.testing.Built = try .init(gpa);
    defer built.deinit(gpa);
    const mesh = try srmesh.testing.square(gpa);
    defer mesh.deinit(gpa);
    const levels = [_]srapiext.Level{.{ .mesh = &mesh, .until = std.math.inf(f32) }};

    var parts = [_]Model.Part{.{
        .hidden = false,
        .parent = null,
        .origin = .{ 0, 0, 0 },
        .object = .{ .flags = .{}, .position = @splat(0), .radius = mesh.radius, .levels = &levels },
    }};
    var glows = [_]Model.Glow{.{
        .part = 0,
        .origin = .{ 0, 0, -50 },
        .orientation = math.identity,
        .size = .{ 5, 5, 20 },
        .retro = false,
        .steady = false,
        .level = .{.{ .mesh = built.glows.mesh(1), .until = std.math.inf(f32) }},
        .object = .{ .flags = .{ .not_culled = true }, .position = @splat(0), .radius = 20, .levels = &.{} },
    }};
    glows[0].object.levels = glows[0].level[0..1];
    var model: Model = .{ .parts = &parts, .order = &.{0}, .lights = &.{}, .glows = &glows, .mounts = &.{} };
    model.place(.{ 0, 0, 1000 }, math.identity);

    var scene: srcore.Scene = .{};
    defer scene.deinit(gpa);
    // Idle, the ship burns nothing: only its part is drawn.
    try model.draw(gpa, &scene, .world, .{});
    try std.testing.expectEqual(1, scene.layers.get(.world).items.len);

    // At half throttle the plume stands where its attachment does, half as long as it reaches.
    try model.draw(gpa, &scene, .world, .{ .throttle = 0.5 });
    try std.testing.expectEqual(3, scene.layers.get(.world).items.len);
    try std.testing.expectEqual(@as(Vector, .{ 0, 0, 950 }), glows[0].object.position);
    try std.testing.expectEqual(5, glows[0].object.orientation[0]);
    try std.testing.expectEqual(10, glows[0].object.orientation[8]);

    // A glow goes out with the part that carries it.
    parts[0].hidden = true;
    try model.draw(gpa, &scene, .world, .{ .throttle = 1 });
    try std.testing.expectEqual(3, scene.layers.get(.world).items.len);
}

test "a part hangs from the part it names" {
    const gpa = std.testing.allocator;
    const srmesh = @import("../surrender/surrenderlib/srmesh.zig");
    const mesh = try srmesh.testing.square(gpa);
    defer mesh.deinit(gpa);

    // Three parts: a hull at the model's origin, a turret standing on it, and a barrel on the
    // turret. The barrel comes first, so the order has to sort them out.
    var data = [3]shp.PartData{
        testingPart(),
        testingPart(),
        testingPart(),
    };
    data[0].part.position = .{ .x = 0, .y = 0, .z = 300 };
    data[0].part.parent = 1;
    data[1].part.position = .{ .x = 0, .y = 0, .z = 100 };
    data[1].part.parent = 2;
    data[2].part.position = .{ .x = 0, .y = 0, .z = 0 };
    data[2].part.parent = -1;
    const source: shp.Model = .{ .header = std.mem.zeroes(shp.Header), .parts = &data, .tail_count = 0, .trailing_bytes = 0 };

    var levels = [_]srapiext.Level{.{ .mesh = &mesh, .until = std.math.inf(f32) }};
    var loaded_parts = [3]srofiles.LoadedPart{
        .{ .flags = .{}, .levels = &levels, .meshes = &.{} },
        .{ .flags = .{}, .levels = &levels, .meshes = &.{} },
        .{ .flags = .{}, .levels = &levels, .meshes = &.{} },
    };
    const loaded: srofiles.Loaded = .{ .parts = &loaded_parts };
    var model: Model = try .create(gpa, &source, &loaded, .{});
    defer model.deinit(gpa);
    testingLink(&model);

    // Each hangs from the part it names, and stands at its origin in that part.
    try std.testing.expectEqual(@as(?usize, 1), model.parts[0].parent);
    try std.testing.expectEqual(@as(?usize, 2), model.parts[1].parent);
    try std.testing.expectEqual(@as(?usize, null), model.parts[2].parent);
    try std.testing.expectEqual(@as(Vector, .{ 0, 0, 200 }), model.parts[0].origin);
    try std.testing.expectEqual(@as(Vector, .{ 0, 0, 100 }), model.parts[1].origin);
    // The hull comes before the turret, and the turret before the barrel.
    try std.testing.expectEqualSlices(usize, &.{ 2, 1, 0 }, model.order);

    // Placed, each stands where the model puts it, whatever it hangs from.
    model.place(.{ 1000, 0, 0 }, math.identity);
    try std.testing.expectEqual(@as(Vector, .{ 1000, 0, 300 }), model.parts[0].object.position);
    try std.testing.expectEqual(@as(Vector, .{ 1000, 0, 100 }), model.parts[1].object.position);

    // Turned, a part carries what hangs from it: a quarter turn about Y puts them along X.
    model.place(@splat(0), math.rotation(.y, std.math.pi / 2.0));
    try std.testing.expectApproxEqAbs(300, model.parts[0].object.position[0], 1e-3);
    try std.testing.expectApproxEqAbs(100, model.parts[1].object.position[0], 1e-3);
}

test "a part whose parents run in a circle stands at the root" {
    const gpa = std.testing.allocator;
    var data = [2]shp.PartData{ testingPart(), testingPart() };
    data[0].part.parent = 1;
    data[1].part.parent = 0;
    const source: shp.Model = .{ .header = std.mem.zeroes(shp.Header), .parts = &data, .tail_count = 0, .trailing_bytes = 0 };
    const order = try Model.linkOrder(gpa, &source);
    defer gpa.free(order);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1 }, order);
}

test "a gun attachment mounts the model its id names" {
    const gpa = std.testing.allocator;
    const srmesh = @import("../surrender/surrenderlib/srmesh.zig");
    const mesh = try srmesh.testing.square(gpa);
    defer mesh.deinit(gpa);
    var levels = [_]srapiext.Level{.{ .mesh = &mesh, .until = std.math.inf(f32) }};
    var loaded_parts = [1]srofiles.LoadedPart{.{ .flags = .{}, .levels = &levels, .meshes = &.{} }};
    const loaded: srofiles.Loaded = .{ .parts = &loaded_parts };

    // The gun the mount answers with: one part at the model's origin.
    var gun_data = [1]shp.PartData{testingPart()};
    gun_data[0].part.parent = -1;
    gun_data[0].part.volume = 1;
    gun_data[0].part.density = 1;
    const gun: shp.Model = .{ .header = std.mem.zeroes(shp.Header), .parts = &gun_data, .tail_count = 0, .trailing_bytes = 0 };

    // A hull carrying one gun attachment, out along X, and one of a kind that mounts nothing.
    var attachments = [2]shp.Attachment{ std.mem.zeroes(shp.Attachment), std.mem.zeroes(shp.Attachment) };
    attachments[0] = .{
        .kind = .gun,
        .position = .{ .x = 50, .y = 0, .z = 0 },
        .orientation = math.identity,
        .id = 0,
        ._unknown_38 = @splat(0),
        .size = @splat(0),
        .blink = .{ 0, 0 },
        .blink_phase = 0,
        ._unknown_60 = @splat(0),
        .gun_type = 0,
        ._unknown_68 = @splat(0),
        .light_range = 0,
        .light_brightness = 0,
    };
    attachments[1] = attachments[0];
    attachments[1].kind = .missile;
    var hull = [1]shp.PartData{testingPart()};
    hull[0].part.parent = -1;
    hull[0].attachments = &attachments;
    const model: shp.Model = .{ .header = std.mem.zeroes(shp.Header), .parts = &hull, .tail_count = 0, .trailing_bytes = 0 };

    const Answer = struct {
        gun: *const shp.Model,
        loaded: *const srofiles.Loaded,
        asked: usize = 0,
        fn load(context: *anyopaque, file: []const u8) ?Mounts.Mounted {
            const answer: *@This() = @ptrCast(@alignCast(context));
            answer.asked += 1;
            // Only the gun the table names for kind 1 id 0 is answered for.
            if (!std.mem.eql(u8, file, create.models.attachment(.gun, 0).?.model.?)) return null;
            return .{ .model = answer.gun, .loaded = answer.loaded };
        }
    };
    var answer: Answer = .{ .gun = &gun, .loaded = &loaded };
    var built: Model = try .create(gpa, &model, &loaded, .{
        .mounts = .{ .context = &answer, .load = Answer.load },
    });
    defer built.deinit(gpa);
    testingLink(&built);

    // Only the gun is mounted; the missile attachment mounts nothing and is not even looked for.
    try std.testing.expectEqual(1, built.mounts.len);
    try std.testing.expectEqual(1, answer.asked);
    try std.testing.expectEqual(0, built.mounts[0].part);
    try std.testing.expectEqual(@as(Vector, .{ 50, 0, 0 }), built.mounts[0].origin);
    try std.testing.expectEqual(1, built.mounts[0].model.parts.len);

    // Placed, the mounted model stands at the attachment on the part that carries it.
    built.place(.{ 0, 0, 1000 }, math.identity);
    try std.testing.expectEqual(@as(Vector, .{ 50, 0, 1000 }), built.mounts[0].model.parts[0].object.position);
    // Turned a quarter about Y, the attachment goes with the hull.
    built.place(@splat(0), math.rotation(.y, std.math.pi / 2.0));
    try std.testing.expectApproxEqAbs(0, built.mounts[0].model.parts[0].object.position[0], 1e-3);
    try std.testing.expectApproxEqAbs(-50, built.mounts[0].model.parts[0].object.position[2], 1e-3);

    // It is drawn with the hull, and goes dark with the part that carries it.
    var scene: srcore.Scene = .{};
    defer scene.deinit(gpa);
    try built.draw(gpa, &scene, .world, .{});
    try std.testing.expectEqual(2, scene.layers.get(.world).items.len);
    scene.clear();
    built.parts[0].hidden = true;
    try built.draw(gpa, &scene, .world, .{});
    try std.testing.expectEqual(0, scene.layers.get(.world).items.len);

    // A model that mounts itself stops rather than running on: the gun answers with the hull.
    const Circle = struct {
        model: *const shp.Model,
        loaded: *const srofiles.Loaded,
        fn load(context: *anyopaque, _: []const u8) ?Mounts.Mounted {
            const circle: *@This() = @ptrCast(@alignCast(context));
            return .{ .model = circle.model, .loaded = circle.loaded };
        }
    };
    var circle: Circle = .{ .model = &model, .loaded = &loaded };
    var deep: Model = try .create(gpa, &model, &loaded, .{
        .mounts = .{ .context = &circle, .load = Circle.load },
    });
    defer deep.deinit(gpa);
    testingLink(&deep);
    var depth: usize = 0;
    var at = &deep;
    while (at.mounts.len > 0) : (depth += 1) at = &at.mounts[0].model;
    try std.testing.expectEqual(shp.max_mount_depth, depth);
}

test "an object too far off to cover a pixel is not drawn" {
    const gpa = std.testing.allocator;
    const srmesh = @import("../surrender/surrenderlib/srmesh.zig");
    const mesh = try srmesh.testing.square(gpa);
    defer mesh.deinit(gpa);
    var levels = [_]srapiext.Level{.{ .mesh = &mesh, .until = std.math.inf(f32) }};
    var parts = [_]Model.Part{.{
        .hidden = false,
        .parent = null,
        .origin = @splat(0),
        .object = .{ .flags = .{}, .position = @splat(0), .radius = mesh.radius, .levels = &levels },
    }};
    var model: Model = .{ .parts = &parts, .order = &.{0}, .lights = &.{}, .glows = &.{}, .mounts = &.{} };
    model.radius = 100;
    model.place(.{ 0, 0, 50_000 }, math.identity);

    // A thousand pixels to a view unit: a radius of 100 covers a pixel out to 100,000 units.
    var scene: srcore.Scene = .{};
    defer scene.deinit(gpa);
    try model.draw(gpa, &scene, .world, .{ .scale = 1000 });
    try std.testing.expectEqual(1, scene.layers.get(.world).items.len);
    scene.clear();
    model.place(.{ 0, 0, 150_000 }, math.identity);
    try model.draw(gpa, &scene, .world, .{ .scale = 1000 });
    try std.testing.expectEqual(0, scene.layers.get(.world).items.len);
    // Without a scale nothing is left out, however far off it stands.
    scene.clear();
    try model.draw(gpa, &scene, .world, .{});
    try std.testing.expectEqual(1, scene.layers.get(.world).items.len);
    // An object that sees less far than its size says goes first.
    scene.clear();
    model.place(.{ 0, 0, 50_000 }, math.identity);
    model.visibility = 0.25;
    try model.draw(gpa, &scene, .world, .{ .scale = 1000 });
    try std.testing.expectEqual(0, scene.layers.get(.world).items.len);
}

/// A model of three parts, each hanging from the one before, the second carrying `tracks`, built as
/// `create_object` builds one, for the animation tests.
const Animated = struct {
    data: [3]shp.PartData,
    levels: [1]srapiext.Level,
    loaded_parts: [3]srofiles.LoadedPart,
    loaded: srofiles.Loaded,
    source: shp.Model,

    fn init(animated: *Animated, mesh: *const srapiext.Mesh, tracks: []shp.Track) void {
        animated.levels = .{.{ .mesh = mesh, .until = std.math.inf(f32) }};
        for (&animated.data, &animated.loaded_parts, 0..) |*data, *loaded, index| {
            data.* = testingPart();
            data.part.parent = @as(i32, @intCast(index)) - 1;
            data.part.position = .{ .x = 0, .y = 0, .z = @floatFromInt(100 * index) };
            loaded.* = .{ .flags = .{}, .levels = &animated.levels, .meshes = &.{} };
        }
        animated.data[1].tracks = tracks;
        animated.loaded = .{ .parts = &animated.loaded_parts };
        animated.source = .{ .header = std.mem.zeroes(shp.Header), .parts = &animated.data, .tail_count = 0, .trailing_bytes = 0 };
    }
};

fn testingKey(time: i32, angles: [3]f32, offset: [3]f32) shp.Keyframe {
    return .{
        .time = time,
        .angles = .{ .x = angles[0], .y = angles[1], .z = angles[2] },
        .offset = .{ .x = offset[0], .y = offset[1], .z = offset[2] },
    };
}

fn testingClip(length: i32, mode: Model.Mode, name: []const u8) shp.Clip {
    var made: shp.Clip = .{ .length = length, .mode = @enumFromInt(@intFromEnum(mode)), .name_bytes = @splat(0) };
    @memcpy(made.name_bytes[0..name.len], name);
    return made;
}

test "Model.animate" {
    const gpa = std.testing.allocator;
    const srmesh = @import("../surrender/surrenderlib/srmesh.zig");
    const mesh = try srmesh.testing.square(gpa);
    defer mesh.deinit(gpa);
    var keys = [_]shp.Keyframe{
        testingKey(100, .{ 0, 0, 0 }, .{ 0, 0, 10 }),
        testingKey(200, .{ 0, 0, 0 }, .{ 0, 0, 30 }),
        testingKey(200, .{ 0, 0, 0 }, .{ 0, 0, 99 }),
    };
    var tracks = [_]shp.Track{.{ .clip = testingClip(300, .once, "startup"), .keyframes = &keys, .events = &.{} }};
    var animated: Animated = undefined;
    animated.init(&mesh, &tracks);
    var model: Model = try .create(gpa, &animated.source, &animated.loaded, .{});
    defer model.deinit(gpa);
    testingLink(&model);

    const a = &model.parts[1].animation;
    // Before the first keyframe it moves from no pose at time zero; between two, in a straight
    // line; where two share a time, the first of them; past them all, as the last has it.
    model.animate(1, 50);
    try std.testing.expectEqual(@as(Vector, .{ 0, 0, 5 }), a.offset);
    model.animate(1, 150);
    try std.testing.expectEqual(@as(Vector, .{ 0, 0, 20 }), a.offset);
    model.animate(1, 200);
    try std.testing.expectEqual(@as(Vector, .{ 0, 0, 30 }), a.offset);
    model.animate(1, 1000);
    try std.testing.expectEqual(@as(Vector, .{ 0, 0, 99 }), a.offset);
    // The pose moves the part's next place by its offset, and marks it pending and posed.
    try std.testing.expect(a.pending and a.posed);
    try std.testing.expectEqual(@as(Vector, .{ 0, 0, 199 }), a.next.place.position);
    // A track past the part's leaves it no pose.
    a.track = 5;
    model.animate(1, 150);
    try std.testing.expectEqual(@as(Vector, .{ 0, 0, 0 }), a.offset);
}

test "Model.placeFor" {
    const gpa = std.testing.allocator;
    const srmesh = @import("../surrender/surrenderlib/srmesh.zig");
    const mesh = try srmesh.testing.square(gpa);
    defer mesh.deinit(gpa);
    var animated: Animated = undefined;
    animated.init(&mesh, &.{});
    // The part's frame is turned a quarter about X from the model's, as an exporter leaves many.
    animated.data[1].part.orientation = math.rotation(.x, std.math.pi / 2.0);
    animated.data[1].part.mount_point = .{ .x = 10, .y = 0, .z = 0 };
    var model: Model = try .create(gpa, &animated.source, &animated.loaded, .{});
    defer model.deinit(gpa);
    testingLink(&model);

    // With no pose it stands at its origin in its parent, unturned.
    const rest = model.placeFor(1, .{});
    try std.testing.expect(math.length(rest.position - @as(Vector, .{ 0, 0, 100 })) < 1e-4);
    for (rest.orientation, math.identity) |got, want| try std.testing.expectApproxEqAbs(want, got, 1e-6);
    // Turned, it turns in its own frame, about its mount point, which stays where it is.
    const angles: Vector = .{ 0, 0.5, 0 };
    const turned = model.placeFor(1, .{ .angles = angles });
    const o = model.parts[1].animation.orientation;
    const expected = math.product(math.product(math.transpose(o), math.fromAngles(0, 0.5, 0)), o);
    try std.testing.expectEqual(expected, turned.orientation);
    const mount: Vector = .{ 10, 0, 0 };
    const pivot = math.transform(turned.orientation, mount) + turned.position;
    try std.testing.expect(math.length(pivot - (mount + @as(Vector, .{ 0, 0, 100 }))) < 1e-3);
}

test "a part's first track poses it where it is linked" {
    const gpa = std.testing.allocator;
    const srmesh = @import("../surrender/surrenderlib/srmesh.zig");
    const mesh = try srmesh.testing.square(gpa);
    defer mesh.deinit(gpa);
    // A gun barrel whose firing track starts drawn back.
    var keys = [_]shp.Keyframe{ testingKey(0, .{ 0, 0, 0 }, .{ 0, 0, -60 }), testingKey(50, .{ 0, 0, 0 }, .{ 0, 0, 0 }) };
    var tracks = [_]shp.Track{.{ .clip = testingClip(100, .once, "fire"), .keyframes = &keys, .events = &.{} }};
    var animated: Animated = undefined;
    animated.init(&mesh, &tracks);
    var model: Model = try .create(gpa, &animated.source, &animated.loaded, .{});
    defer model.deinit(gpa);
    testingLink(&model);
    // It stands drawn back from the start, with nothing pending, and plays nothing.
    try std.testing.expectEqual(@as(Vector, .{ 0, 0, 40 }), model.parts[1].origin);
    try std.testing.expect(!model.parts[1].animation.pending and !model.parts[1].animation.animating);
    try std.testing.expectEqual(@as(?usize, 0), model.parts[1].animation.slots.get(.fire));
    try std.testing.expectEqual(@as(?usize, null), model.parts[1].animation.slots.get(.startup));
}

test "Model.play" {
    const gpa = std.testing.allocator;
    const srmesh = @import("../surrender/surrenderlib/srmesh.zig");
    const mesh = try srmesh.testing.square(gpa);
    defer mesh.deinit(gpa);
    var tracks = [_]shp.Track{
        .{ .clip = testingClip(100, .none, "idle"), .keyframes = &.{}, .events = &.{} },
        .{ .clip = testingClip(100, .loop, "STARTUP"), .keyframes = &.{}, .events = &.{} },
    };
    var animated: Animated = undefined;
    animated.init(&mesh, &tracks);
    var model: Model = try .create(gpa, &animated.source, &animated.loaded, .{});
    defer model.deinit(gpa);
    testingLink(&model);
    const a = &model.parts[1].animation;

    // `create_object` plays the `startup` track, whatever its case, as it says, at 4 a step, and
    // marks the part and all it hangs from as animating.
    create.startUp(&model);
    try std.testing.expectEqual(1, a.track);
    try std.testing.expectEqual(Model.Mode.loop, a.mode);
    try std.testing.expectEqual(4, a.speed);
    try std.testing.expect(a.animating and model.parts[0].animation.animating and !model.parts[2].animation.animating);
    // A time below zero leaves the time as it is; a track by a name it doesn't have plays nothing.
    a.time = 30;
    model.playNamed(1, "idle", -1, null, 2);
    try std.testing.expectEqual(0, a.track);
    try std.testing.expectEqual(Model.Mode.none, a.mode);
    try std.testing.expectEqual(30, a.time);
    model.playNamed(1, "wave", 0, .once, 2);
    try std.testing.expectEqual(0, a.track);
    model.play(1, .deploy, 0, .once, 2);
    try std.testing.expectEqual(Model.Mode.none, a.mode);
}

/// Keeps the events a model's tracks set off.
const Fired = struct {
    kinds: [8]gameobj.EventKind = undefined,
    count: usize = 0,

    fn events(fired: *Fired) gameobj.Events {
        return .{ .context = fired, .fire = fire };
    }

    fn fire(context: *anyopaque, _: *Model, _: usize, kind: gameobj.EventKind) void {
        const fired: *Fired = @ptrCast(@alignCast(context));
        fired.kinds[fired.count] = kind;
        fired.count += 1;
    }
};

test "a track plays once, round and round, and back and forth" {
    const gpa = std.testing.allocator;
    const srmesh = @import("../surrender/surrenderlib/srmesh.zig");
    const mesh = try srmesh.testing.square(gpa);
    defer mesh.deinit(gpa);
    var keys = [_]shp.Keyframe{ testingKey(0, .{ 0, 0, 0 }, .{ 0, 0, 0 }), testingKey(100, .{ 0, 0, 0 }, .{ 0, 0, 100 }) };
    var events = [_]shp.ClipEvent{
        .{ .time = 10, .kind = 0, ._unknown_08 = 0 },
        .{ .time = 90, .kind = 2, ._unknown_08 = 0 },
        .{ .time = 50, .kind = 3, ._unknown_08 = 0 },
    };
    var tracks = [_]shp.Track{.{ .clip = testingClip(100, .once, "fire"), .keyframes = &keys, .events = &events }};
    var animated: Animated = undefined;
    animated.init(&mesh, &tracks);
    var model: Model = try .create(gpa, &animated.source, &animated.loaded, .{});
    defer model.deinit(gpa);
    testingLink(&model);
    const a = &model.parts[1].animation;
    var root = std.mem.zeroes(Node);
    var fired: Fired = .{};

    // Once: each step moves it on by its speed, setting off the events it passes, a kind the
    // update doesn't know aside; at the end it stops, and the part stops animating.
    model.play(1, .fire, 0, null, 40);
    gameobj.updateTree(&root, &model, fired.events());
    try std.testing.expectEqual(40, a.time);
    try std.testing.expectEqual(1, fired.count);
    try std.testing.expectEqual(gameobj.EventKind.flash, fired.kinds[0]);
    try std.testing.expect(root.flags.animating);
    gameobj.updateTree(&root, &model, fired.events());
    gameobj.updateTree(&root, &model, fired.events());
    try std.testing.expectEqual(100, a.time);
    try std.testing.expectEqual(0, a.speed);
    try std.testing.expectEqual(2, fired.count);
    try std.testing.expectEqual(gameobj.EventKind.puff, fired.kinds[1]);
    // Each step commits the place the last worked out. Stopped, the part clears its mark on its
    // next visit, the part it hangs from on the one after, and the root on the one after that.
    try std.testing.expectEqual(@as(Vector, .{ 0, 0, 80 }), a.now.pose.offset);
    gameobj.updateTree(&root, &model, fired.events());
    try std.testing.expect(!a.animating and model.parts[0].animation.animating);
    gameobj.updateTree(&root, &model, fired.events());
    try std.testing.expect(!model.parts[0].animation.animating and root.flags.animating);
    gameobj.updateTree(&root, &model, fired.events());
    try std.testing.expect(!root.flags.animating);

    // Round and round: past the end it starts again, and the events on both sides go off.
    fired.count = 0;
    model.play(1, .fire, 80, .loop, 40);
    gameobj.updateTree(&root, &model, fired.events());
    try std.testing.expectEqual(20, a.time);
    try std.testing.expectEqual(2, fired.count);
    try std.testing.expectEqual(@as(Vector, .{ 0, 0, 20 }), a.offset);

    // Back and forth: out over the length and back over the next, with no events.
    fired.count = 0;
    model.play(1, .fire, 60, .swing, 70);
    gameobj.updateTree(&root, &model, fired.events());
    try std.testing.expectEqual(130, a.time);
    try std.testing.expectEqual(@as(Vector, .{ 0, 0, 70 }), a.offset);
    gameobj.updateTree(&root, &model, fired.events());
    gameobj.updateTree(&root, &model, fired.events());
    try std.testing.expectEqual(70, a.time);
    try std.testing.expectEqual(0, fired.count);

    // A hidden part isn't visited, and neither is what hangs from it.
    model.parts[0].hidden = true;
    const was = a.time;
    gameobj.updateTree(&root, &model, fired.events());
    try std.testing.expectEqual(was, a.time);
}

test "Model.frame" {
    const gpa = std.testing.allocator;
    const srmesh = @import("../surrender/surrenderlib/srmesh.zig");
    const mesh = try srmesh.testing.square(gpa);
    defer mesh.deinit(gpa);
    // A dish that turns a little past half a turn about Y each step.
    var keys = [_]shp.Keyframe{ testingKey(0, .{ 0, 0, 0 }, .{ 0, 0, 0 }), testingKey(100, .{ 0, 3, 0 }, .{ 0, 0, 40 }) };
    var tracks = [_]shp.Track{.{ .clip = testingClip(100, .once, "startup"), .keyframes = &keys, .events = &.{} }};
    var animated: Animated = undefined;
    animated.init(&mesh, &tracks);
    var model: Model = try .create(gpa, &animated.source, &animated.loaded, .{});
    defer model.deinit(gpa);
    testingLink(&model);
    var root = std.mem.zeroes(Node);
    const part = &model.parts[1];
    const linked = part.origin;

    create.startUp(&model);
    // The first step works out the next pose but commits nothing yet: the frame stays.
    gameobj.updateTree(&root, &model, null);
    model.frame(0.5);
    try std.testing.expectEqual(linked, part.origin);
    // After the next it is drawn between the two, at the step at the committed place.
    gameobj.updateTree(&root, &model, null);
    model.frame(0);
    try std.testing.expectEqual(part.animation.now.place.position, part.origin);
    model.frame(0.5);
    const halfway = model.placeFor(1, .{ .angles = .{ 0, 0.18, 0 }, .offset = .{ 0, 0, 2.4 } });
    try std.testing.expect(math.length(halfway.position - part.origin) < 1e-4);
    // Poses more than half a turn apart are drawn turning the short way round: from -3 to 3 by
    // way of -pi rather than zero.
    const a = &part.animation;
    a.now.pose.angles = .{ 0, -3, 0 };
    a.next.pose.angles = .{ 0, 3, 0 };
    a.unframed = true;
    model.frame(0.5);
    const offset = (a.next.pose.offset - a.now.pose.offset) * @as(Vector, @splat(0.5)) + a.now.pose.offset;
    const short = model.placeFor(1, .{ .angles = .{ 0, -std.math.pi, 0 }, .offset = offset });
    for (short.orientation, part.turn) |want, got| try std.testing.expectApproxEqAbs(want, got, 1e-5);
}

test "Node.framePlace" {
    var root = std.mem.zeroes(Node);
    root.orientation = math.identity;
    root.next_orientation = math.rotation(.y, 0.4);
    root.next_position = .{ .x = 40, .y = 0, .z = 0 };
    // Until a step commits a place, the frame stays where it was.
    try std.testing.expectEqual(null, root.framePlace(0.5));
    root.flags.next_pending = true;
    root.commitNext();
    root.next_position = .{ .x = 80, .y = 0, .z = 0 };
    root.next_orientation = math.rotation(.y, 0.8);
    // At the step, the committed place; a quarter of the way on, a quarter of the move and turn.
    const at = root.framePlace(0).?;
    try std.testing.expectEqual(@as(Vector, .{ 40, 0, 0 }), at.position);
    const quarter = root.framePlace(0.25).?;
    try std.testing.expectEqual(@as(Vector, .{ 50, 0, 0 }), quarter.position);
    const turned = math.rotation(.y, 0.5);
    for (turned, quarter.orientation) |want, got| try std.testing.expectApproxEqAbs(want, got, 1e-5);
}

test stepFraction {
    var clock: Clock = .{};
    clock.start(0);
    // A frame two ticks into a step, and three quarters of the way through the next tick.
    clock.advanceToFine(275, 100);
    clock.simulation_counter = 2;
    try std.testing.expectEqual(0.5, stepFraction(&clock, false));
    try std.testing.expectEqual(0.6875, stepFraction(&clock, true));
    // Paused, nothing moves, so the time past the tick doesn't count.
    clock.paused = true;
    try std.testing.expectEqual(0.5, stepFraction(&clock, true));
}
