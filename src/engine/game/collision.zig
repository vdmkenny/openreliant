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
const main = @import("main.zig");
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
pub fn collide(world: gameobj.World, first: u16, second: u16, pass: u8) bool {
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
    if (lists_components) return parts(world, near, far, pass);

    // Two torpedoes and two pieces of debris pass through each other, as do two of `satellite_type`.
    if (classes[0] == classes[1] and (classes[0] == .torpedo or classes[0] == .debris)) return false;
    if (all.slots[near].object.type == satellite_type and all.slots[far].object.type == satellite_type) return false;

    // A mine goes off against a fighter, and a torpedo against whatever it met.
    if (classes[0] == .mine or classes[1] == .mine) return false;
    if (classes[0] == .torpedo) return true;

    return push(world, near, far, pass);
}

/// The class of the ship type in a slot, or null for an object with no stats, which the game would
/// follow a null pointer for.
fn className(all: *const create.Objects, index: u16) ?create.ShipCombat.Class {
    const combat = all.slots[index].combat orelse return null;
    return combat.class;
}

/// How hard the two come off each other (`0x004DC4A4`): the impulse carries twice the speed they
/// meet at, so the bounce keeps it.
const bounce: f32 = -2;

/// The speed a pair whose contact points are not closing is pushed apart at, for each pass the
/// sweep has already made (`0x004DC56C`), so a pair that keeps meeting is parted harder each time.
const resting_speed: f32 = 5;

/// `0x00464E80`: the shove two objects give each other where their spheres touch. The contact
/// point lies on the line between their centres, so neither is turned by it.
fn shove(world: gameobj.World, first: u16, second: u16, pass: u8) void {
    const all = world.objects;
    const here = gameobj.vector(all.slots[first].object.root.position);
    const there = gameobj.vector(all.slots[second].object.root.position);
    const apart = here - there;
    if (math.lengthSquared(apart) == 0) return;
    const toward = math.normalize(apart);
    const contact = there + toward * @as(Vector, @splat(all.slots[second].object.radius));
    const impulse = shoveAt(world, first, second, -toward, .{
        math.transformTransposed(all.slots[first].object.root.orientation, contact - here),
        math.transformTransposed(all.slots[second].object.root.orientation, contact - there),
    }, pass) orelse return;
    impact(world, first, second, impulse, contact);
}

/// `0x00464E80` itself: the impulse where two objects meet. `normal` points from the first to the
/// second, and `levers` gives the contact point in each object's own frame. The impulse follows
/// how fast those points close between this step and the next, each object's mass and its
/// `angular_response`, and both take it through `knock`, equal and opposite. An object held to
/// another, and the Ripper carrying something, take none.
///
/// The move that follows applies the knocks, which is why a colliding pair moves again.
fn shoveAt(world: gameobj.World, first: u16, second: u16, normal: Vector, levers: [2]Vector, pass: u8) ?Vector {
    const all = world.objects;
    const near = &all.slots[first].object;
    const far = &all.slots[second].object;

    // Where each contact point stands now and where the step is taking it.
    const now: [2]Vector = .{
        math.transform(near.root.orientation, levers[0]) + gameobj.vector(near.root.position),
        math.transform(far.root.orientation, levers[1]) + gameobj.vector(far.root.position),
    };
    const next: [2]Vector = .{
        math.transform(near.root.next_orientation, levers[0]) + gameobj.vector(near.root.next_position),
        math.transform(far.root.next_orientation, levers[1]) + gameobj.vector(far.root.next_position),
    };
    var closing = (next[0] - now[0]) - (next[1] - now[1]);
    if (math.lengthSquared(closing) == 0 and far.flags.components) {
        closing = normal * @as(Vector, @splat(near.radius - math.distance(now[0], next[0])));
    }
    const speed = math.length(closing);
    if (math.dot(closing, normal) < 0 and speed > 0) {
        closing *= @as(Vector, @splat(-(1 + @as(f32, @floatFromInt(pass))) * resting_speed / speed));
    }

    var give: f32 = 0;
    for ([_]u16{ first, second }, now) |index, at| {
        if (!shoved(all, index)) continue;
        const object = &all.slots[index].object;
        const lever = at - gameobj.vector(object.root.position);
        const turn = math.transform(
            object.root.orientation,
            math.transform(object.angular_response, math.transformTransposed(object.root.orientation, math.cross(lever, normal))),
        );
        give += 1 / object.mass + math.dot(math.cross(turn, lever), normal);
    }
    // A tensor or a mass the arithmetic cannot hold would throw the pair across the sky.
    if (!(give > 0) or !std.math.isFinite(give)) return null;
    var force = normal * @as(Vector, @splat(math.dot(closing, normal) * bounce / give));
    if (@reduce(.And, force == @as(Vector, @splat(0)))) force = normal;
    if (!@reduce(.And, @abs(force) < @as(Vector, @splat(std.math.floatMax(f32))))) return null;
    for ([_]u16{ first, second }, now, 0..) |index, at, which| {
        if (!shoved(all, index)) continue;
        gameobj.knock(&all.slots[index].object, if (which == 0) force else -force, at);
    }
    return force;
}

/// Whether the object takes a shove at all: one held to another does not, nor does the Ripper while
/// it is carrying something.
///
/// **Improvement:** neither does an object of no mass, which the game would divide by, since a
/// model whose parts hold no volume leaves one.
fn shoved(all: *const create.Objects, index: u16) bool {
    const slot = &all.slots[index];
    if (slot.object.flags.attached or slot.object.mass <= 0) return false;
    if (slot.object.type != ripper_type) return true;
    return slot.object.order_count == 0 or slot.orders[0].order != .ripper_grabs_target_object;
}

/// The Ripper, which is not shoved while it is carrying something.
const ripper_type: u32 = 0x1F;

/// Both objects shove each other, move again, and are then set apart along the line between them
/// where they still overlap. The move applies the knocks the shove handed them, which is why it
/// runs again here.
fn push(world: gameobj.World, first: u16, second: u16, pass: u8) bool {
    const all = world.objects;
    shove(world, first, second, pass);
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

/// What the collision damage counts as (`0x00463EE0`'s last argument). **Unknown:** what 0, 1 and
/// 5 stand for, beyond counting toward `recent_damage`, which 2 does not.
pub const Kind = enum(u8) {
    collision = 2,
    _,
};

/// The quadrants an object's shields and armour are kept in, as `object_armor_conditions` reads
/// them.
pub const Quadrant = enum(u2) {
    left = 0,
    right = 1,
    fore = 2,
    aft = 3,
};

/// `0x00463CA0`: the quadrant a hit falls in, from where it lies in the object's frame as a share
/// of the object's bounds: whichever of along and across is the larger share decides.
pub fn quadrant(object: *const gameobj.GameObject, at: Vector) Quadrant {
    const across = at[0] / (object.bounds_max.x - object.bounds_min.x);
    const along = at[2] / (object.bounds_max.z - object.bounds_min.z);
    if (@abs(across) <= @abs(along)) return if (along <= 0) .aft else .fore;
    return if (across > 0) .right else .left;
}

/// How much of a collision's impulse becomes damage (`0x004DC3F8` and `0x004DC408`), over the
/// lighter of the two masses.
const damage_share: f32 = 0.2 * 0.5;

/// What the damage is scaled by while either object is held to another (`0x004DC4AC`).
const attached_damage: f32 = 0.02;

/// What a player's ship does to a friendly one (`0x004DC3D4`).
const friendly_damage: f32 = 0.25;

/// `0x00465CA0`: the damage two objects do each other as they meet. It follows the impulse the
/// shove handed them, over the lighter of the two masses, and lands on the quadrant each was struck
/// in: the shields take it first, and what passes through wears the armour.
fn impact(world: gameobj.World, first: u16, second: u16, impulse: Vector, contact: Vector) void {
    const all = world.objects;
    const near = &all.slots[first].object;
    const far = &all.slots[second].object;
    var value = math.length(impulse) * damage_share / @min(near.mass, far.mass);
    if (near.flags.attached or far.flags.attached) value *= attached_damage;

    for ([_]u16{ first, second }, [_]u16{ second, first }) |index, other| {
        const object = &all.slots[index].object;
        const struck = quadrant(object, math.transformTransposed(object.root.orientation, contact - gameobj.vector(object.root.position)));
        var share = value;
        // A player's ship is gentler with its own side.
        if (other == all.player and object.side == .friendly and index >= all.players) share *= friendly_damage;
        damage(world, index, struck, share, 1, other, .collision);
    }
}

/// `0x00463EE0`: damage to an object, which its shields take first. What passes through wears the
/// armour instead, times `factor`, which every caller here gives as 1. A shield that is already
/// down adds its own deficit to what passes through. Damage of kinds 0, 1 and 5 counts toward what the object has
/// taken lately, which is what sends a ship after its attacker.
///
/// Not ported: the scaling the difficulty setting gives a hit (`0x00463D70`), the head-up display's
/// answer to one, the score a player's hit is worth, and what multiplayer makes of it.
pub fn damage(world: gameobj.World, index: u16, struck: Quadrant, value: f32, factor: f32, attacker: u16, kind: Kind) void {
    const all = world.objects;
    const slot = &all.slots[index];
    const object = &slot.object;
    if (object.flags.jumping) return;
    if (slot.combat) |combat| if (combat.class == .debris) return;

    const shield = &object.shields[@intFromEnum(struck)];
    const through = @max(value - shield.*, 0);
    if (counted(kind)) object.recent_damage += value;
    if (shield.* >= 0) shield.* -= value;
    if (shield.* < 0) armorDamage(world, index, struck, through * factor, attacker, kind);
    object.last_attacker = attacker;
}

/// `0x004641F0`: damage to an object's armour, once its shields are down. The armour's conditions
/// follow it (`object_armor_conditions`), and armour below zero destroys the object.
///
/// Not ported: the destruction itself (`object_destroyed`,
/// [#41](https://github.com/vdmkenny/openreliant/issues/41)), the damage a component takes in place
/// of the hull ([#40](https://github.com/vdmkenny/openreliant/issues/40)), and what an invulnerable
/// object shrugs off.
pub fn armorDamage(world: gameobj.World, index: u16, struck: Quadrant, value: f32, attacker: u16, kind: Kind) void {
    const all = world.objects;
    const slot = &all.slots[index];
    const object = &slot.object;
    if (object.flags.jumping or object.flags.exploding) return;
    if (slot.combat) |combat| if (combat.class == .debris) return;
    if (counted(kind)) object.recent_damage += value;
    if (object.invulnerable != 0) return;

    object.armor[@intFromEnum(struck)] -= value;
    if (slot.combat) |combat| main.armorConditions(object, combat);
    object.last_attacker = attacker;
}

/// Whether the damage counts toward what an object has taken lately, which `order_retaliate` reads.
fn counted(kind: Kind) bool {
    return switch (@intFromEnum(kind)) {
        0, 1, 5 => true,
        else => false,
    };
}

/// `0x00465C50`: a ship that meets an object listing components is tested against that object's
/// parts, not its sphere. The two are moved apart and tested again, up to nine times. Two objects
/// that both list components pass through each other, as does anything meeting `limpet_pod_type`.
fn parts(world: gameobj.World, first: u16, second: u16, pass: u8) bool {
    const all = world.objects;
    if (all.slots[first].object.flags.components and all.slots[second].object.flags.components) return false;
    if (all.slots[first].object.type == limpet_pod_type or all.slots[second].object.type == limpet_pod_type) return false;
    const hull = if (all.slots[first].object.flags.components) first else second;
    const ship = if (hull == first) second else first;

    var tries: u8 = 0;
    while (tries < hull_passes) : (tries += 1) {
        if (!hullHit(world, ship, hull, pass)) break;
        for ([_]u16{ ship, hull }) |index| {
            const slot = &all.slots[index];
            const flight = slot.flight orelse continue;
            motion.move(&slot.object, flight, world.view, slot.motion, if (index == all.player) world.shake else null);
        }
    }
    return tries > 0 and tries < hull_passes;
}

/// How many times a pair is tested against a hull before the sweep gives up on it.
const hull_passes = 9;

/// `0x00465380`, as far as the shove goes: the nearest face of the hull to the ship's sphere. The
/// ship is shoved at its own centre and the hull at the face, so the hull turns about the hit and
/// the ship does not.
///
/// Not ported: the damage the hit does, and what it destroys
/// ([#42](https://github.com/vdmkenny/openreliant/issues/42)). The game also tests the player's
/// ship against each part's trigger polygons first, which one shipped model carries.
fn hullHit(world: gameobj.World, ship: u16, hull: u16, pass: u8) bool {
    const all = world.objects;
    const model = if (all.slots[hull].model) |*live| live else return false;
    const source = if (all.slots[hull].type) |kind| kind.model else return false;
    const object = &all.slots[hull].object;

    // The hull stands where this step is taking it, as the ship's sphere does.
    model.place(gameobj.vector(object.root.next_position), object.root.next_orientation);
    const at = gameobj.vector(all.slots[ship].object.root.next_position);
    const found = objects.hitSphere(model, source, at, all.slots[ship].object.radius) orelse return false;

    const part = model.parts[found.part].object;
    const contact = math.transform(part.orientation, found.point) + part.position;
    const normal = math.transform(part.orientation, found.normal);
    // The ship takes the shove at its own centre, the hull at the face it was hit on. The game
    // works the hull's lever out in the part's frame; the port uses the object's, which differs
    // only for a part its model animates.
    const lever = math.transformTransposed(object.root.orientation, contact - gameobj.vector(object.root.position));
    const impulse = shoveAt(world, ship, hull, -normal, .{ @splat(0), lever }, pass) orelse return true;

    // The ship takes the damage on the quadrant it was struck in. What the hull's own part takes
    // waits on the components (#40).
    const hit = &all.slots[ship].object;
    const value = math.length(impulse) * damage_share / hit.mass;
    const struck = quadrant(hit, math.transformTransposed(hit.root.orientation, contact - gameobj.vector(hit.root.position)));
    damage(world, ship, struck, value, 1, hull, .collision);
    return true;
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
    try std.testing.expect(collide(world, near, far, 0));
    try std.testing.expectApproxEqAbs(-1100, all.slots[near].object.root.position.x, 0.01);
    try std.testing.expectApproxEqAbs(1100, all.slots[far].object.root.position.x, 0.01);
    // What is drawn moves with them.
    try std.testing.expectApproxEqAbs(-1100, all.slots[near].drawn.position[0], 0.01);

    // Once they are clear of each other, nothing moves them.
    const held = all.slots[near].object.root.position.x;
    try std.testing.expect(collide(world, near, far, 0));
    try std.testing.expectEqual(held, all.slots[near].object.root.position.x);
}

test "a collision shoves both ships" {
    const libcmt = @import("../libcmt.zig");
    const input = @import("../input.zig");
    var random: libcmt.Rand = .{};
    const all = try create.Objects.create(std.testing.allocator, &random);
    defer all.destroy();
    var tables = create.testing.tables();
    var player: input.Player = .{};
    var shake: f32 = 0;
    const world = testing.world(all, &player, &shake);

    // Two ships of the same mass, the first flying into the second.
    const near = try testing.ship(all, &tables, &random, .{ -900, 0, 0 }, 1000);
    const far = try testing.ship(all, &tables, &random, .{ 900, 0, 0 }, 1000);
    for ([_]u16{ near, far }) |index| {
        all.slots[index].object.mass = 1000;
        all.slots[index].object.angular_response = math.identity;
    }
    all.slots[near].object.velocity = .{ .x = 100, .y = 0, .z = 0 };
    all.slots[near].object.root.next_position = .{ .x = -800, .y = 0, .z = 0 };

    try std.testing.expect(collide(world, near, far, 0));
    // The one that ran in is thrown back, and the one it struck is pushed on.
    try std.testing.expect(all.slots[near].object.velocity.x < 100);
    try std.testing.expect(all.slots[far].object.velocity.x > 0);
    // What one takes, the other gives: the two shares of the momentum match.
    const given = 100 - all.slots[near].object.velocity.x;
    try std.testing.expectApproxEqAbs(given, all.slots[far].object.velocity.x, 1e-3);
    // Neither is set spinning: the point two spheres meet at lies on the line between their
    // centres, so the shove has no lever to turn them by. A hull's own faces do (#143).
    try std.testing.expectEqual(0, all.slots[near].object.rotation[1]);
    try std.testing.expectEqual(0, all.slots[far].object.rotation[1]);

    // An object held to another takes no shove.
    all.slots[far].object.flags.attached = true;
    all.slots[far].object.velocity = .{ .x = 0, .y = 0, .z = 0 };
    objects.setPosition(&all.slots[near].object, &all.slots[near].drawn, .{ -900, 0, 0 });
    objects.setPosition(&all.slots[far].object, &all.slots[far].drawn, .{ 900, 0, 0 });
    all.slots[near].object.velocity = .{ .x = 100, .y = 0, .z = 0 };
    try std.testing.expect(collide(world, near, far, 0));
    try std.testing.expectEqual(0, all.slots[far].object.velocity.x);
}

test "a ship that meets a hull is shoved off the face it hit" {
    const libcmt = @import("../libcmt.zig");
    const input = @import("../input.zig");
    const gpa = std.testing.allocator;
    var random: libcmt.Rand = .{};
    const all = try create.Objects.create(gpa, &random);
    defer all.destroy();
    var model: create.testing.Model = undefined;
    try model.init(gpa);
    defer model.deinit(gpa);
    model.withHull();
    var tables = create.testing.tables();
    var player: input.Player = .{};
    var shake: f32 = 0;
    const world = testing.world(all, &player, &shake);

    // A hull of one square part, and a ship flying into its face.
    // The inverse inertia of a body of this mass, about 6 / (mass * size squared), which is what
    // `recentre` works out from a model's parts.
    const hull_turn: math.Matrix = @splat(0);
    const hull = try create.createObject(all, &tables, model.types(), null, 0, @splat(0), &random);
    all.slots[hull].object.flags.components = true;
    all.slots[hull].object.mass = 100000;
    all.slots[hull].object.angular_response = hull_turn;
    all.slots[hull].object.angular_response[0] = 6e-9;
    all.slots[hull].object.angular_response[4] = 6e-9;
    all.slots[hull].object.angular_response[8] = 6e-9;
    all.slots[hull].motion = null;
    // The ship meets the face off to one side, so the hit has a lever on the hull.
    const ship = try create.createObject(all, &tables, create.testing.no_models, null, 0, .{ 60, 0, -60 }, &random);
    all.slots[ship].object.radius = 100;
    all.slots[ship].object.mass = 1000;
    all.slots[ship].object.angular_response = .{ 6e-7, 0, 0, 0, 6e-7, 0, 0, 0, 6e-7 };
    all.slots[ship].motion = null;
    all.slots[ship].object.velocity = .{ .x = 0, .y = 0, .z = 40 };
    all.slots[ship].object.root.next_position = .{ .x = 60, .y = 0, .z = -20 };

    try std.testing.expect(collide(world, ship, hull, 0));
    // It is thrown back off the face, which faces along -Z, and the hull is pushed the other way.
    try std.testing.expect(all.slots[ship].object.velocity.z < 40);
    try std.testing.expect(all.slots[hull].object.velocity.z > 0);
    // The hull turns about the hit, which the ship does not: it is shoved at its own centre.
    try std.testing.expect(all.slots[hull].object.yaw_rate != 0 or all.slots[hull].object.pitch_rate != 0);
    try std.testing.expectEqual(0, all.slots[ship].object.yaw_rate);

    // A ship nowhere near the hull meets nothing.
    objects.setPosition(&all.slots[ship].object, &all.slots[ship].drawn, .{ 0, 0, -5000 });
    all.slots[ship].object.velocity = .{ .x = 0, .y = 0, .z = 0 };
    try std.testing.expect(!collide(world, ship, hull, 0));

    // Two hulls pass through each other.
    all.slots[ship].object.flags.components = true;
    try std.testing.expect(!collide(world, ship, hull, 0));
}

test damage {
    const libcmt = @import("../libcmt.zig");
    const input = @import("../input.zig");
    var random: libcmt.Rand = .{};
    const all = try create.Objects.create(std.testing.allocator, &random);
    defer all.destroy();
    var tables = create.testing.tables();
    var player: input.Player = .{};
    var shake: f32 = 0;
    const world = testing.world(all, &player, &shake);
    const index = try testing.ship(all, &tables, &random, @splat(0), 1000);
    const object = &all.slots[index].object;
    object.shields = .{ 10, 10, 10, 10 };
    object.armor = .{ 20, 20, 20, 20 };

    // The shield takes it first.
    damage(world, index, .fore, 4, 1, 1, .collision);
    try std.testing.expectEqual(6, object.shields[2]);
    try std.testing.expectEqual(20, object.armor[2]);
    try std.testing.expectEqual(1, object.last_attacker);

    // Past the shield, the rest wears the armour, and the armour's conditions follow.
    damage(world, index, .fore, 10, 1, 1, .collision);
    try std.testing.expect(object.shields[2] < 0);
    try std.testing.expectEqual(16, object.armor[2]);
    try std.testing.expect(object.gun_condition < 1);

    // A collision is not what sends a ship after its attacker; a shot is. What passes a shield
    // that is already down carries the shield's deficit with it, so the armour takes both.
    try std.testing.expectEqual(0, object.recent_damage);
    damage(world, index, .fore, 1, 1, 1, @enumFromInt(0));
    try std.testing.expectEqual(6, object.recent_damage);

    // Debris takes none, and neither does a ship that is jumping.
    const left = object.armor[2];
    tables.combat[0].class = .debris;
    damage(world, index, .fore, 100, 1, 1, .collision);
    try std.testing.expectEqual(left, object.armor[2]);
    tables.combat[0].class = .fighter;
    object.flags.jumping = true;
    damage(world, index, .fore, 100, 1, 1, .collision);
    try std.testing.expectEqual(left, object.armor[2]);
}

test quadrant {
    var object = gameobj.testing.object();
    object.bounds_min = .{ .x = -100, .y = -50, .z = -400 };
    object.bounds_max = .{ .x = 100, .y = 50, .z = 400 };
    // Along the ship counts for more than across it, so the nose and tail win the middle ground.
    try std.testing.expectEqual(.fore, quadrant(&object, .{ 0, 0, 300 }));
    try std.testing.expectEqual(.aft, quadrant(&object, .{ 0, 0, -300 }));
    try std.testing.expectEqual(.right, quadrant(&object, .{ 90, 0, 10 }));
    try std.testing.expectEqual(.left, quadrant(&object, .{ -90, 0, 10 }));
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
    try std.testing.expect(!collide(world, near, far, 0));

    // So do a torpedo and another object of its own type.
    tables.combat[0].class = .torpedo;
    try std.testing.expect(!collide(world, near, far, 0));

    // A torpedo of another type goes off against it instead of pushing it.
    tables.combat[1].class = .fighter;
    all.slots[far].object.type = 1;
    all.slots[far].combat = &tables.combat[1];
    try std.testing.expect(collide(world, near, far, 0));
    try std.testing.expectEqual(0, all.slots[near].object.root.position.x);

    // An object that lists components is met by its parts, which aren't ported, so nothing comes
    // of it.
    tables.combat[0].class = .fighter;
    all.slots[far].object.flags.components = true;
    try std.testing.expect(!collide(world, near, far, 0));
    try std.testing.expectEqual(0, all.slots[near].object.root.position.x);
}
