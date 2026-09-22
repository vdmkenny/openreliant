//! `C:\lancer\game\collision.cpp`: what becomes of two objects that meet. `objects_update` finds
//! the pairs whose spheres overlap ([`create.zig`](create.zig)) and hands each to `objects_collide`,
//! which pushes them apart. `docs/engine/loop.md` describes the sweep.
//!
//! **Unverified:** this file's known code lies before `objects_collide`; what is ported here lies
//! between it and `Create.cpp`'s, which no string places.

const std = @import("std");

const math = @import("../surrender/math.zig");
const Vector = math.Vector;
const create = @import("create.zig");
const gameobj = @import("gameobj.zig");
const motion = @import("motion.zig");
const objects = @import("objects.zig");

/// How far apart a collision sets two objects, as a share of each one's radius from the point
/// between them (`0x004DC7C0` and `0x004DC7C4`): a tenth further than touching, so that the next
/// step does not find them overlapping again.
pub const push_apart: f32 = 1.1;

/// The satellite, two of which never collide whatever their class.
const satellite_type: u32 = 0x71;

/// The limpet pod, which rides on a hull and so is never tested against its parts.
const limpet_pod_type: u32 = 0xBC;

comptime {
    // The numbers are the game's own, so the models they stand for say which types they are.
    const types = create.models.ship_types;
    std.debug.assert(std.mem.eql(u8, types[satellite_type].model.?, "stork_sat.shp"));
    std.debug.assert(std.mem.eql(u8, types[limpet_pod_type].model.?, "limpet_pod.shp"));
}

/// `objects_collide` (`0x00466170`): what two objects whose spheres overlap do about it, and
/// whether they were moved, which has `objects_update` look again.
///
/// Two of one type never collide while a torpedo is one of them, nor do two torpedoes, two pieces
/// of debris or two of `satellite_type`. A torpedo or a mine goes off instead of being pushed
/// (`explode.cpp`), and a ship that meets something which lists components is tested against its
/// parts. Anything else is pushed apart along the line between the two, each to `push_apart` of its
/// radius from the point between them, after both have moved again.
///
/// Not ported: the damage the impact does, through the shields and the armour
/// ([#42](https://github.com/vdmkenny/openreliant/issues/42)), the torpedo's and the mine's
/// explosions ([#41](https://github.com/vdmkenny/openreliant/issues/41)), and the test against the
/// parts of a ship that lists components
/// ([#143](https://github.com/vdmkenny/openreliant/issues/143)), which leaves those pairs passing
/// through each other for now.
pub fn collide(world: gameobj.World, first: u16, second: u16) bool {
    const all = world.objects;
    var near = first;
    var far = second;
    const near_class = className(all, near) orelse return false;
    const far_class = className(all, far) orelse return false;
    var classes: [2]create.ShipCombat.Class = .{ near_class, far_class };

    // A torpedo comes first, and never meets another object of its own type or one that is already
    // going off.
    if (classes[0] == .torpedo or classes[1] == .torpedo) {
        if (all.slots[near].object.type == all.slots[far].object.type) return false;
        if (classes[1] == .torpedo) {
            std.mem.swap(u16, &near, &far);
            std.mem.swap(create.ShipCombat.Class, &classes[0], &classes[1]);
        }
        if (all.slots[near].object.flags.exploding) return false;
    }

    const lists_components = all.slots[near].object.flags.components or all.slots[far].object.flags.components;
    if (lists_components) return parts(world, near, far);

    // Two torpedoes and two pieces of debris pass through each other, as do two of `satellite_type`.
    if (classes[0] == classes[1] and (classes[0] == .torpedo or classes[0] == .debris)) return false;
    if (all.slots[near].object.type == satellite_type and all.slots[far].object.type == satellite_type) return false;

    // A mine goes off against a fighter, and a torpedo against whatever it met.
    if (classes[0] == .mine or classes[1] == .mine) return false;
    if (classes[0] == .torpedo) return true;

    return push(world, near, far);
}

/// The class of the ship type in a slot, or null for an object with no stats, which the game would
/// follow a null pointer for.
fn className(all: *const create.Objects, index: u16) ?create.ShipCombat.Class {
    const combat = all.slots[index].combat orelse return null;
    return combat.class;
}

/// Both objects move again, and are then set apart along the line between them where they still
/// overlap. The game does the impact's damage first, which may knock them about, so they are moved
/// again before the two are placed.
fn push(world: gameobj.World, first: u16, second: u16) bool {
    const all = world.objects;
    for ([_]u16{ first, second }) |index| {
        const slot = &all.slots[index];
        const flight = slot.flight orelse continue;
        motion.move(&slot.object, flight, world.view, slot.motion, if (index == all.player) world.shake else null);
    }
    const near = &all.slots[first];
    const far = &all.slots[second];
    const here = gameobj.vector(near.object.root.next_position);
    const there = gameobj.vector(far.object.root.next_position);
    const reach = near.object.radius + far.object.radius;
    if (math.lengthSquared(here - there) >= reach * reach) return true;

    const apart = math.normalize(here - there);
    const between = (here + there) * @as(Vector, @splat(0.5));
    objects.setPosition(&near.object, &near.drawn, between + apart * @as(Vector, @splat(near.object.radius * push_apart)));
    objects.setPosition(&far.object, &far.drawn, between - apart * @as(Vector, @splat(far.object.radius * push_apart)));
    return true;
}

/// `0x00465C50`: a ship that meets an object listing components is tested against its parts rather
/// than its sphere, up to nine times over as the two are moved apart. Two objects that both list
/// components pass through each other, as does anything meeting `limpet_pod_type`.
///
/// The test itself (`0x00465380`) walks the parts' collision hulls, which the port does not read
/// yet ([#143](https://github.com/vdmkenny/openreliant/issues/143)), so nothing comes of the pair.
fn parts(world: gameobj.World, first: u16, second: u16) bool {
    const all = world.objects;
    if (all.slots[first].object.flags.components and all.slots[second].object.flags.components) return false;
    if (all.slots[first].object.type == limpet_pod_type or all.slots[second].object.type == limpet_pod_type) return false;
    return false;
}

const testing = struct {
    const libcmt = @import("../libcmt.zig");
    const input = @import("../input.zig");

    /// A world of objects with no models, at rest.
    fn world(all: *create.Objects, player: *input.Player, shake: *f32) gameobj.World {
        return .{ .objects = all, .player = player, .view = .chase, .shake = shake };
    }

    /// An object of `ship_type` at `at`, with a radius of its own and nothing flying it.
    fn ship(all: *create.Objects, tables: *create.Stats, random: *libcmt.Rand, at: Vector, radius: f32) !u16 {
        const index = try create.createObject(all, tables, create.testing.no_models, null, 0, at, random);
        all.slots[index].object.radius = radius;
        all.slots[index].motion = null;
        return index;
    }
};

test collide {
    const libcmt = @import("../libcmt.zig");
    const input = @import("../input.zig");
    var random: libcmt.Rand = .{};
    const all = try create.Objects.create(std.testing.allocator, &random);
    defer all.destroy();
    var tables = create.testing.tables();
    var player: input.Player = .{};
    var shake: f32 = 0;
    const world = testing.world(all, &player, &shake);

    // Two ships of 1000 units, 400 apart: each ends 1100 from the point between them.
    const near = try testing.ship(all, &tables, &random, .{ -200, 0, 0 }, 1000);
    const far = try testing.ship(all, &tables, &random, .{ 200, 0, 0 }, 1000);
    try std.testing.expect(collide(world, near, far));
    try std.testing.expectApproxEqAbs(-1100, all.slots[near].object.root.position.x, 0.01);
    try std.testing.expectApproxEqAbs(1100, all.slots[far].object.root.position.x, 0.01);
    // What is drawn moves with them.
    try std.testing.expectApproxEqAbs(-1100, all.slots[near].drawn.position[0], 0.01);

    // Once they are clear of each other, nothing moves them.
    const held = all.slots[near].object.root.position.x;
    try std.testing.expect(collide(world, near, far));
    try std.testing.expectEqual(held, all.slots[near].object.root.position.x);
}

test "what never collides" {
    const libcmt = @import("../libcmt.zig");
    const input = @import("../input.zig");
    var random: libcmt.Rand = .{};
    const all = try create.Objects.create(std.testing.allocator, &random);
    defer all.destroy();
    var tables = create.testing.tables();
    var player: input.Player = .{};
    var shake: f32 = 0;
    const world = testing.world(all, &player, &shake);

    // The test's stats make every type a fighter; two pieces of debris pass through each other.
    const near = try testing.ship(all, &tables, &random, @splat(0), 1000);
    const far = try testing.ship(all, &tables, &random, .{ 100, 0, 0 }, 1000);
    tables.combat[0].class = .debris;
    try std.testing.expect(!collide(world, near, far));

    // So do a torpedo and another object of its own type.
    tables.combat[0].class = .torpedo;
    try std.testing.expect(!collide(world, near, far));

    // A torpedo of another type goes off against it instead of pushing it.
    tables.combat[1].class = .fighter;
    all.slots[far].object.type = 1;
    all.slots[far].combat = &tables.combat[1];
    try std.testing.expect(collide(world, near, far));
    try std.testing.expectEqual(0, all.slots[near].object.root.position.x);

    // An object that lists components is met by its parts, which aren't ported, so nothing comes
    // of it.
    tables.combat[0].class = .fighter;
    all.slots[far].object.flags.components = true;
    try std.testing.expect(!collide(world, near, far));
    try std.testing.expectEqual(0, all.slots[near].object.root.position.x);
}
