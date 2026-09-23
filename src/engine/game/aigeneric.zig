//! `C:\lancer\game\aigeneric.cpp`: each object's stack of orders, the current one on top, which the
//! AI, the mission scripts and the player's controls push and pop. [`ai.zig`](ai.zig) has the order
//! table.

const std = @import("std");
const assert = std.debug.assert;

const engine = @import("../../engine.zig");
const Pointer = engine.Pointer;
const dte = @import("../../formats/dte.zig");
const ai = @import("ai.zig");
const aieject = @import("aieject.zig");
const aiexplode = @import("aiexplode.zig");
const aifight = @import("aifight.zig");
const aiorders = @import("aiorders.zig");
const camera = @import("camera.zig");
const create = @import("create.zig");
const gameobj = @import("gameobj.zig");
const input = @import("../input.zig");
const Clock = @import("main.zig").Clock;
const orders = @import("ai/orders.zig");
const Order = orders.Order;

/// Orders an object's stack holds; `order_push` refuses another.
pub const max_stack = 20;

/// Orders from other players an object's queue holds; `order_queue` stops with a fatal error past
/// the last.
pub const max_queued = 20;

/// What an order is aimed at, as the `SetAI` command gives it.
pub const Target = extern struct {
    kind: Kind,
    /// The ship's slot, or the flight group's or squad's index; -1 for none.
    index: i16,
    /// A component of the ship, or -1 for the whole ship.
    component: i16,

    /// An order aimed at nothing, which is how the mission's records leave a target it does not
    /// name.
    pub const none: Target = .{ .kind = .ship, .index = -1, .component = -1 };

    /// The kinds of the mission's object table, as a word.
    pub const Kind = enum(i16) {
        ship = 0,
        flight_group = 1,
        squad = 2,
        _,
    };

    comptime {
        for (std.enums.values(dte.Object.Kind)) |kind| {
            assert(@intFromEnum(@field(Kind, @tagName(kind))) == @intFromEnum(kind));
        }
    }
};

/// An order on an object's stack.
pub const Entry = extern struct {
    order: Order,
    target: Target,
    /// A running count from `0x5185A8` while the byte at `0x5185B1` is set, otherwise zero.
    sequence: i16,
    /// The order's own data, zero when the order is pushed.
    data: Data,

    pub const Data = extern union {
        /// `player_controls` keeps the mouse's stick position in the first two.
        words: [8]i16,
        /// Fight's: the maneuver to start next.
        fight: aifight.FightData,
        /// Fly's: the speed to fly at, or zero for its full throttle, which it reads as a whole
        /// word from the first two. The entries sit two bytes apart, so the word is not aligned.
        fly: i32 align(2),
        /// Explode's and Eject Spin's: what `object_destroyed` was told.
        destroyed: aiexplode.Data,
    };

    comptime {
        assert(@offsetOf(Entry, "target") == 0x2);
        assert(@offsetOf(Entry, "data") == 0xA);
        assert(@sizeOf(Entry) == 0x1A);
    }
};

/// An order from another player in a multiplayer game, waiting for its frame: an entry of an
/// object's queue.
pub const Queued = extern struct {
    entry: Entry,
    _unknown_1a: u16,
    /// **Unknown.** A byte the sender passes to `order_queue`.
    _unknown_1c: u32,
    /// The tick, counted by `mission_ticks`, from which `object_orders` may start it.
    due: i32,

    comptime {
        assert(@offsetOf(Queued, "due") == 0x20);
        assert(@sizeOf(Queued) == 0x24);
    }
};

/// What the current order keeps between updates, zeroed when an order starts; each order uses it
/// its own way.
pub const State = extern union {
    bytes: [0x90]u8,
    fight: aifight.FightState,
    fly: aiorders.FlyState,
    explode: aiexplode.State,
    eject_player: aieject.PlayerState,

    comptime {
        assert(@sizeOf(State) == 0x90);
    }
};

/// What the order routines reach besides the object they run for, which `object_orders` reaches
/// through globals: the world the mission runs in and its clock, with the devices the player's
/// controls read.
pub const Context = struct {
    world: gameobj.World,
    clock: *const Clock,
    /// The keyboard and the joystick, which the Player Control order steers by; null where nothing
    /// reads them, as in a test.
    devices: ?*input.Devices = null,
};

/// The fatal error the game stops with as "Cannot set ai %s on ship %s: Still %s", which a port
/// hands back to its caller instead.
pub const Error = error{OrderConflict};

/// How often `ordersUpdate` clears what each object has lately taken (`recent_damage`), in ticks.
pub const damage_window: u32 = 500;

/// `order_refused` (`0x0040CA00`): whether the ship refuses the order outright. A player's ship,
/// which is one of the slots from the first that belong to players, takes only the orders numbered
/// 100 and up and those the table marks as a player's. An order the table does not hold is refused
/// with them.
pub fn refused(all: *const create.Objects, index: u16, order: Order) bool {
    if (index >= all.players or @intFromEnum(order) > 99) return false;
    const info = orders.info(order) orelse return true;
    return !info.flags.players;
}

/// `order_give_way` (`0x0040CA50`): whether the current order makes way for `order`, or for
/// clearing them all where that is null, running its `exit` as it goes.
///
/// An object that is exploding, whose pilot has ejected, or that is being taken apart takes no
/// order at all. Otherwise the way is clear while it has no order or its order has yet to start,
/// and for a one-shot order, which runs over the top of whatever is there. A started order gives
/// way to Explode, and to any order while its own priority is zero or the new order's is higher.
/// Pushing anything else on it is the game's fatal error.
pub fn giveWay(ctx: Context, index: u16, order: ?Order) Error!bool {
    const all = ctx.world.objects;
    const slot = &all.slots[index];
    const object = &slot.object;
    if (object.flags.exploding or object.flags.ejected or object.flags._unknown_28) return false;
    if (object.order_count == 0 or object.order_starting) return true;
    // Clearing reads the record before the table in the game, which is zero, so it is neither
    // one-shot nor of any priority.
    const pushed = if (order) |wanted| orders.info(wanted) else null;
    if (pushed) |info| if (info.flags.one_shot) return true;
    const running = orders.info(slot.orders[0].order) orelse return true;
    if (order == .explode or running.priority == 0) {
        runExit(ctx, index, running);
        return true;
    }
    const wanted = pushed orelse return error.OrderConflict;
    if (running.priority >= wanted.priority) return error.OrderConflict;
    runExit(ctx, index, running);
    return true;
}

/// `order_push` (`0x0040CC10`): pushes an order aimed at `target` on the object's stack, and
/// whether it took. It takes at once where the current order is the same order aimed the same way.
/// Otherwise the current order must give way, any equal order deeper in the stack is dropped, and
/// the stack must have room. A pushed order starts with its data zeroed, and unless it is one-shot
/// it is marked as starting and the order state is zeroed with it.
///
/// The game allocates the stack and the state with the object's first order; the port keeps both in
/// the slot, so an object always has them.
pub fn push(ctx: Context, index: u16, order: Order, target: Target) Error!bool {
    const all = ctx.world.objects;
    const slot = &all.slots[index];
    const object = &slot.object;
    if (refused(all, index, order)) return false;
    if (object.order_count > 0 and slot.orders[0].order == order and equalTargets(slot.orders[0].target, target)) return true;
    if (!try giveWay(ctx, index, order)) return false;

    // The same order aimed the same way, deeper in the stack, is dropped rather than left to come
    // back once this one is done.
    var deeper: u16 = 1;
    while (deeper < object.order_count) : (deeper += 1) {
        if (slot.orders[deeper].order != order or !equalTargets(slot.orders[deeper].target, target)) continue;
        var from = deeper + 1;
        while (from < object.order_count) : (from += 1) slot.orders[from - 1] = slot.orders[from];
        object.order_count -= 1;
        break;
    }

    if (object.order_count >= max_stack) return false;
    var at: u16 = @intCast(object.order_count);
    while (at > 0) : (at -= 1) slot.orders[at] = slot.orders[at - 1];
    slot.orders[0] = .{ .order = order, .target = target, .sequence = 0, .data = .{ .words = @splat(0) } };
    if (orders.info(order)) |info| if (!info.flags.one_shot) start(slot);
    object.order_count += 1;
    return true;
}

/// The order an object is running, which is the entry on top of its stack; null where it has none.
/// Whoever pushes an order fills in its data through this, as the mission's commands do.
pub fn current(all: *create.Objects, index: u16) ?*Entry {
    const slot = &all.slots[index];
    if (slot.object.order_count == 0) return null;
    return &slot.orders[0];
}

/// `order_push_ship` (`0x0040CBF0`): `push`, aimed at the ship in a slot.
pub fn pushShip(ctx: Context, index: u16, order: Order, ship: u16, component: i16) Error!bool {
    return push(ctx, index, order, .{ .kind = .ship, .index = @intCast(ship), .component = component });
}

/// `order_pop` (`0x0040CE70`): pops the current order, running its `exit` where it has started, and
/// whether there was one. Unless the popped order was one-shot, the order below starts again.
pub fn pop(ctx: Context, index: u16) bool {
    const slot = &ctx.world.objects.slots[index];
    const object = &slot.object;
    if (object.order_count == 0) return false;
    const popped = orders.info(slot.orders[0].order);
    if (popped) |info| if (!object.order_starting) runExit(ctx, index, info);
    var at: u16 = 1;
    while (at < object.order_count) : (at += 1) slot.orders[at - 1] = slot.orders[at];
    object.order_count -= 1;
    if (popped) |info| if (!info.flags.one_shot) start(slot);
    return true;
}

/// `orders_clear` (`0x0040CF50`): drops every order where the current one gives way, running only
/// its `exit`, as the `ClearAI` command does.
pub fn clear(ctx: Context, index: u16) Error!void {
    if (try giveWay(ctx, index, null)) ctx.world.objects.slots[index].object.order_count = 0;
}

/// `orders_pop_all` (`0x0040CF80`): pops every order, running each `exit` in turn.
pub fn popAll(ctx: Context, index: u16) void {
    while (ctx.world.objects.slots[index].object.order_count > 0) {
        if (!pop(ctx, index)) return;
    }
}

/// Marks the current order as one that has yet to start and clears what an order keeps between its
/// updates, which both `order_push` and `order_pop` do.
fn start(slot: *create.Slot) void {
    slot.object.order_starting = true;
    slot.object._unknown_620 = -1;
    slot.state = .{ .bytes = @splat(0) };
}

fn equalTargets(a: Target, b: Target) bool {
    return a.kind == b.kind and a.index == b.index and a.component == b.component;
}

/// `object_orders` (`0x0040C5F0`): runs an object's current order. A `retaliate` order lets the
/// ship turn on whoever is shooting it first. Both burns are cleared, so an order that burns sets
/// them again each time it runs. A one-shot order runs its update, pops itself and lets the order
/// below run in the same pass; any other runs its `init` where it is starting, then its update.
/// Afterwards the object's own state has the last word: engines that are disabled hold the throttle
/// at nothing, an empty tank stops both burns, and only a ship that can reverse keeps reverse
/// thrust.
///
/// Not ported: the orders other players' machines queue, which are multiplayer's
/// ([#55](https://github.com/vdmkenny/openreliant/issues/55)).
pub fn objectOrders(ctx: Context, index: u16) void {
    const slot = &ctx.world.objects.slots[index];
    const object = &slot.object;
    if (object.order_count > 0) {
        if (orders.info(slot.orders[0].order)) |info| if (info.flags.retaliate) retaliate(ctx, index);
    }
    object.afterburner = false;
    object.reverse_thrust = false;
    if (object.order_count > 0) run: {
        const running = orders.info(slot.orders[0].order) orelse break :run;
        if (!running.flags.one_shot) {
            if (object.order_starting) {
                runInit(ctx, index, running);
                object.order_starting = false;
            }
            runUpdate(ctx, index, running);
        } else {
            runUpdate(ctx, index, running);
            const starting = object.order_starting;
            _ = pop(ctx, index);
            object.order_starting = starting;
            objectOrders(ctx, index);
        }
    }
    if (object.flags.engines_disabled) {
        object.throttle = 0;
        object.afterburner = false;
        object.reverse_thrust = false;
    }
    if (object.afterburner_fuel < 1) {
        object.afterburner = false;
        object.reverse_thrust = false;
    }
    if (!object.flags.can_reverse) object.reverse_thrust = false;
}

/// `orders_update` (`0x0040C8F0`): the orders of every object that is not disabled, once a frame,
/// in the loops' order. Every `damage_window` ticks it first clears what each object has lately
/// taken, which is what the ships retaliate by.
///
/// Not ported: the guns' step, which runs for each object after its orders
/// ([#38](https://github.com/vdmkenny/openreliant/issues/38)).
pub fn ordersUpdate(ctx: Context) void {
    const all = ctx.world.objects;
    if (ctx.clock.game_ticks > all.damage_cleared_at) {
        for (all.slots[0..all.count]) |*slot| slot.object.recent_damage = 0;
        all.damage_cleared_at = ctx.clock.game_ticks + damage_window;
    }
    var walk = all.walk();
    while (walk.next()) |index| {
        if (all.slots[index].object.flags.disabled) continue;
        objectOrders(ctx, index);
    }
}

/// What a ship must take, as a share of its armour class, before it turns on its attacker
/// (`0x004DC484` times the six the armour class is worth).
const retaliation_damage: f32 = 6 * 0.7;

/// `order_retaliate` (`0x0040C520`): while the current order lets the ship retaliate, enough damage
/// sends it after whoever last hit it. Both ships must be of the fighter class, the attacker must
/// be on the other side and not already the order's target, and a ship told not to be disturbed
/// stays on its order.
///
/// Nothing sets `recent_damage` yet, so no ship retaliates until damage is ported
/// ([#42](https://github.com/vdmkenny/openreliant/issues/42)).
pub fn retaliate(ctx: Context, index: u16) void {
    const all = ctx.world.objects;
    const slot = &all.slots[index];
    const object = &slot.object;
    const combat = slot.combat orelse return;
    if (combat.class != .fighter) return;
    if (@as(f32, @floatFromInt(combat.armor_class)) * retaliation_damage > object.recent_damage) return;
    if (object.flags.do_not_disturb) return;

    const attacker: Target = .{ .kind = .ship, .index = @intCast(object.last_attacker), .component = -1 };
    if (!ai.targetValid(all, attacker, .{})) return;
    if (attacker.index == slot.orders[0].target.index) return;
    const other = &all.slots[@intCast(attacker.index)];
    if (other.object.side == object.side) return;
    const other_combat = other.combat orelse return;
    if (other_combat.class != .fighter) return;
    _ = pushShip(ctx, index, .fight, @intCast(attacker.index), -1) catch return;
}

/// `order_immediately_set_ship_to_zero_velocity_and_rotation` (`0x0040C4D0`): the update of order
/// 44, which stops the ship dead and pops. **Unverified:** it lies before this file's known code.
pub fn zeroVelocity(ctx: Context, index: u16) void {
    ai.stop(&ctx.world.objects.slots[index].object);
    _ = pop(ctx, index);
}

/// `order_fly_ship_backwards` (`0x0040C4E0`): the update of order 45, which backs the ship up
/// without turning. **Unverified:** it lies before this file's known code.
pub fn flyBackwards(ctx: Context, index: u16) void {
    const object = &ctx.world.objects.slots[index].object;
    object.yaw_input = 0;
    object.pitch_input = 0;
    object.roll_input = 0;
    object.throttle = aiorders.backwards_throttle;
}

/// The `init` of the order, where the port runs it. The orders that aren't ported yet do nothing
/// ([#30](https://github.com/vdmkenny/openreliant/issues/30),
/// [#33](https://github.com/vdmkenny/openreliant/issues/33)).
fn runInit(ctx: Context, index: u16, info: orders.Info) void {
    switch (info.order) {
        .fly => aiorders.flyInit(ctx, index),
        .random_spin_slow => aiorders.randomSpinInit(ctx, index, .slow),
        .random_spin_medium => aiorders.randomSpinInit(ctx, index, .medium),
        .random_spin_fast => aiorders.randomSpinInit(ctx, index, .fast),
        .explode => aiexplode.init(ctx, index),
        .eject_player => aieject.playerInit(ctx, index),
        else => {},
    }
}

/// The `update` of the order, where the port runs it.
fn runUpdate(ctx: Context, index: u16, info: orders.Info) void {
    switch (info.order) {
        .do_nothing => aiorders.doNothing(ctx, index),
        .fly => aiorders.fly(ctx, index),
        .run_away => aiorders.runAway(ctx, index),
        .slow_rotate => aiorders.slowRotate(ctx, index),
        .match_speed => aiorders.matchSpeed(ctx, index),
        .immediately_set_ship_to_zero_velocity_and_rotation => zeroVelocity(ctx, index),
        .fly_ship_backwards => flyBackwards(ctx, index),
        .player_control => playerControl(ctx, index),
        .explode => aiexplode.update(ctx, index),
        .eject_player => aieject.player(ctx, index),
        else => {},
    }
}

/// The `exit` of the order. None of the orders with one is ported yet.
fn runExit(ctx: Context, index: u16, info: orders.Info) void {
    _ = ctx;
    _ = index;
    _ = info;
}

/// The update of Player Control (100), which is the player's own
/// [controls](../input.zig). It needs the devices to read; without them the ship holds what it has.
pub fn playerControl(ctx: Context, index: u16) void {
    const devices = ctx.devices orelse return;
    const slot = &ctx.world.objects.slots[index];
    const combat = slot.combat orelse return;
    input.playerControls(ctx.world.player, devices, &slot.object, combat, ctx.world.view, ctx.clock.frame_duration, .{
        .fitted = slot.guns,
        .groups = slot.gun_groups,
        .frame_start = ctx.clock.frame_start,
    });
}

test {
    std.testing.refAllDecls(@This());
}

test push {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const ctx = mission.orders();
    const index = try mission.addOther(@splat(0));
    const slot = &all.slots[index];

    try std.testing.expect(try push(ctx, index, .slow_rotate, .{ .kind = .ship, .index = -1, .component = -1 }));
    try std.testing.expectEqual(1, slot.object.order_count);
    try std.testing.expectEqual(Order.slow_rotate, slot.orders[0].order);
    try std.testing.expect(slot.object.order_starting);

    // The same order aimed the same way is already what it is doing.
    try std.testing.expect(try push(ctx, index, .slow_rotate, .{ .kind = .ship, .index = -1, .component = -1 }));
    try std.testing.expectEqual(1, slot.object.order_count);

    // Another order goes on top, and the one below waits.
    try std.testing.expect(try push(ctx, index, .do_nothing, .{ .kind = .ship, .index = -1, .component = -1 }));
    try std.testing.expectEqual(2, slot.object.order_count);
    try std.testing.expectEqual(Order.do_nothing, slot.orders[0].order);
    try std.testing.expectEqual(Order.slow_rotate, slot.orders[1].order);

    // Pushing the deeper order again moves it up rather than leaving it twice on the stack.
    try std.testing.expect(try push(ctx, index, .slow_rotate, .{ .kind = .ship, .index = -1, .component = -1 }));
    try std.testing.expectEqual(2, slot.object.order_count);
    try std.testing.expectEqual(Order.slow_rotate, slot.orders[0].order);
    try std.testing.expectEqual(Order.do_nothing, slot.orders[1].order);

    // A full stack takes no more.
    slot.object.order_count = max_stack;
    try std.testing.expect(!try push(ctx, index, .fly, .{ .kind = .ship, .index = -1, .component = -1 }));
}

test "a player's ship refuses the orders that are not its own" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const ctx = mission.orders();
    const index = try mission.add(.predator, @splat(0));
    const none: Target = .none;
    try std.testing.expectEqual(0, index);

    // Slow Rotate is numbered below 100 and is not marked as a player's.
    try std.testing.expect(!try push(ctx, index, .slow_rotate, none));
    // Eject is marked as one, and Player Control is numbered above 100.
    try std.testing.expect(try push(ctx, index, .eject, none));
    try std.testing.expect(try push(ctx, index, .player_control, none));
    // Another ship takes the orders the player's refuses.
    const other = try mission.addOther(@splat(0));
    try std.testing.expect(try push(ctx, other, .slow_rotate, none));
}

test pop {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const ctx = mission.orders();
    const index = try mission.addOther(@splat(0));
    const slot = &all.slots[index];
    const none: Target = .none;

    try std.testing.expect(!pop(ctx, index));
    try std.testing.expect(try push(ctx, index, .fly, none));
    try std.testing.expect(try push(ctx, index, .player_control, none));
    slot.object.order_starting = false;

    try std.testing.expect(pop(ctx, index));
    try std.testing.expectEqual(1, slot.object.order_count);
    // The order below starts again, with the state it kept cleared.
    try std.testing.expect(slot.object.order_starting);
    try std.testing.expectEqual(Order.fly, slot.orders[0].order);

    popAll(ctx, index);
    try std.testing.expectEqual(0, slot.object.order_count);
}

test giveWay {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const ctx = mission.orders();
    const index = try mission.addOther(@splat(0));
    const slot = &all.slots[index];
    const none: Target = .none;

    // Eject has priority 98: once it has started, an ordinary order cannot push it aside.
    try std.testing.expect(try push(ctx, index, .eject, none));
    slot.object.order_starting = false;
    try std.testing.expectError(error.OrderConflict, push(ctx, index, .fly, none));
    try std.testing.expectError(error.OrderConflict, clear(ctx, index));
    // Explode, at 99, does.
    try std.testing.expect(try push(ctx, index, .explode, none));

    // An object that is being taken apart takes no order at all.
    slot.object.flags.exploding = true;
    try std.testing.expect(!try push(ctx, index, .fly, none));
}

test objectOrders {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const ctx = mission.orders();
    const index = try mission.addOther(@splat(0));
    const slot = &all.slots[index];
    const none: Target = .none;

    // Order 44 stops the ship and pops itself, leaving the order below to run the next time round.
    try std.testing.expect(try push(ctx, index, .slow_rotate, none));
    try std.testing.expect(try push(ctx, index, .immediately_set_ship_to_zero_velocity_and_rotation, none));
    slot.object.velocity = .{ .x = 0, .y = 0, .z = 100 };
    objectOrders(ctx, index);
    try std.testing.expectEqual(0, slot.object.velocity.z);
    try std.testing.expectEqual(1, slot.object.order_count);
    try std.testing.expectEqual(0, slot.object.yaw_input);
    objectOrders(ctx, index);
    try std.testing.expectEqual(aiorders.spin_input, slot.object.yaw_input);

    // A one-shot order runs, pops, and the order below runs in the same pass. Toggle Cloak's own
    // update isn't ported, so nothing else comes of it.
    slot.object.yaw_input = 0;
    try std.testing.expect(try push(ctx, index, .toggle_cloak, none));
    objectOrders(ctx, index);
    try std.testing.expectEqual(1, slot.object.order_count);
    try std.testing.expectEqual(aiorders.spin_input, slot.object.yaw_input);

    // Both burns are cleared before the order runs, and neither lasts without fuel.
    slot.object.afterburner = true;
    slot.object.afterburner_fuel = 0;
    objectOrders(ctx, index);
    try std.testing.expect(!slot.object.afterburner);

    // Disabled engines hold the throttle at nothing.
    try std.testing.expect(try push(ctx, index, .fly, none));
    slot.object.flags.engines_disabled = true;
    objectOrders(ctx, index);
    try std.testing.expectEqual(0, slot.object.throttle);
}

test ordersUpdate {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const ctx = mission.orders();
    const none: Target = .none;
    // The player's slot comes first, then three ships that all turn on the spot.
    for (0..4) |_| _ = try mission.add(.predator, @splat(0));
    for (1..4) |index| _ = try push(ctx, @intCast(index), .slow_rotate, none);

    all.slots[2].object.flags.disabled = true;
    for (all.slots[0..4]) |*slot| slot.object.recent_damage = 10;
    mission.clock.game_ticks = 1;
    ordersUpdate(ctx);

    // Every object that is not disabled has run its order, and what they had taken is cleared.
    try std.testing.expectEqual(aiorders.spin_input, all.slots[1].object.yaw_input);
    try std.testing.expectEqual(0, all.slots[2].object.yaw_input);
    try std.testing.expectEqual(aiorders.spin_input, all.slots[3].object.yaw_input);
    try std.testing.expectEqual(0, all.slots[1].object.recent_damage);
    try std.testing.expectEqual(damage_window + 1, all.damage_cleared_at);

    // It clears them once a window, not every frame.
    all.slots[1].object.recent_damage = 10;
    mission.clock.game_ticks = damage_window;
    ordersUpdate(ctx);
    try std.testing.expectEqual(10, all.slots[1].object.recent_damage);
}
