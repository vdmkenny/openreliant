//! The orders a ship flies by: Do Nothing, Fly, Run Away, Slow Rotate, the Random Spins, Match
//! Speed and Disrupted. [`aigeneric.zig`](aigeneric.zig) runs them, [`ai.zig`](ai.zig) steers for them, and
//! `docs/engine/orders.md` describes what each does.
//!
//! **Unknown:** its source file. The code lies after `aifight.cpp`'s and before `aifuncs.cpp`'s,
//! and no string places it. The orders of the two files around it are their own.

const std = @import("std");
const assert = std.debug.assert;

const shp = @import("../../formats/shp.zig");
const math = @import("../surrender/math.zig");
const Vector = math.Vector;
const ai = @import("ai.zig");
const aigeneric = @import("aigeneric.zig");
const Context = aigeneric.Context;
const create = @import("create.zig");
const gameobj = @import("gameobj.zig");
const objects = @import("objects.zig");
const xtrabits = @import("xtrabits.zig");

/// What Fly keeps in `order_state`: the heading it started with, which it flies along while it has
/// no target to fly to.
pub const FlyState = extern struct {
    _unknown_00: [2]f32,
    heading: shp.Vec3,
    _unknown_14: [0x7C]u8,

    comptime {
        assert(@offsetOf(FlyState, "heading") == 0x8);
        assert(@sizeOf(FlyState) == 0x90);
    }
};

/// How near its target Fly comes before it pops (`0x004DC490` holds its square).
const fly_reach: f32 = 2000;

/// How far along its heading Fly steers at while it has no target.
const fly_ahead: f32 = 20000;

/// How far past the target Run Away puts the point it steers away by.
const run_away_ahead: f32 = 100000;

/// The throttle Run Away flies at.
const run_away_throttle: f32 = 0.5;

/// What Fly and Run Away leave of the throttle while the ship is going round something
/// (`0x004DC408`).
const avoided_throttle: f32 = 0.5;

/// How far a Fly order moves an object that has no flight stats, for each unit of speed and each
/// tick of the frame (`0x004DC3D4`).
const drift_per_tick: f32 = 0.25;

/// The turn Slow Rotate yaws at, and what every Random Spin turns at before its own share
/// (`0x004DC420`).
pub const spin_input: f32 = 0.1;

/// The throttle Fly Ship Backwards flies at, which is reverse thrust.
pub const backwards_throttle: f32 = -0.5;

/// `order_do_nothing` (`0x0040A880`): the update of Do Nothing (0), which lets the ship coast.
pub fn doNothing(ctx: Context, index: u16) void {
    const object = &ctx.world.objects.slots[index].object;
    object.throttle = 0;
    object.yaw_input = 0;
    object.pitch_input = 0;
    object.roll_input = 0;
}

/// `order_fly_init` (`0x0040AC00`): the init of Fly (6), which keeps the heading the ship starts
/// on.
pub fn flyInit(ctx: Context, index: u16) void {
    const slot = &ctx.world.objects.slots[index];
    slot.state.fly.heading = gameobj.vec3(slot.object.nextHeading());
}

/// `order_fly` (`0x0040AC20`): the update of Fly (6). It flies at the speed in the order's data, or
/// at full throttle for none. With a target it flies to it and pops once it is within `fly_reach`;
/// without one it holds the heading it started on, steering at a point `fly_ahead` along it. An
/// object with no flight stats is moved along that heading instead of flown, so that a body which
/// has no flight of its own still travels.
pub fn fly(ctx: Context, index: u16) void {
    const all = ctx.world.objects;
    const slot = &all.slots[index];
    const object = &slot.object;
    const heading = gameobj.vector(slot.state.fly.heading);
    const speed: f32 = @floatFromInt(slot.orders[0].data.fly);
    if (speed == 0) {
        object.throttle = 1;
    } else if (slot.flight) |flight| {
        object.throttle = speed / ai.cruiseSpeed(object, flight, ctx.world.view);
    } else {
        const ticks: f32 = @floatFromInt(ctx.clock.frame_duration);
        const at = object.nextPosition() + heading * @as(Vector, @splat(speed * ticks * drift_per_tick));
        objects.setPosition(object, &slot.drawn, at);
        return;
    }

    const target = slot.orders[0].target.index;
    const flags: ai.Steering = .{ .avoid_near = true, .avoid_ahead = true, .roll_upright = true };
    const avoided = if (target < 0) steer: {
        const at = object.nextPosition() + heading * @as(Vector, @splat(fly_ahead));
        break :steer ai.steer(slot, at, 1, 0, flags, ctx.clock.frame_duration);
    } else steer: {
        const to = all.slots[@intCast(target)].object.nextPosition();
        if (math.lengthSquared(to - object.nextPosition()) < fly_reach * fly_reach) {
            object.throttle = 0;
            object.yaw_input = 0;
            object.pitch_input = 0;
            object.roll_input = 0;
            _ = aigeneric.pop(ctx, index);
            return;
        }
        if (slot.flight == null) return;
        break :steer ai.steer(slot, to, 1, 0, flags, ctx.clock.frame_duration);
    };
    if (avoided) object.throttle *= avoided_throttle;
}

/// `order_run_away` (`0x0040ADE0`): the update of Run Away (7), which flies away from its target at
/// half throttle, steering at a point far beyond itself. It pops once the target's slot holds a
/// stand-in.
pub fn runAway(ctx: Context, index: u16) void {
    const all = ctx.world.objects;
    const slot = &all.slots[index];
    const target = slot.orders[0].target.index;
    if (target < 0 or all.slots[@intCast(target)].object.type == .stand_in) {
        _ = aigeneric.pop(ctx, index);
        return;
    }
    const from = slot.object.nextPosition();
    const away = from - all.slots[@intCast(target)].object.nextPosition();
    const at = from + away * @as(Vector, @splat(run_away_ahead));
    _ = ai.steer(slot, at, 1, 0.1, .{ .avoid_near = true, .avoid_ahead = true }, ctx.clock.frame_duration);
    slot.object.throttle = run_away_throttle;
}

/// `order_slow_rotate` (`0x0040B660`): the update of Slow Rotate (18), which turns the ship on the
/// spot.
pub fn slowRotate(ctx: Context, index: u16) void {
    const object = &ctx.world.objects.slots[index].object;
    object.throttle = 0;
    object.pitch_input = 0;
    object.roll_input = 0;
    object.yaw_input = spin_input;
}

/// How fast a Random Spin tumbles: the share of the turn each input takes at random, on top of
/// `spin_input` (`0x004DC4C0` and the words after it).
pub const Spin = enum(u8) {
    slow = 0,
    medium = 1,
    fast = 2,

    pub fn spread(spin: Spin) f32 {
        return switch (spin) {
            .slow => 0.3,
            .medium => 0.5,
            .fast => 0.9,
        };
    }
};

/// `order_random_spin_slow_init` (`0x0040B6A0`) and its two neighbours: the init of the Random
/// Spins (22 to 24), which set the ship tumbling, each input at random. Their update does nothing,
/// so the ship keeps the tumble.
pub fn randomSpinInit(ctx: Context, index: u16, spin: Spin) void {
    const object = &ctx.world.objects.slots[index].object;
    const spread = spin.spread();
    object.throttle = 0;
    object.pitch_input = xtrabits.objectRandom(object) * spread + spin_input;
    object.roll_input = xtrabits.objectRandom(object) * spread + spin_input;
    object.yaw_input = xtrabits.objectRandom(object) * spread + spin_input;
}

/// `order_match_speed` (`0x0040B9E0`): the update of Match Speed (32), which holds the ship at its
/// target's speed. It pops once the target can no longer be aimed at.
pub fn matchSpeed(ctx: Context, index: u16) void {
    const all = ctx.world.objects;
    const slot = &all.slots[index];
    const target = slot.orders[0].target;
    if (!ai.targetValid(all, target, .{})) {
        _ = aigeneric.pop(ctx, index);
        return;
    }
    const flight = slot.flight orelse return;
    const speed = all.slots[@intCast(target.index)].object.speed;
    slot.object.throttle = speed / ai.cruiseSpeed(&slot.object, flight, ctx.world.view);
}

/// What a Havoc's shockwave leaves in Disrupted's data (`shockwave.Shockwave.strike`): how many
/// ticks the ship is disrupted for, and the push it takes.
pub const DisruptedData = extern struct {
    ticks: i32 align(2),
    push: [3]f32 align(2),

    comptime {
        assert(@sizeOf(DisruptedData) == @sizeOf(aigeneric.Entry.Data));
    }
};

/// What Disrupted keeps in `order_state`: the tick it ends at, where Explode keeps its own.
pub const DisruptedState = extern struct {
    _unknown_00: u32,
    end: i32,
    _unknown_08: [0x88]u8,

    comptime {
        assert(@offsetOf(DisruptedState, "end") == 0x4);
        assert(@sizeOf(DisruptedState) == 0x90);
    }
};

/// How far either way each of a disrupted ship's rates is knocked, in radians a step.
const disrupted_spin: f32 = 0.1;

/// `order_disrupted_init` (`0x0040C140`): the init of Disrupted (114). The ship is left unpowered
/// until the tick its data counts to, takes the push in its data, and has each rate knocked by up
/// to 0.05 either way, at random, which it tumbles by.
///
/// **Quirk:** the push is given in the world's frame and taken in the ship's own
/// (`gameobj.knockLocal`), so the ship is thrown off at a turn from straight away from the blast.
///
/// Not ported: the fifteen electric rays that play over the ship (`erayfx.cpp`,
/// [#213](https://github.com/vdmkenny/openreliant/issues/213)).
pub fn disruptedInit(ctx: Context, index: u16) void {
    const slot = &ctx.world.objects.slots[index];
    const object = &slot.object;
    const data = slot.orders[0].data.disrupted;
    object.flags.unpowered = true;
    slot.state.disrupted.end = data.ticks + ctx.clock.frame_start;
    gameobj.knockLocal(object, data.push, @splat(0));
    const random = ctx.world.random;
    object.yaw_rate += random.centred() * disrupted_spin;
    object.pitch_rate += random.centred() * disrupted_spin;
    object.roll_rate += random.centred() * disrupted_spin;
    object.rotation = math.fromAngles(object.pitch_rate, object.yaw_rate, object.roll_rate);
}

/// `order_disrupted` (`0x0040C370`): the update of Disrupted, which pops past its end.
pub fn disrupted(ctx: Context, index: u16) void {
    if (ctx.world.objects.slots[index].state.disrupted.end < ctx.clock.frame_start) _ = aigeneric.pop(ctx, index);
}

/// `order_disrupted_exit` (`0x0040C390`): the exit of Disrupted, which powers the ship again.
pub fn disruptedExit(ctx: Context, index: u16) void {
    ctx.world.objects.slots[index].object.flags.unpowered = false;
}

test doNothing {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const index = try mission.add(.predator, @splat(0));
    const ctx = mission.orders();

    all.slots[index].object.throttle = 1;
    all.slots[index].object.yaw_input = 1;
    doNothing(ctx, index);
    try std.testing.expectEqual(0, all.slots[index].object.throttle);
    try std.testing.expectEqual(0, all.slots[index].object.yaw_input);
}

test fly {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const ctx = mission.orders();

    const index = try mission.addOther(@splat(0));
    const other = try mission.addOther(.{ 0, 0, 30000 });
    try std.testing.expect(try aigeneric.pushShip(ctx, index, .fly, other, -1));

    // Starting it keeps the heading, and with no speed of its own it flies at full throttle.
    aigeneric.objectOrders(ctx, index);
    try std.testing.expectEqual(1, all.slots[index].state.fly.heading.z);
    try std.testing.expectEqual(1, all.slots[index].object.throttle);
    // It steers at its target, which lies dead ahead, so it holds its course.
    try std.testing.expectApproxEqAbs(0, all.slots[index].object.yaw_input, 1e-6);

    // A speed in its data is a share of the cruise speed, which is 320 for the test's stats.
    all.slots[index].orders[0].data.fly = 160;
    aigeneric.objectOrders(ctx, index);
    try std.testing.expectApproxEqAbs(0.5, all.slots[index].object.throttle, 1e-6);

    // Within reach of the target it stops and pops.
    objects.setPosition(&all.slots[other].object, &all.slots[other].drawn, .{ 0, 0, 1500 });
    aigeneric.objectOrders(ctx, index);
    try std.testing.expectEqual(0, all.slots[index].object.throttle);
    try std.testing.expectEqual(0, all.slots[index].object.order_count);
}

test "Fly without a target holds the heading it started on" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const ctx = mission.orders();

    const index = try mission.addOther(@splat(0));
    const slot = &all.slots[index];
    objects.setOrientation(&slot.object, &slot.drawn, math.rotation(.y, std.math.pi / 2.0));
    try std.testing.expect(try aigeneric.push(ctx, index, .fly, .{ .kind = .ship, .index = -1, .component = -1 }));
    aigeneric.objectOrders(ctx, index);
    try std.testing.expectApproxEqAbs(1, slot.state.fly.heading.x, 1e-6);
    // The heading is where it points, so it steers straight on.
    try std.testing.expectApproxEqAbs(0, slot.object.yaw_input, 1e-6);
    try std.testing.expectEqual(1, slot.object.order_count);
}

test "a ship under a Fly order closes on its target and stops there" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const ctx = mission.orders();

    const index = try mission.addOther(@splat(0));
    const target = try mission.addOther(.{ 8000, 0, 30000 });
    try std.testing.expect(try aigeneric.pushShip(ctx, index, .fly, target, -1));
    const slot = &all.slots[index];
    const to = all.slots[target].object.nextPosition();
    const start = math.distance(gameobj.vector(slot.object.root.position), to);

    // A frame of orders, then the step that moves what they steer, as the loop paces them.
    for (0..2000) |_| {
        mission.clock.frame_duration = 4;
        aigeneric.ordersUpdate(ctx);
        create.objectsUpdate(ctx.world);
        for (all.slots[0..all.count]) |*live| {
            gameobj.updateTree(&live.object.root, null, null);
            live.drawn = .{ .position = gameobj.vector(live.object.root.position), .orientation = live.object.root.orientation };
        }
        if (slot.object.order_count == 0) break;
    }

    // It flew there, and stopped once it arrived: the order popped and the throttle is off.
    const reached = math.distance(gameobj.vector(slot.object.root.position), to);
    try std.testing.expect(reached < start / 10);
    try std.testing.expect(reached < fly_reach);
    try std.testing.expectEqual(0, slot.object.order_count);
    try std.testing.expectEqual(0, slot.object.throttle);
}

test matchSpeed {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const ctx = mission.orders();

    const index = try mission.addOther(@splat(0));
    const other = try mission.addOther(.{ 0, 0, 5000 });
    all.slots[other].object.flags.targetable = true;
    all.slots[other].object.speed = 160;
    try std.testing.expect(try aigeneric.pushShip(ctx, index, .match_speed, other, -1));

    aigeneric.objectOrders(ctx, index);
    try std.testing.expectApproxEqAbs(0.5, all.slots[index].object.throttle, 1e-6);

    // Once the target can no longer be aimed at, it pops.
    all.slots[other].object.flags.exploding = true;
    aigeneric.objectOrders(ctx, index);
    try std.testing.expectEqual(0, all.slots[index].object.order_count);
}

test randomSpinInit {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const ctx = mission.orders();

    const index = try mission.addOther(@splat(0));
    const object = &all.slots[index].object;
    object.throttle = 1;
    randomSpinInit(ctx, index, .fast);
    try std.testing.expectEqual(0, object.throttle);
    for ([_]f32{ object.pitch_input, object.roll_input, object.yaw_input }) |turn| {
        try std.testing.expect(turn >= spin_input and turn <= spin_input + Spin.fast.spread());
    }
    // A slower spin never turns as fast as the fastest can.
    randomSpinInit(ctx, index, .slow);
    try std.testing.expect(object.yaw_input <= spin_input + Spin.slow.spread());
}

test runAway {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const ctx = mission.orders();

    const index = try mission.addOther(@splat(0));
    const other = try mission.addOther(.{ 0, 0, 5000 });
    try std.testing.expect(try aigeneric.pushShip(ctx, index, .run_away, other, -1));

    // The target lies ahead, so it turns away from it and flies at half throttle.
    aigeneric.objectOrders(ctx, index);
    try std.testing.expectEqual(run_away_throttle, all.slots[index].object.throttle);
    try std.testing.expect(@abs(all.slots[index].object.yaw_input) > 0 or @abs(all.slots[index].object.roll_input) > 0);

    // A slot that has gone back to standing in is nothing to run from.
    all.resetSlot(other, &mission.random);
    aigeneric.objectOrders(ctx, index);
    try std.testing.expectEqual(0, all.slots[index].object.order_count);
}
