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
    /// engine glow, which brightens with the throttle, 3 and 5 a light, 3 also setting its colour.
    /// **Unknown:** 4 and 6.
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
        /// Bit 0 is set on a node whose next place has yet to be taken up: `object_move` sets it
        /// on an object's root, and `object_link_part` clears all four after copying a part's next
        /// place into its own and its frame's. **Unknown:** the other three, and which routine
        /// takes up a root's next place.
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
    lights: []Light,
    glows: []Glow,
    /// Where the model's origin lies from the object's, less (`GameObject + 0x524`): the centres
    /// of mass `recentre` moved the origin to.
    centre: Vector = @splat(0),
    /// Its farthest vertex from its origin, and its bounding box (`GameObject.radius`,
    /// `bounds_min`, `bounds_max`), as `recentre` leaves them.
    radius: f32 = 0,
    bounds: [2]Vector = .{ @splat(0), @splat(0) },

    /// A light a model carries, which `node_draw` draws for node kinds 3 and 5: an attachment of
    /// kind `light`, drawn as one sprite coloured by the attachment's id and blinking by its own
    /// timing. Every light draws the same sprite, the one attachment kind 4 id 0 names.
    ///
    /// Not ported: the light it also casts on what stands near it, which takes a paler colour than
    /// its sprite.
    pub const Light = struct {
        /// The part that carries it, whose node `node_draw` walks to reach it.
        part: usize,
        /// Its place in the model, from the root.
        origin: Vector,
        /// Its sprite's colour, which the attachment's id picks.
        colour: [3]f32,
        /// How far its sprite reaches either side of its centre, before the distance it is seen
        /// from scales it.
        size: f32,
        /// Ticks on, then off. A light with neither never blinks.
        blink: [2]i32,
        /// Where in its blink it starts, so that lights side by side need not blink together.
        phase: i32,
        set: srapiext.SpriteSet,
        sprite: [1]srapiext.Sprite,
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
        /// Its place in the model, from the root.
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
    pub fn create(gpa: Allocator, model: *const shp.Model, loaded: *const srofiles.Loaded, effects: Effects) Allocator.Error!Model {
        const parts = try gpa.alloc(Part, model.parts.len);
        errdefer gpa.free(parts);
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
        const lights = try createLights(gpa, model, effects.light_sprite);
        errdefer gpa.free(lights);
        return .{ .parts = parts, .lights = lights, .glows = try createGlows(gpa, model, effects.glows) };
    }

    /// One light for each attachment of kind `light` a part carries, at its place in the model.
    fn createLights(gpa: Allocator, model: *const shp.Model, image: ?*srtexture.Image) Allocator.Error![]Light {
        var count: usize = 0;
        for (model.parts) |part| {
            for (part.attachments) |attachment| {
                if (attachment.kind == .light) count += 1;
            }
        }
        const lights = try gpa.alloc(Light, count);
        var made: usize = 0;
        for (model.parts, 0..) |part, index| {
            const origin = part.part.position;
            for (part.attachments) |attachment| {
                if (attachment.kind != .light) continue;
                const light = &lights[made];
                made += 1;
                light.* = .{
                    .part = index,
                    .origin = .{
                        attachment.position.x + origin.x,
                        attachment.position.y + origin.y,
                        attachment.position.z + origin.z,
                    },
                    .colour = lightColour(attachment.id),
                    .size = attachment.size[1],
                    .blink = attachment.blink,
                    .phase = attachment.blink_phase,
                    .sprite = .{.{}},
                    .set = .{ .flags = .{ ._unknown_6 = 1 }, .sprites = &.{} },
                };
                if (image) |texture| light.set.surface = lightSurface(texture);
                // The set's sprite stands in the light itself, which does not move again.
                light.set.sprites = light.sprite[0..1];
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
            const origin = part.part.position;
            for (part.attachments) |attachment| {
                if (attachment.kind != .engine_glow) continue;
                const glow = &made[at];
                at += 1;
                const size: Vector = attachment.size;
                glow.* = .{
                    .part = index,
                    .origin = .{
                        attachment.position.x + origin.x,
                        attachment.position.y + origin.y,
                        attachment.position.z + origin.z,
                    },
                    .orientation = attachment.orientation,
                    .size = size,
                    // Its plume burns the way the attachment's Z axis points, so a plume that
                    // reaches forward pushes the ship back.
                    .retro = size[2] * attachment.orientation[8] > 0,
                    .steady = attachment.id == steady_glow,
                    .level = .{.{ .mesh = built.mesh(attachment.id), .until = std.math.inf(f32) }},
                    .object = .{
                        // Neither culled nor given a level of detail by how far off it is.
                        .flags = .{ .not_culled = true, ._unknown_12 = true },
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
        gpa.free(model.parts);
        gpa.free(model.lights);
        gpa.free(model.glows);
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
        // A light and a glow stand on the part that carries them, so they move with the parts.
        for (model.lights) |*light| light.origin -= centre;
        for (model.glows) |*glow| glow.origin -= centre;

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
    pub fn draw(model: *Model, gpa: Allocator, scene: *srcore.Scene, layer: srcore.Layer, view: View) Allocator.Error!void {
        if (model.hidden) return;
        for (model.parts) |*part| {
            if (part.hidden) continue;
            try xtrabits.sceneAdd(gpa, scene, .{ .mesh = &part.object }, layer);
        }
        for (model.lights) |*light| {
            // A light goes dark with the part that carries it, as a damaged part's does while the
            // part it belongs to is whole.
            if (model.parts[light.part].hidden) continue;
            const world = math.transform(model.orientation, light.origin) + model.position;
            const away = math.length(world - view.camera);
            const shown = blinkBrightness(light.*, view.frame_start) * distanceBrightness(away);
            if (!(shown > 0)) continue;
            light.set.position = world;
            light.sprite[0].half_size = @splat(light.size * distanceSize(away) * sprite_scale);
            for (&light.sprite[0].colour, light.colour) |*channel, c| {
                channel.* = @min(shown, 1) * c * sprite_share;
            }
            try xtrabits.sceneAdd(gpa, scene, .{ .sprites = &light.set }, layer);
        }
        for (model.glows) |*glow| {
            // A glow goes out with the part that carries it, as a light does.
            if (model.parts[glow.part].hidden) continue;
            const burning = glow.plume(view.throttle, view.random) orelse continue;
            glow.object.position = math.transform(model.orientation, glow.origin) + model.position;
            // The plume stands as its attachment does, drawn to the size it gives it.
            const scale: math.Matrix = .{ glow.size[0], 0, 0, 0, glow.size[1], 0, 0, 0, burning * glow.size[2] };
            glow.object.orientation = math.product(math.product(model.orientation, glow.orientation), scale);
            try xtrabits.sceneAdd(gpa, scene, .{ .mesh = &glow.object }, layer);
        }
    }
};

/// What a model draws its attachments with: the sprite every light draws, and the meshes the engine
/// glows draw. A model carries only the ones it is given.
pub const Effects = struct {
    light_sprite: ?*srtexture.Image = null,
    glows: ?*const environfx.Glows = null,
};

/// What a model's lights are drawn by: where the camera stands, since a light's size and brightness
/// follow how far off it is, and the frame's tick, which says where each light stands in its blink.
pub const View = struct {
    camera: Vector = @splat(0),
    /// `frame_start`, the mission tick the frame began on.
    frame_start: i32 = 0,
    /// How hard the object is burning, between -1 and 1, which is how far its engine glows reach.
    /// `object_draw` is given the throttle of its last update, dimmed by the share of its engines
    /// still standing.
    throttle: f32 = 0,
    /// Where the glows' flicker comes from; without one they burn steady.
    random: ?*libcmt.Rand = null,
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

/// The sprite every light draws, whatever its colour: the one attachment kind 4 id 0 names.
pub fn lightSprite(textures: *srtexture.Table) matmanager.Error!?*srtexture.Image {
    const entry = create.models.attachment(.light, 0) orelse return null;
    const name = entry.sprite orelse return null;
    return try matmanager.textureRequire(textures, name);
}

/// The colour of a light of each attachment id (`node_draw`). Past the sixth it takes none.
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
fn lightSurface(image: *srtexture.Image) srapiext.Surface {
    return .{
        .material = .{
            .two_pass = false,
            ._unknown_01 = 0,
            .coordinates = .{ .mesh, .none },
            .lit = .{ true, false },
            .blend = .{ .add, .off },
            .image = .{ .null, .null },
        },
        .textures = .{ .{ .image = image }, .none },
    };
}

/// How far a light's sprite reaches at its largest, over the size the attachment gives it.
const sprite_scale: f32 = 7;

/// The share of its colour a light's sprite takes.
const sprite_share: f32 = 0.5;

/// A light fades over these ticks at each end of its blink.
const blink_fade: f32 = 200;

/// Where a light stands in its blink at `frame_start`: 1 while it is full on, falling away over
/// `blink_fade` ticks at each end, and nothing while it is off. A light with no blink is always on.
fn blinkBrightness(light: Model.Light, frame_start: i32) f32 {
    const period = light.blink[0] +% light.blink[1];
    if (period == 0) return 1;
    const at = @mod((frame_start *% 10) -% light.phase, period);
    if (light.blink[0] < at) return @as(f32, @floatFromInt(light.blink[0] - at + 200)) / blink_fade;
    if (period < at) return @as(f32, @floatFromInt(at - period + 200)) / blink_fade;
    return 1;
}

/// A light is full at a thousand units off, a tenth of that beyond fifteen thousand, and between
/// the two it fades from one to the other.
fn distanceBrightness(away: f32) f32 {
    const near = 1000;
    const far = 15000;
    const faded = 0.1;
    if (away <= near) return 1;
    if (away >= far) return faded;
    return 1 + (faded - 1) * (away - near) / (far - near);
}

/// A light's sprite grows with how far off it is, up to six thousand units, so that it stays worth
/// seeing at a distance.
fn distanceSize(away: f32) f32 {
    const full = 6000;
    return if (away >= full) 1 else away / full;
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
        .origin = .{ 0, 0, 100 },
        .object = .{ .flags = .{}, .position = @splat(0), .radius = mesh.radius, .levels = &levels },
    }};
    // A light standing on that part, at the same place in the model.
    var lights = [_]Model.Light{.{
        .part = 0,
        .origin = .{ 0, 0, 100 },
        .colour = .{ 1, 0, 0 },
        .size = 10,
        .blink = .{ 0, 0 },
        .phase = 0,
        .set = .{ .sprites = &.{} },
        .sprite = .{.{}},
    }};
    lights[0].set.sprites = lights[0].sprite[0..1];
    var model: Model = .{ .parts = &parts, .lights = &lights, .glows = &.{} };
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
    // A light moves with the parts, so it stays where it stood on the hull.
    try std.testing.expectEqual(parts[0].origin, lights[0].origin);
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

test blinkBrightness {
    var light: Model.Light = .{
        .part = 0,
        .origin = @splat(0),
        .colour = .{ 1, 1, 1 },
        .size = 100,
        .blink = .{ 0, 0 },
        .phase = 0,
        .set = .{ .sprites = &.{} },
        .sprite = .{.{}},
    };
    // A light that does not blink is always full on.
    try std.testing.expectEqual(1, blinkBrightness(light, 0));
    try std.testing.expectEqual(1, blinkBrightness(light, 12_345));

    // On for 1000 ticks of its clock, then off for 1000; the clock runs ten to the tick.
    light.blink = .{ 1000, 1000 };
    try std.testing.expectEqual(1, blinkBrightness(light, 0));
    try std.testing.expectEqual(1, blinkBrightness(light, 100)); // at 1000, still on
    // Just past the on time it fades, and by 200 of its clock it is out.
    try std.testing.expectApproxEqAbs(0.5, blinkBrightness(light, 110), 1e-6);
    try std.testing.expect(blinkBrightness(light, 120) <= 0);
    // Its phase shifts where it stands: the same light started later is still on.
    light.phase = 1000;
    try std.testing.expectEqual(1, blinkBrightness(light, 110));
}

test distanceBrightness {
    // Full within a thousand units, a tenth past fifteen thousand, and between the two it fades.
    try std.testing.expectEqual(1, distanceBrightness(0));
    try std.testing.expectEqual(1, distanceBrightness(1000));
    try std.testing.expectApproxEqAbs(0.55, distanceBrightness(8000), 1e-6);
    try std.testing.expectApproxEqAbs(0.1, distanceBrightness(15000), 1e-6);
    try std.testing.expectApproxEqAbs(0.1, distanceBrightness(100_000), 1e-6);
}

test distanceSize {
    // A light's sprite grows with distance up to six thousand units, then stays.
    try std.testing.expectEqual(0, distanceSize(0));
    try std.testing.expectApproxEqAbs(0.5, distanceSize(3000), 1e-6);
    try std.testing.expectEqual(1, distanceSize(6000));
    try std.testing.expectEqual(1, distanceSize(60_000));
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
    var model: Model = .{ .parts = &parts, .lights = &.{}, .glows = &glows };
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
