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
const libcmt = @import("../libcmt.zig");
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

/// `object_set_targetable` (`0x00401830`): sets or clears the object's `targetable` flag, which
/// stays clear for an object with no stats or of a type that can't be targeted
/// (`ShipCombat.Targeting`). **Unverified:** it lies before this file's known code.
pub fn setTargetable(object: *gameobj.GameObject, combat: ?*const create.ShipCombat, targetable: bool) void {
    const allowed = if (combat) |stats| stats.targeting.targetable else false;
    object.flags.targetable = targetable and allowed;
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
    if (view != full_speed_view and object.invulnerable == 0) speed *= object.armor_speed_factor;
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
    object.invulnerable = 1;
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
    const toward = at - gameobj.vector(object.root.next_position);
    if (math.dot(toward, math.forward(object.root.next_orientation)) <= math.length(toward) * ahead_cosine) return;
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
    const model = if (slot.model) |*live| live else return false;
    return !model.parts[slot.components[@intCast(target.component)]].hidden;
}

comptime {
    assert(@as(u32, @bitCast(target_barred)) == 0x10000D40);
}

test steer {
    var random: libcmt.Rand = .{};
    const all = try create.Objects.create(std.testing.allocator, &random);
    defer all.destroy();
    var tables = create.testing.tables();
    const index = try create.createObject(all, &tables, create.testing.no_models, null, 0, @splat(0), &random);
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
    var random: libcmt.Rand = .{};
    const all = try create.Objects.create(std.testing.allocator, &random);
    defer all.destroy();
    var tables = create.testing.tables();
    const index = try create.createObject(all, &tables, create.testing.no_models, null, 0, @splat(0), &random);
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
    var random: libcmt.Rand = .{};
    const all = try create.Objects.create(std.testing.allocator, &random);
    defer all.destroy();
    var tables = create.testing.tables();
    const index = try create.createObject(all, &tables, create.testing.no_models, null, 0, @splat(0), &random);
    const slot = &all.slots[index];

    _ = steer(slot, .{ 200, 0, 4000 }, 1, 0, .{}, slow_frame);
    const quick = slot.object.yaw_input;
    _ = steer(slot, .{ 200, 0, 4000 }, 1, 0, .{}, slow_frame + 1);
    try std.testing.expectApproxEqAbs(quick * 0.5, slot.object.yaw_input, 1e-6);
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
