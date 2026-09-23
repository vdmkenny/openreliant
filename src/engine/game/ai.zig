//! `C:\lancer\game\Ai.cpp`: the order table, every order objects follow.
//! [`ai/orders.zig`](ai/orders.zig) transcribes it. **Unverified:** the table lies in the data
//! before this file's path, which holds this file's data or an earlier file's.

const std = @import("std");
const assert = std.debug.assert;

const engine = @import("../../engine.zig");
const Pointer = engine.Pointer;
const gameobj = @import("gameobj.zig");
const Routine = gameobj.Routine;
const camera = @import("camera.zig");
const create = @import("create.zig");
const math = @import("../surrender/math.zig");
const Vector = math.Vector;
const motion = @import("motion.zig");
const aigeneric = @import("aigeneric.zig");
const guns = @import("guns.zig");
const objects = @import("objects.zig");
const GameObject = gameobj.GameObject;

pub const orders = @import("ai/orders.zig");

/// A record of the order table. `order_groups` points at the records of each hundred order
/// numbers: order `n` is record `n % 100` of group `n / 100`.
pub const Record = extern struct {
    /// Runs before the order's first update. Null for none.
    init: Pointer(Routine),
    /// Runs each time `object_orders` runs the order.
    update: Pointer(Routine),
    /// Runs when the order is popped or replaced after it has started. Null for none.
    exit: Pointer(Routine),
    flags: Flags,
    /// The developers' name for the order, which fatal errors show.
    name: Pointer(u8),
    /// Zero for an order that any other replaces. Otherwise, once it has started, only `explode`, a
    /// one-shot order or an order of higher priority may be pushed on it, and pushing another is a
    /// fatal error.
    priority: i32,

    pub const Flags = packed struct(u32) {
        /// It may be given to a player's ship. A player's ship refuses the other orders numbered
        /// below 100.
        players: bool,
        /// **Unknown.** Bits set on some orders that nothing in the payload tests.
        _unknown_1: u4,
        /// It runs its update once, then pops itself, and the order below carries on without
        /// starting again. Its `init` never runs.
        one_shot: bool,
        /// While it runs, a ship that takes enough damage turns to fight its attacker
        /// (`order_retaliate`).
        retaliate: bool,
        /// While it runs, `avoidance_scan` lists the objects the ship could hit, up to ten of each
        /// of two kinds at `GameObject` offsets `0x6B4` and `0x6E0`, unless the object has
        /// `no_avoidance`; `docs/engine/orders.md` says which.
        avoidance: bool,
        _unknown_8: u2,
        /// While it runs, a multiplayer game sends the ship's steering inputs, throttle, rates and
        /// velocity.
        send_flight: bool,
        _unknown_11: u21,
    };

    comptime {
        assert(@offsetOf(Record, "flags") == 0xC);
        assert(@sizeOf(Record) == 0x18);
    }
};

test {
    std.testing.refAllDecls(@This());
}

/// Where the AI aims at a target, and how far across that is: the part a component names, the
/// part a few types are aimed at by (`gameobj.Type.aimedChild`), or the object itself
/// (`0x004018F0`, which gives the part's node). **Unverified:** these helpers lie before this
/// file's path, beside `ai_steer`.
pub const Aimed = struct {
    position: Vector,
    radius: f32,
    /// How the part hanging from the root that it is, or hangs from, is turned; the object's own
    /// turn for the object itself (`maneuver_new_attack_run_run`, which walks up to it).
    orientation: math.Matrix,

    fn ofPart(model: *const objects.Model, part: *const objects.Model.Part) Aimed {
        return .{ .position = part.object.position, .radius = part.object.radius, .orientation = model.topOf(part).object.orientation };
    }
};

pub fn aimedAt(all: *const create.Objects, target: aigeneric.Target) Aimed {
    const slot = &all.slots[@intCast(target.index)];
    if (targetPart(all, target)) |part| return .ofPart(&slot.model.?, part);
    return .{ .position = slot.drawn.position, .radius = slot.object.radius, .orientation = slot.drawn.orientation };
}

/// `ai_target_node` (`0x004018F0`): the part whose node a target names, the component or the part
/// a few types are aimed at by, or null for the object's root.
pub fn targetPart(all: *const create.Objects, target: aigeneric.Target) ?*const objects.Model.Part {
    const slot = &all.slots[@intCast(target.index)];
    const model = if (slot.model) |*model| model else return null;
    if (target.component >= 0 and target.component < slot.components.len) {
        if (slot.components[@intCast(target.component)]) |part| return part;
    }
    const child = slot.object.type.aimedChild() orelse return null;
    return model.rootChild(child);
}

/// `0x00402860`: the entry of the player's orders that is Player Control, which holds the
/// player's target, or null for none.
pub fn playerControlEntry(all: *create.Objects) ?*aigeneric.Entry {
    const slot = &all.slots[all.player];
    for (slot.orders[0..@intCast(slot.object.order_count)]) |*entry| {
        if (entry.order == .player_control) return entry;
    }
    return null;
}

/// How much further a Turret Flak's shot is led for, over its type's lifetime (`0x004DC3D8`), and
/// the share of a gun's range within which a shot is led at all (`0x004DC3D4`).
const flak_lead: f32 = 3;
const lead_range: f32 = 0.25;

/// `0x00401280`: where to aim at `target` for the fastest of the guns the ship fires together to
/// hit it: ahead of it along its heading by how far it flies, times `lead`, while that gun's shot
/// flies to it (`0x00401180`). Null where that takes longer than a quarter of the gun's life, when
/// the caller aims at it unled.
pub fn leadAim(all: *const create.Objects, index: u16, target: aigeneric.Target, lead: f32) ?Vector {
    const slot = &all.slots[index];
    var fastest: guns.GunType = .laser_cannon;
    var best: f32 = -1;
    var chosen: guns.Chosen = .of(&slot.object, slot.guns, slot.gun_groups);
    while (chosen.next()) |gun| {
        const speed = gun.type.stats(&all.gun_stats).speed;
        if (speed > best) {
            best = speed;
            fastest = gun.type;
        }
    }
    const record = fastest.stats(&all.gun_stats);
    const life: f32 = @floatFromInt(record.lifetime);
    const lifetime = if (fastest == .turret_flak) life * flak_lead else life;
    const aimed = aimedAt(all, target);
    const flight = math.distance(slot.drawn.position, aimed.position) / record.speed;
    if (!(flight < lifetime * lead_range)) return null;
    const struck = &all.slots[@intCast(target.index)];
    return aimed.position + math.forward(struck.drawn.orientation) * @as(Vector, @splat(flight * struck.object.speed * lead));
}

/// `0x004010F0`: whether `point` lies ahead of `place` and within `radius` of the line along its
/// nose.
pub fn alongNose(place: math.Place, point: Vector, radius: f32) bool {
    const offset = point - place.position;
    const along = math.dot(math.forward(place.orientation), offset);
    if (!(along > 0)) return false;
    return math.lengthSquared(offset) - along * along < radius * radius;
}

/// How near a box of a hull has to be for `escapeDirection` to push away from it (`0x004DC444`).
const escape_reach: f32 = 20000;

/// `0x00402500`: which way lies clear of a ship's hull from `from`. Each box of the collision trees
/// of the parts hanging from its root whose edge, taking it as a sphere as wide as its half-size, is
/// within `escape_reach` of `from` pushes away from it, the harder the nearer it is; the sum,
/// normalized.
pub fn escapeDirection(slot: *const create.Slot, from: Vector) Vector {
    var away: Vector = @splat(0);
    const model = if (slot.model) |*model| model else return math.normalize(away);
    const source = (slot.type orelse return math.normalize(away)).model;
    const count = @min(model.parts.len, source.parts.len);
    for (model.parts[0..count], source.parts[0..count]) |part, data| {
        if (part.parent != null) continue;
        for (data.nodes) |node| {
            const toward = math.transform(part.object.orientation, gameobj.vector(node.centre)) + part.object.position - from;
            const gap = math.length(toward) - math.length(gameobj.vector(node.half_size));
            if (gap < escape_reach and gap > 0) away += math.normalize(toward) * @as(Vector, @splat(gap - escape_reach));
        }
    }
    return math.normalize(away);
}

/// How much of the target's velocity the course is closed against (`0x00401980`), and the least
/// closing that counts (`0x004DC418`).
const crash_target_share: f32 = -2;
const least_closing: f32 = 0.001;

/// `0x00401980`: whether the ship at `index` is on course to hit `target`, one without listed
/// components, within `steps` simulation steps and with `margin` to spare: they are within reach
/// of each other at their cruise speeds, the target is ahead of the ship, and the ship is closing
/// on it by its velocity less twice the target's, to within both radii and the margin.
///
/// Not ported: against a target with listed components, the parts of it the ship could hit
/// ([#40](https://github.com/vdmkenny/openreliant/issues/40)); that is taken as no.
pub fn collisionCourse(world: gameobj.World, index: u16, target: u16, steps: f32, margin: f32) bool {
    const all = world.objects;
    const ship = &all.slots[index];
    const struck = &all.slots[target];
    if (struck.object.flags.components) return false;
    const ship_flight = ship.flight orelse return false;
    const struck_flight = struck.flight orelse return false;
    var apart = ship.object.nextPosition() - struck.object.nextPosition();
    const speeds = cruiseSpeed(&struck.object, struck_flight, world.view) + cruiseSpeed(&ship.object, ship_flight, world.view);
    const reach = speeds * steps + struck.object.radius + ship.object.radius + margin;
    if (math.lengthSquared(apart) > reach * reach) return false;
    const closing = gameobj.vector(struck.object.velocity) * @as(Vector, @splat(crash_target_share)) + gameobj.vector(ship.object.velocity);
    if (math.dot(ship.object.nextHeading(), apart) > 0) return false;
    const along = math.dot(apart, closing);
    if (-along < 0) return false;
    const rate = math.dot(closing, closing);
    if (rate < least_closing) return false;
    apart += closing * @as(Vector, @splat(@min(-along / rate, steps)));
    const touching = struck.object.radius + ship.object.radius + margin;
    return math.lengthSquared(apart) < touching * touching;
}

/// A pilot ejects rather than go down with the ship where its `eject_roll` is below this
/// (`0x28`).
pub const eject_below = 40;

/// `object_destroyed` (`0x00401F30`): a ship's end. An AI ship's pilot ejects where the mission
/// lets it and its roll says so, or where the ship is told to eject before exploding, and the ship
/// spins on under Eject Spin. The player's ejects, unless it already has or the blow was too
/// heavy, or it is flying the Kamov, and its ship blows up later (`aieject.playerInit`).
/// Otherwise the ship explodes (`aiexplode`), in place of whatever it was doing: the stack is
/// overwritten whether or not its order gives way, and the order's state is left for Explode's
/// `init` to fill in. `may_spin` goes into the order's data.
///
/// Not ported: multiplayer, where the player's ship explodes at once.
pub fn objectDestroyed(ctx: aigeneric.Context, index: u16, may_spin: bool, no_eject: bool) void {
    const all = ctx.world.objects;
    const slot = &all.slots[index];
    const object = &slot.object;
    const ai_pilot_ejects = index >= all.players and object._unknown_74c == 0 and object.eject_roll < eject_below;
    if (!object.flags.ejected and (ai_pilot_ejects or object.invulnerable == .eject_before_exploding)) {
        replaceOrders(ctx, index, .eject, .eject_spin, may_spin);
        return;
    }
    if (slot.orders[0].order == .explode) return;
    if (index == all.player and !object.flags.ejected and !no_eject and object.type != .kamov) {
        if (slot.orders[0].order != .eject_player) {
            const aimed = slot.orders[0].target;
            _ = aigeneric.push(ctx, index, .eject_player, .{ .kind = .ship, .index = aimed.index, .component = aimed.component }) catch false;
            object.flags.ejected = true;
            return;
        }
        if (slot.state.eject_player.ended == 0) return;
        _ = aigeneric.pop(ctx, index);
    }
    replaceOrders(ctx, index, .explode, .explode, may_spin);
    object.flags.exploding = true;
}

/// Clears the way as for `making_way`, whatever the current order says, and leaves `order`,
/// aimed at nothing, as the only one, starting.
fn replaceOrders(ctx: aigeneric.Context, index: u16, making_way: orders.Order, order: orders.Order, may_spin: bool) void {
    const slot = &ctx.world.objects.slots[index];
    _ = aigeneric.giveWay(ctx, index, making_way) catch false;
    slot.object.order_count = 1;
    slot.orders[0].order = order;
    slot.orders[0].target = .none;
    slot.orders[0].data.destroyed = .{ .may_spin = may_spin };
    slot.object.order_starting = true;
}

/// `object_set_targetable` (`0x00401830`): sets or clears the object's `targetable` flag, which
/// stays clear for an object with no stats or of a type that can't be targeted
/// (`ShipCombat.Targeting`). **Unverified:** it lies before this file's known code.
pub fn setTargetable(object: *gameobj.GameObject, combat: ?*const create.ShipCombat, targetable: bool) void {
    const allowed = if (combat) |stats| stats.targeting.targetable else false;
    object.flags.targetable = targetable and allowed;
}

test objectDestroyed {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const ctx = mission.orders();
    const player = try mission.add(.predator, @splat(0));
    const other = try mission.add(.sabre, .{ 0, 0, 1000 });
    const slots = &mission.objects.slots;

    // An AI ship explodes, taking no order after.
    try std.testing.expect(try aigeneric.push(ctx, other, .do_nothing, .none));
    objectDestroyed(ctx, other, true, false);
    try std.testing.expectEqual(.explode, slots[other].orders[0].order);
    try std.testing.expectEqual(1, slots[other].object.order_count);
    try std.testing.expect(slots[other].object.flags.exploding and slots[other].object.order_starting);
    try std.testing.expect(!try aigeneric.push(ctx, other, .do_nothing, .none));

    // Where the mission lets its pilot eject, a low roll ejects, and the ship spins on.
    const ejecting = try mission.add(.sabre, .{ 0, 0, 2000 });
    slots[ejecting].object._unknown_74c = 0;
    slots[ejecting].object.eject_roll = eject_below - 1;
    objectDestroyed(ctx, ejecting, true, false);
    try std.testing.expectEqual(.eject_spin, slots[ejecting].orders[0].order);
    try std.testing.expect(!slots[ejecting].object.flags.exploding);

    // The player's pilot ejects, unless the blow was too heavy.
    objectDestroyed(ctx, player, true, false);
    try std.testing.expectEqual(.eject_player, slots[player].orders[0].order);
    try std.testing.expect(slots[player].object.flags.ejected);
    const heavy = try mission.add(.predator, .{ 0, 0, 3000 });
    mission.objects.player = heavy;
    objectDestroyed(ctx, heavy, true, true);
    try std.testing.expectEqual(.explode, slots[heavy].orders[0].order);
}

test setTargetable {
    var object = gameobj.testing.object();
    var combat = std.mem.zeroes(create.ShipCombat);
    setTargetable(&object, &combat, true);
    try std.testing.expect(!object.flags.targetable);
    combat.targeting.targetable = true;
    setTargetable(&object, &combat, true);
    try std.testing.expect(object.flags.targetable);
    setTargetable(&object, &combat, false);
    try std.testing.expect(!object.flags.targetable);
    object.flags.targetable = true;
    setTargetable(&object, null, true);
    try std.testing.expect(!object.flags.targetable);
}

/// The view `object_cruise_speed` leaves a ship its undamaged speed in, whatever its armor.
const full_speed_view: camera.View = @enumFromInt(13);

/// `object_cruise_speed` (`0x00403060`), which lies after this file's known code, before
/// `aidefend.cpp`'s: `max_speed` scaled by `speed_factor`, by the share of its
/// engines left, and, unless the camera is in view 13 or the object is invulnerable, by
/// `armor_speed_factor` as well. So losing engines or armor slows a ship.
///
/// The port takes the flight stats and the view rather than reaching them through the object and a
/// global, since `GameObject` holds the binary's own 32-bit pointers.
pub fn cruiseSpeed(object: *const gameobj.GameObject, flight: *const create.FlightModel, view: camera.View) f32 {
    var speed = flight.max_speed * object.speed_factor * object.engines_intact;
    if (view != full_speed_view and object.invulnerable == .none) speed *= object.armor_speed_factor;
    return speed;
}

test cruiseSpeed {
    var object = gameobj.testing.object();
    try std.testing.expectEqual(320, cruiseSpeed(&object, &gameobj.testing.flight, .chase));
    // Losing half its engines and a fifth of its armor slows it.
    object.engines_intact = 0.5;
    object.armor_speed_factor = 0.8;
    try std.testing.expectEqual(128, cruiseSpeed(&object, &gameobj.testing.flight, .chase));
    // The armor tells in every view but 13, and not at all while it is invulnerable.
    try std.testing.expectEqual(160, cruiseSpeed(&object, &gameobj.testing.flight, @enumFromInt(13)));
    object.invulnerable = .player_can_hit;
    try std.testing.expectEqual(160, cruiseSpeed(&object, &gameobj.testing.flight, .chase));
}

/// What `ai_steer` does besides turning toward its point, as the orders and the maneuvers ask for
/// it.
pub const Steering = packed struct(u32) {
    /// Move the point around the objects with listed components the ship could hit (`avoid_near`,
    /// `0x004028F0`), which isn't ported yet
    /// ([#140](https://github.com/vdmkenny/openreliant/issues/140)).
    avoid_near: bool = false,
    /// Move the point around the objects the ship is closing on (`avoid_ahead`, `0x00402DC0`),
    /// which isn't ported yet either.
    avoid_ahead: bool = false,
    /// Unless avoidance took the point over, roll toward the world's Y axis as well
    /// (`rollUpright`).
    roll_upright: bool = false,
    /// Hold the pitch at `pitch_floor` or more, so the ship keeps its nose up.
    pitch_up: bool = false,
    _unknown_4: u28 = 0,
};

/// The turn that fills a steering input: an input reaches 1 at five degrees off, the angle in
/// degrees over five (`0x004DC3FC`).
///
/// **Improvement:** the game holds this rounded to 11.459155, one place in the last digit below
/// the figure the port computes.
const input_per_radian: f32 = std.math.deg_per_rad / 5.0;

/// How much of the turn rate the steering takes off its input at no ease, which damps the turn as
/// the ship comes round (`0x004DC400`).
const rate_damping: f32 = 6;

/// While a frame takes more than this many ticks, `steer` halves the turns under `half_turn`, so a
/// slow frame doesn't overshoot (`frame_duration`).
const slow_frame: i32 = 10;

/// The turn `steer` halves while frames are slow (`0x004DC40C`), which is an eighth of a turn.
const half_turn: f32 = std.math.pi / 8.0;

/// Where `Steering.pitch_up` holds the pitch input (`0x004DC3F8`).
const pitch_floor: f32 = 0.2;

/// How near its nose a direction counts as ahead: the cosine of the angle (`0x004DC414`).
const ahead_cosine: f32 = 0.95;

/// How far the roll may be off, in radians, before the ship pitches as well (`0x004DC410`).
const roll_before_pitch: f32 = 0.8;

/// `ai_steer` (`0x00401380`): the AI's steering, which the orders and the maneuvers turn a ship
/// with. It aims the ship at `at`, a point in the world, by setting its three turning inputs: the
/// angles off its nose, less `(1 - ease) * 6` times each turn rate, as shares of five degrees, each
/// held within `limit` and 1. `ease` slackens the damping, so an eased turn swings further.
///
/// Where the flags ask for avoidance, the point moves around what the ship could hit first, and the
/// turn is then made at full limit with no ease; that isn't ported yet
/// ([#140](https://github.com/vdmkenny/openreliant/issues/140)), so the point stands as the caller
/// gave it and this always returns false.
///
/// It steers by the place the ship is drawn at, which is where the frames have moved it to since
/// the last step, since the orders run once a frame.
///
/// **Improvement:** the angles come from `std.math.atan2` rather than the engine's table
/// (`sr_atan2`), as they do elsewhere in the port.
pub fn steer(slot: *create.Slot, at: Vector, limit_given: f32, ease_given: f32, flags_given: Steering, frame_duration: i32) bool {
    const object = &slot.object;
    // A ship with no flight stats would follow a null pointer here, so it steers nowhere instead.
    const flight = slot.flight orelse return false;
    var flags = flags_given;
    var ease = ease_given;
    var limit = limit_given;
    const avoided = false;
    if (avoided) {
        limit = 1;
        ease = 0;
        flags.pitch_up = false;
    }
    const held = limit;

    object.pitch_input = 0;
    object.yaw_input = 0;
    object.roll_input = 0;
    const direction = math.transformTransposed(slot.drawn.orientation, at - slot.drawn.position);
    if (@as(u16, @truncate(flight._unknown_24)) == 0) {
        steerAngles(object, direction, slot.motion == .backward, flags);
    } else {
        steerAxes(object, direction);
    }

    // A slow frame turns the ship further than a quick one, so the small turns are halved.
    if (frame_duration > slow_frame) {
        var halved = false;
        inline for (.{ &object.pitch_input, &object.yaw_input, &object.roll_input }) |input| {
            if (@abs(input.*) < half_turn) {
                input.* *= 0.5;
                halved = true;
            }
        }
        if (halved) limit = held * 0.5;
    }

    const damping = (1 - ease) * rate_damping;
    object.pitch_input = (object.pitch_input - damping * object.pitch_rate) * input_per_radian;
    object.yaw_input = (object.yaw_input - damping * object.yaw_rate) * input_per_radian;
    object.roll_input = (object.roll_input - damping * object.roll_rate) * input_per_radian;

    limit = @min(limit, 1);
    object.pitch_input = @min(object.pitch_input, limit);
    object.pitch_input = if (flags.pitch_up) @max(object.pitch_input, pitch_floor) else @max(object.pitch_input, -limit);
    object.yaw_input = std.math.clamp(object.yaw_input, -limit, limit);
    object.roll_input = std.math.clamp(object.roll_input, -limit, limit);

    if (!avoided and flags.roll_upright) rollUpright(object, at);
    return avoided;
}

/// `0x00401710`: the turns that bring `direction`, the point in the ship's own frame, onto its
/// nose. A ship flying backwards turns toward the other way about.
///
/// Within `ahead_cosine` of the nose axis it simply yaws. Further off it banks first, rolling to
/// bring the point overhead, or under it while the point is below or the pitch is held up; and it
/// pitches only once the roll is nearly right, so the ship turns the way a pilot would fly it.
fn steerAngles(object: *GameObject, direction: Vector, backward: bool, flags: Steering) void {
    var toward = math.normalize(direction);
    if (backward) toward = -toward;
    if (@abs(toward[2]) >= ahead_cosine) {
        object.yaw_input = std.math.atan2(toward[0], toward[2]);
    } else if (toward[1] < 0 or flags.pitch_up) {
        object.roll_input = -std.math.atan2(-toward[0], -toward[1]);
    } else {
        object.roll_input = -std.math.atan2(toward[0], toward[1]);
    }
    if (@abs(object.roll_input) < roll_before_pitch) object.pitch_input = -std.math.atan2(toward[1], toward[2]);
}

/// `0x00401690`: the turns for a ship whose flight stats hold a word at `+0x24`, which pitches and
/// yaws at the point together and never rolls. With the point behind it, it yaws hard to the side
/// the point lies on. Nothing in the shipped game's ship stats sets that word.
fn steerAxes(object: *GameObject, direction: Vector) void {
    if (direction[2] >= 0) {
        object.pitch_input = -std.math.atan2(direction[1], direction[2]);
        object.yaw_input = std.math.atan2(direction[0], direction[2]);
        return;
    }
    object.yaw_input = if (direction[0] < 0) -1 else 1;
}

/// `ai_roll_upright` (`0x00403170`): rolls the ship level with the world, which it does while it
/// is flying at the point it steers by.
pub fn rollUpright(object: *GameObject, at: Vector) void {
    rollToward(object, at, .{ 0, 1, 0 });
}

/// `0x00403090`: rolls the ship so that `axis` stands up in its own frame, by the same measure the
/// steering turns by. It rolls only while `at` is within `ahead_cosine` of dead ahead, so a ship
/// levels off once it is flying at what it steers by rather than while it is still coming round.
fn rollToward(object: *GameObject, at: Vector, axis: Vector) void {
    const toward = at - object.nextPosition();
    if (math.dot(toward, object.nextHeading()) <= math.length(toward) * ahead_cosine) return;
    const up = math.transformTransposed(object.root.next_orientation, axis);
    const roll = (-std.math.atan2(up[0], up[1]) - object.roll_rate * rate_damping) * input_per_radian;
    object.roll_input = std.math.clamp(roll, -1, 1);
}

/// `object_stop` (`0x00403000`): stops an object dead, keeping where it is and how it is turned.
/// **Unverified:** it lies after this file's known code, before `aidefend.cpp`'s.
pub fn stop(object: *GameObject) void {
    object.velocity = .{ .x = 0, .y = 0, .z = 0 };
    object.rotation = math.identity;
    object.throttle = 0;
    object.yaw_input = 0;
    object.pitch_input = 0;
    object.roll_input = 0;
    object.lateral_input = 0;
    object.speed = 0;
    object.yaw_rate = 0;
    object.pitch_rate = 0;
    object.roll_rate = 0;
}

/// The flags that bar an object from being aimed at (`targetValid`).
pub const target_barred: GameObject.Flags = .{
    .exploding = true,
    .cloaked = true,
    .disabled = true,
    .ejected = true,
    ._unknown_28 = true,
};

/// `order_target_valid` (`0x00401870`): whether an order's target can still be aimed at. The object
/// must be targetable and none of `target_barred`, save the flags in `allowed`, and a component
/// must be one the object has and neither hidden nor passed over. **Unverified:** it lies before
/// this file's known code.
pub fn targetValid(all: *const create.Objects, target: aigeneric.Target, allowed: GameObject.Flags) bool {
    if (target.index < 0 or target.index >= all.slots.len) return false;
    const slot = &all.slots[@intCast(target.index)];
    const object = &slot.object;
    if (!object.flags.targetable) return false;
    const barred = @as(u32, @bitCast(object.flags)) & ~@as(u32, @bitCast(allowed)) & @as(u32, @bitCast(target_barred));
    if (barred != 0) return false;
    if (target.component < 0) return true;
    if (target.component >= object.component_count) return false;
    // The game also passes over a node marked with flag `0x10`, which the port does not keep.
    const part = slot.components[@intCast(target.component)] orelse return false;
    return !part.hidden;
}

comptime {
    assert(@as(u32, @bitCast(target_barred)) == 0x10000D40);
}

test playerControlEntry {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const player = try mission.add(.predator, @splat(0));
    try std.testing.expectEqual(null, playerControlEntry(mission.objects));
    // Found below an order pushed over it.
    try std.testing.expect(try aigeneric.push(mission.orders(), player, .player_control, .none));
    try std.testing.expect(try aigeneric.push(mission.orders(), player, .eject_player, .none));
    const entry = playerControlEntry(mission.objects).?;
    try std.testing.expectEqual(&mission.slot(player).orders[1], entry);
}

test steer {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const index = try mission.add(.predator, @splat(0));
    const slot = &all.slots[index];

    // Dead ahead, nothing turns.
    _ = steer(slot, .{ 0, 0, 4000 }, 1, 0, .{}, 1);
    try std.testing.expectEqual(0, slot.object.yaw_input);
    try std.testing.expectEqual(0, slot.object.pitch_input);
    try std.testing.expectEqual(0, slot.object.roll_input);

    // A point well off the nose is banked toward before it is pitched at.
    _ = steer(slot, .{ 4000, 4000, 1000 }, 1, 0, .{}, 1);
    try std.testing.expect(@abs(slot.object.roll_input) > 0);

    // A point a little off the nose is yawed at, within the limit it is given.
    _ = steer(slot, .{ 200, 0, 4000 }, 0.25, 0, .{}, 1);
    try std.testing.expectEqual(0.25, @abs(slot.object.yaw_input));
    try std.testing.expectEqual(0, slot.object.roll_input);

    // The turn rate damps the input, the less so the more the ease.
    slot.object.yaw_rate = 0.02;
    _ = steer(slot, .{ 200, 0, 4000 }, 1, 0, .{}, 1);
    const damped = slot.object.yaw_input;
    _ = steer(slot, .{ 200, 0, 4000 }, 1, 1, .{}, 1);
    try std.testing.expect(damped < slot.object.yaw_input);
    slot.object.yaw_rate = 0;

    // With the pitch held up it never dips below the floor, whichever way the point lies.
    slot.object.pitch_rate = 1;
    _ = steer(slot, .{ 0, -4000, 1000 }, 1, 0, .{ .pitch_up = true }, 1);
    try std.testing.expectEqual(pitch_floor, slot.object.pitch_input);
}

test "a ship steered at a point comes round to face it" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const index = try mission.add(.predator, @splat(0));
    const slot = &all.slots[index];
    const at: Vector = .{ 20000, 6000, 10000 };

    const off = struct {
        /// How far the point lies off the ship's nose, in radians.
        fn angle(ship: *const create.Slot, point: Vector) f32 {
            const toward = math.normalize(point - gameobj.vector(ship.object.root.position));
            return std.math.acos(std.math.clamp(math.dot(toward, math.forward(ship.object.root.orientation)), -1, 1));
        }
    }.angle;

    const before = off(slot, at);
    for (0..50) |_| {
        _ = steer(slot, at, 1, 0, .{ .roll_upright = true }, 1);
        motion.move(&slot.object, slot.flight.?, .chase, .forward, null);
        // What the next step commits, which the steering then reads.
        slot.object.root.position = slot.object.root.next_position;
        slot.object.root.orientation = slot.object.root.next_orientation;
        slot.drawn = .{ .position = gameobj.vector(slot.object.root.position), .orientation = slot.object.root.orientation };
    }
    try std.testing.expect(off(slot, at) < before / 4);
}

test "a slow frame halves the small turns" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const index = try mission.add(.predator, @splat(0));
    const slot = &all.slots[index];

    _ = steer(slot, .{ 200, 0, 4000 }, 1, 0, .{}, slow_frame);
    const quick = slot.object.yaw_input;
    _ = steer(slot, .{ 200, 0, 4000 }, 1, 0, .{}, slow_frame + 1);
    try std.testing.expectApproxEqAbs(quick * 0.5, slot.object.yaw_input, 1e-6);
}

test alongNose {
    const place: math.Place = .{ .position = .{ 0, 0, 100 } };
    // Ahead and near the line, it is; behind, or wide of it, it isn't.
    try std.testing.expect(alongNose(place, .{ 5, 0, 1000 }, 10));
    try std.testing.expect(!alongNose(place, .{ 5, 0, 0 }, 10));
    try std.testing.expect(!alongNose(place, .{ 50, 0, 1000 }, 10));
}

test "aiming at a target" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const ship = try mission.add(.predator, @splat(0));
    const target = try mission.add(.sabre, .{ 0, 0, 1000 });
    const struck = &all.slots[target];
    struck.drawn = .{ .position = .{ 0, 0, 1000 }, .orientation = math.rotation(.y, std.math.pi / 2.0) };
    struck.object.speed = 10;
    const aimed: aigeneric.Target = .{ .kind = .ship, .index = @intCast(target), .component = -1 };
    try std.testing.expectEqual(Vector{ 0, 0, 1000 }, aimedAt(all, aimed).position);

    // With no gun fast enough to reach it in a quarter of its life, it isn't led.
    const laser = &all.gun_stats.types[guns.GunType.laser_cannon.number()];
    laser.speed = 100;
    laser.lifetime = 20;
    try std.testing.expectEqual(null, leadAim(all, ship, aimed, 1));
    // With one, it is led along its heading by how far it flies while the shot does.
    laser.lifetime = 100;
    const led = leadAim(all, ship, aimed, 1).?;
    try std.testing.expectApproxEqAbs(100, led[0], 1e-3);
    try std.testing.expectApproxEqAbs(1000, led[2], 1e-3);
}

test collisionCourse {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const world = mission.world();
    const all = mission.objects;
    const ship = try mission.add(.predator, @splat(0));
    const target = try mission.add(.sabre, .{ 0, 0, 2000 });
    all.slots[ship].object.velocity = .{ .x = 0, .y = 0, .z = 50 };

    // Flying straight at it, it is on course to hit; turned away, or past it, it isn't.
    try std.testing.expect(collisionCourse(world, ship, target, 100, 500));
    all.slots[ship].object.velocity = .{ .x = 0, .y = 0, .z = -50 };
    try std.testing.expect(!collisionCourse(world, ship, target, 100, 500));
    all.slots[ship].object.velocity = .{ .x = 0, .y = 0, .z = 50 };
    all.slots[target].object.root.next_position = .{ .x = 0, .y = 0, .z = -2000 };
    try std.testing.expect(!collisionCourse(world, ship, target, 100, 500));
}

test rollUpright {
    var object = gameobj.testing.object();
    object.root.next_orientation = math.rotation(.z, 0.5);
    // Rolled over, with the point it steers by dead ahead, it rolls back level.
    rollUpright(&object, .{ 0, 0, 1000 });
    try std.testing.expect(object.roll_input < 0);
    // With the point off to the side it holds its roll.
    object.roll_input = 0;
    rollUpright(&object, .{ 1000, 0, 0 });
    try std.testing.expectEqual(0, object.roll_input);
}

test stop {
    var object = gameobj.testing.object();
    object.velocity = .{ .x = 1, .y = 2, .z = 3 };
    object.speed = 10;
    object.throttle = 1;
    object.yaw_rate = 0.5;
    object.rotation = math.rotation(.y, 0.1);
    stop(&object);
    try std.testing.expectEqual(0, object.speed);
    try std.testing.expectEqual(0, object.velocity.z);
    try std.testing.expectEqual(0, object.throttle);
    try std.testing.expectEqual(0, object.yaw_rate);
    try std.testing.expectEqual(math.identity, object.rotation);
}
