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
const GameObject = @import("gameobj.zig").GameObject;
const srofiles = @import("srofiles.zig");
const srtexture = @import("../surrender/surrenderlib/srtexture.zig");
const matmanager = @import("matmanager.zig");
const create = @import("create.zig");
const environfx = @import("environfx.zig");
const libcmt = @import("../libcmt.zig");
const xtrabits = @import("xtrabits.zig");
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
    _unknown_44: [0x18]u8,
    /// Where `position` goes next: `object_move` puts the position plus the velocity here, and
    /// placing an object sets both. `node_tree_update` (`updateTree`) and `object_link_part` copy
    /// it into `position`, and `node_place` works it out for a part's node.
    next_position: shp.Vec3,
    /// Likewise for `orientation`: `object_move` puts the orientation times the rotation here.
    next_orientation: [9]f32,
    _unknown_8c: [0x18]u8,
    /// The model part the node stands for, as loaded.
    part: Pointer(shp.Part),
    /// The object the node belongs to.
    owner: Pointer(GameObject),
    _unknown_ac: [0x0C]u8,
    /// Which of the part's animation tracks the node runs, and where `node_animate` reads its
    /// keyframes; past the part's tracks, the node is not animated.
    animation: i32,
    _unknown_bc: [8]u8,
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
        /// it visits the node. **Unknown:** what reads it.
        _unknown_1: bool,
        /// Set when `node_tree_update` commits a new place for the node. **Unknown:** what clears
        /// or reads it.
        _unknown_2: bool,
        /// Cleared each time `node_tree_update` visits the node. **Unknown:** what sets or reads
        /// it.
        _unknown_3: bool,
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

    /// The first step of `node_tree_update` for a node: clears flag bits 1 and 3, and if the
    /// node's next place is pending, commits it. The game copies the whole block from
    /// `next_position` to the end of `_unknown_8c` over the block from `position` to the end of
    /// `_unknown_44`, then clears `next_pending` and sets bits 1 and 2.
    pub fn commitNext(node: *Node) void {
        node.flags._unknown_1 = false;
        node.flags._unknown_3 = false;
        if (!node.flags.next_pending) return;
        node.position = node.next_position;
        node.orientation = node.next_orientation;
        node._unknown_44 = node._unknown_8c;
        node.flags.next_pending = false;
        node.flags._unknown_1 = true;
        node.flags._unknown_2 = true;
    }

    comptime {
        assert(@offsetOf(Node, "next_position") - @offsetOf(Node, "position") == 0x48);
        assert(@offsetOf(Node, "part") - @offsetOf(Node, "next_position") == 0x48);
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

/// `node_tree_update` (`0x00476C90`), which `simulation_step` runs for every live object at the
/// start of each step, before the objects move. For the object's root and each descendant that is
/// animating, it commits the node's pending next place (`Node.commitNext`), advances the node's
/// animation and fires its keyframe events. So an object moves from the place the previous step
/// worked out, and until the next step its `position` stays one step behind `next_position`, which
/// is what the rest of the game reads as its place.
///
/// Ported so far: committing the root's next place. Not yet ported: the animation, and the walk
/// over the descendants, which descends into a child only while the child is animating (flag bit
/// 11), is not hidden and doesn't have flag bit 7 set.
pub fn updateTree(root: *Node) void {
    root.commitNext();
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
    /// The object's `hidden` flag: none of its parts is drawn.
    hidden: bool = false,
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
    /// Its farthest vertex from its origin, and its bounding box (`GameObject.radius`,
    /// `bounds_min`, `bounds_max`), as `recentre` leaves them.
    radius: f32 = 0,
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
        /// The part its node hangs from (`object_link_part`), or null for one hanging from the
        /// root. A part names its parent by index, or -1 for none.
        parent: ?usize,
        /// Its origin in the frame of the part it hangs from, or in the model's for one hanging
        /// from the root. A model gives every part its origin in the model whatever its parent, so
        /// hanging one from another takes the parent's origin off it and leaves it where it stood.
        origin: Vector,
        /// The node's frame: a scene object showing the part's meshes. `place` fills it in.
        object: srapiext.MeshObject,
    };

    /// The part `index` hangs from, or null where it hangs from the root: the index a part names,
    /// unless it names none or one no model part answers to.
    fn parentOf(model: *const shp.Model, index: usize) ?usize {
        const named = model.parts[index].part.parent;
        if (named < 0 or named == index) return null;
        const parent: usize = @intCast(named);
        return if (parent < model.parts.len) parent else null;
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
    /// far across as its largest level. A part of a component's damaged model is hidden.
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
            const parent = parentOf(model, index);
            const at = source.part.position;
            const from = if (parent) |p| model.parts[p].part.position else shp.Vec3{ .x = 0, .y = 0, .z = 0 };
            node.* = .{
                .hidden = source.part.flags.damaged,
                .parent = parent,
                .origin = .{ at.x - from.x, at.y - from.y, at.z - from.z },
                .object = .{
                    .flags = part.flags,
                    .position = .{ at.x, at.y, at.z },
                    .radius = radius,
                    .light_mask = lightMask(model.header.flags.components),
                    .levels = part.levels,
                },
            };
        }
        const order = try linkOrder(gpa, model);
        errdefer gpa.free(order);
        const lights = try createLights(gpa, model, effects.light_sprites);
        errdefer gpa.free(lights);
        const glows = try createGlows(gpa, model, effects.glows);
        errdefer gpa.free(glows);
        return .{
            .parts = parts,
            .order = order,
            .lights = lights,
            .glows = glows,
            .mounts = try createMounts(gpa, model, effects, depth),
        };
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
                // A mounted model stands on its own centre of mass, as an object of its own does.
                made.items[made.items.len - 1].model.recentre(mounted.model);
            }
        }
        return made.toOwnedSlice(gpa);
    }

    /// Moves the object's origin to its parts' centre of mass, as `object_link_parts` ends
    /// (`object_recentre`, `0x004769F0`). `node_mass_add` (`0x004764A0`) sums, over the shown
    /// parts, the density times the part's first moment about the root, its origin times its
    /// volume plus its own first moment; over the parts' masses, density times volume, that is the
    /// centre. `object_bounds` (`0x00476680`) takes it off each part's origin, then finds the
    /// object's radius and bounding box over the vertices of each part's current level, hidden ones
    /// too. `source` is the model the parts come from.
    pub fn recentre(model: *Model, source: *const shp.Model) void {
        // Each part's origin in the model, which is where it stands with the root at rest.
        model.place(@splat(0), math.identity);
        var moment: [3]f32 = @splat(0);
        var mass: f32 = 0;
        for (model.parts, source.parts) |part, data| {
            if (part.hidden) continue;
            const p = data.part;
            const origin: [3]f32 = part.object.position;
            for (&moment, origin, p.first_moments) |*m, o, first| m.* = (o * p.volume + first) * p.density + m.*;
            mass = p.density * p.volume + mass;
        }
        if (mass > 0) {
            const scale = 1 / mass;
            for (&moment) |*m| m.* = scale * m.*;
        }
        const centre: Vector = moment;
        model.centre += centre;
        // Only a part standing at the root moves: one hanging from another keeps the origin it has
        // in its parent, and follows it. What stands on a part likewise moves with the part.
        for (model.parts) |*part| {
            if (part.parent == null) part.origin -= centre;
        }

        model.place(@splat(0), math.identity);
        model.radius = 0;
        model.bounds = .{ @splat(std.math.floatMax(f32)), @splat(-std.math.floatMax(f32)) };
        for (model.parts) |part| {
            if (part.object.levels.len == 0) continue;
            for (part.object.levels[part.object.level].mesh.positions) |position| {
                const at = position + part.object.position;
                model.bounds = .{ @min(model.bounds[0], at), @max(model.bounds[1], at) };
                model.radius = @max(model.radius, math.length(at));
            }
        }
    }

    /// Puts the object's root at `position`, turned by `orientation`, and each part's object with
    /// it: a part standing at the root takes the root's turn on its origin, and one hanging from
    /// another stands in that part's frame, so a part carries what hangs from it
    /// (`SR_object_concate_parents`, `0x004C3490`, for each part's frame). A part carries no turn
    /// of its own until the turrets are ported, so each takes the root's.
    pub fn place(model: *Model, position: Vector, orientation: math.Matrix) void {
        model.position = position;
        model.orientation = orientation;
        for (model.order) |index| {
            const part = &model.parts[index];
            const from = if (part.parent) |parent| model.parts[parent].object else null;
            const at = if (from) |carrier| carrier.position else position;
            const turn = if (from) |carrier| carrier.orientation else orientation;
            part.object.position = math.transform(turn, part.origin) + at;
            part.object.orientation = turn;
        }
        for (model.mounts) |*mount| {
            const carrier = model.parts[mount.part].object;
            // The attachment's own turn, on the part that carries it.
            const turn = math.product(carrier.orientation, mount.orientation);
            const at = math.transform(carrier.orientation, mount.origin) + carrier.position;
            // The mounted model stands on its own centre of mass, so its origin goes back by it.
            mount.model.place(math.transform(turn, mount.model.centre) + at, turn);
        }
    }

    /// Adds each shown part's object to `layer`, the world's or, for a cockpit, the overlay
    /// (`node_draw`, `0x0049A8C0`, for the model's part nodes), none while the object is hidden,
    /// then the lights and the engine glows its shown parts carry.
    /// Not yet ported: the cloak, the nodes of kinds 4 and 6, and its leaving out an object too far
    /// away to see.
    pub fn draw(model: *Model, gpa: Allocator, scene: *srcore.Scene, layer: srcore.Layer, view: View) Allocator.Error!void {
        if (model.hidden) return;
        if (view.tooFarOff(model.position, model.radius * model.visibility)) return;
        for (model.parts) |*part| {
            if (part.hidden) continue;
            try xtrabits.sceneAdd(gpa, scene, .{ .mesh = &part.object }, layer);
        }
        for (model.lights) |*light| {
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
        .material = .{
            .two_pass = false,
            ._unknown_01 = 0,
            .coordinates = .{ .mesh, .none },
            .lit = .{ true, false },
            .blend = .{ .add, .off },
            .image = .{ .null, .null },
        },
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

test "Node.commitNext" {
    var node: Node = std.mem.zeroes(Node);
    node.next_position = .{ .x = 1, .y = 2, .z = 3 };
    node.next_orientation = .{ 0, 1, 0, 1, 0, 0, 0, 0, 1 };
    node._unknown_8c[0] = 7;
    node.flags._unknown_3 = true;
    // Nothing pending: only bits 1 and 3 are cleared.
    node.commitNext();
    try std.testing.expectEqual(0, node.position.x);
    try std.testing.expect(!node.flags._unknown_3);
    // Pending: the whole next block is committed, and the flags say so.
    node.flags.next_pending = true;
    node.commitNext();
    try std.testing.expectEqual(node.next_position, node.position);
    try std.testing.expectEqual(node.next_orientation, node.orientation);
    try std.testing.expectEqual(7, node._unknown_44[0]);
    try std.testing.expect(!node.flags.next_pending and node.flags._unknown_1 and node.flags._unknown_2);
    // The next visit clears bit 1 again but leaves bit 2.
    node.commitNext();
    try std.testing.expect(!node.flags._unknown_1 and node.flags._unknown_2);
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
    var data = std.mem.zeroes(shp.PartData);
    data.part.volume = 2;
    data.part.density = 3;
    data.part.first_moments = .{ 0, 0, 20 };
    const source: shp.Model = .{ .header = std.mem.zeroes(shp.Header), .parts = (&data)[0..1], .tail_count = 0, .trailing_bytes = 0 };
    model.recentre(&source);
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

    // Hidden, as from its own cockpit, it adds nothing.
    scene.clear();
    model.hidden = true;
    try model.draw(gpa, &scene, .world, .{});
    try std.testing.expectEqual(0, scene.layers.get(.world).items.len);
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
    var hull = [1]shp.PartData{std.mem.zeroes(shp.PartData)};
    hull[0].part.parent = -1;
    hull[0].attachments = &attachments;
    const model: shp.Model = .{ .header = std.mem.zeroes(shp.Header), .parts = &hull, .tail_count = 0, .trailing_bytes = 0 };

    var flare: srtexture.Image = .{ .levels = &.{} };
    var lamp: srtexture.Image = .{ .levels = &.{} };
    var built: Model = try .create(gpa, &model, &loaded, .{ .light_sprites = .{ .flare = &flare, .lamp = &lamp } });
    defer built.deinit(gpa);

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
        std.mem.zeroes(shp.PartData),
        std.mem.zeroes(shp.PartData),
        std.mem.zeroes(shp.PartData),
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
    var data = [2]shp.PartData{ std.mem.zeroes(shp.PartData), std.mem.zeroes(shp.PartData) };
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
    var gun_data = [1]shp.PartData{std.mem.zeroes(shp.PartData)};
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
        .light_range = 0,
        .light_brightness = 0,
    };
    attachments[1] = attachments[0];
    attachments[1].kind = .missile;
    var hull = [1]shp.PartData{std.mem.zeroes(shp.PartData)};
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
