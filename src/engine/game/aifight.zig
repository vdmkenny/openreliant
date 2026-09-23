//! `C:\lancer\game\aifight.cpp`: the Fight order, which runs one combat maneuver after another
//! against its target, aiming and firing as it goes. [`aidefend.zig`](aidefend.zig) runs the
//! maneuvers.

const std = @import("std");
const assert = std.debug.assert;

const Vec3 = @import("../../formats/shp.zig").Vec3;
const math = @import("../surrender/math.zig");
const Vector = math.Vector;
const ai = @import("ai.zig");
const aidefend = @import("aidefend.zig");
const Mirror = aidefend.Mirror;
const maneuvers = aidefend.maneuvers;
const Maneuver = maneuvers.Maneuver;
const Bearing = maneuvers.Bearing;
const aigeneric = @import("aigeneric.zig");
const Order = @import("ai/orders.zig").Order;
const create = @import("create.zig");
const gameobj = @import("gameobj.zig");
const guns = @import("guns.zig");
const pilots = @import("pilots.zig");
const xtrabits = @import("xtrabits.zig");

/// What the Fight order keeps in its `order_state` (`ai_local` in the developers' asserts).
pub const FightState = extern struct {
    /// Where it aims its guns, moved each update by `aim_velocity`.
    aim: Vec3,
    /// A quarter of the target's velocity when last aimed, per tick.
    aim_velocity: Vec3,
    /// The tick at which the maneuver ends and Fight chooses another.
    maneuver_end: i32,
    /// The tick at which it aims again.
    next_aim: i32,
    /// The tick from which its missile has locked on, which the missiles' code keeps.
    locked_at: i32,
    /// The tick from which `cloak` cloaks the ship.
    cloak_at: i32,
    /// The maneuver running.
    maneuver: Maneuver,
    /// Whether the aim leads the target, as `ai.leadAim` found it could.
    led: bool,
    /// The script line running (`AIFight_line`): `before_first` until the first starts.
    line: u8,
    /// Set while the line's instruction waits.
    waiting: bool,
    /// **Unknown.** In a multiplayer game, set once the choice of maneuver is sent.
    _unknown_2d: u8,
    /// Whether `Cloak` asked for the cloak.
    cloak: bool,
    /// Whether a missile is ready to fire.
    missile_ready: bool,
    /// Which inputs the maneuver mirrors this time.
    mirror: Mirror,
    _unknown_31: [3]u8,
    /// The tick at which the running instruction's time is up.
    timer: i32,
    _unknown_38: u32,
    /// Whether `SetAfterburner` lit the afterburner, which the maneuver keeps burning.
    afterburner: bool,
    _unknown_3d: [3]u8,
    /// The point the ship flies to.
    point: Vec3,
    /// Set once the point is nearly dead ahead: the ship then pitches at its full rate, weaving,
    /// until the point is some 45 degrees off its nose.
    weaving: bool,
    _unknown_4d: u8,
    /// The ship `RunToShip` flies to.
    ship: u16,
    _unknown_50: [0x40]u8,

    /// `line` before a maneuver's first line starts, which the first step onward wraps to 0.
    pub const before_first = 0xFF;

    comptime {
        assert(@offsetOf(FightState, "maneuver_end") == 0x18);
        assert(@offsetOf(FightState, "maneuver") == 0x28);
        assert(@offsetOf(FightState, "line") == 0x2B);
        assert(@offsetOf(FightState, "missile_ready") == 0x2F);
        assert(@offsetOf(FightState, "timer") == 0x34);
        assert(@offsetOf(FightState, "afterburner") == 0x3C);
        assert(@offsetOf(FightState, "point") == 0x40);
        assert(@offsetOf(FightState, "ship") == 0x4E);
        assert(@sizeOf(FightState) == 0x90);
    }
};

/// What the Fight order keeps in its entry's `data`: the maneuver to start next.
pub const FightData = extern struct {
    /// Its length in ticks, or -1 while it is still to be drawn from the maneuver's range.
    ticks: i16,
    /// The ship to run to, for `run_to_ship`.
    ship: u16,
    /// The maneuver's number, or 0xFF while none is chosen.
    maneuver: u8,
    /// Set when a new maneuver has been chosen and has yet to start.
    fresh: bool,
    _unknown_06: [10]u8,

    comptime {
        assert(@sizeOf(FightData) == 16);
    }
};

/// A ship under the Fight order: what the order's routines and its maneuvers work on.
pub const Fighter = struct {
    ctx: aigeneric.Context,
    index: u16,
    slot: *create.Slot,
    state: *FightState,
    pilot: *const pilots.Pilot,

    pub fn of(ctx: aigeneric.Context, index: u16) Fighter {
        const all = ctx.world.objects;
        const slot = &all.slots[index];
        return .{ .ctx = ctx, .index = index, .slot = slot, .state = &slot.state.fight, .pilot = all.pilots.get(slot.object.pilot) };
    }

    pub fn objects(fighter: Fighter) *create.Objects {
        return fighter.ctx.world.objects;
    }

    pub fn now(fighter: Fighter) i32 {
        return fighter.ctx.clock.frame_start;
    }

    pub fn ship(fighter: Fighter) *gameobj.GameObject {
        return &fighter.slot.object;
    }

    /// Where the ship will be at the next step, which the fighting goes by.
    pub fn position(fighter: Fighter) Vector {
        return fighter.ship().nextPosition();
    }

    /// Where the ship's nose will point at the next step.
    pub fn heading(fighter: Fighter) Vector {
        return fighter.ship().nextHeading();
    }

    /// The square of how far `object` will be from the ship at the next step.
    pub fn apartSquared(fighter: Fighter, object: *const gameobj.GameObject) f32 {
        return math.lengthSquared(object.nextPosition() - fighter.position());
    }

    pub fn entry(fighter: Fighter) *aigeneric.Entry {
        return &fighter.slot.orders[0];
    }

    pub fn target(fighter: Fighter) aigeneric.Target {
        return fighter.slot.orders[0].target;
    }

    /// The target's slot. Every routine but `init` runs only once `ai.targetValid` has passed it.
    pub fn enemy(fighter: Fighter) *create.Slot {
        return &fighter.objects().slots[@intCast(fighter.target().index)];
    }

    pub fn enemyPosition(fighter: Fighter) Vector {
        return fighter.enemy().object.nextPosition();
    }

    /// Where the object at the action sphere's centre will be.
    pub fn sphereCentre(fighter: Fighter) Vector {
        const all = fighter.objects();
        return all.slots[all.action_sphere.centre].object.nextPosition();
    }

    /// The part of the target it aims at (`0x004018F0`).
    pub fn aimed(fighter: Fighter) ai.Aimed {
        return ai.aimedAt(fighter.objects(), fighter.target());
    }

    /// `object_cruise_speed` of the ship; nothing for one with no flight stats.
    pub fn cruise(fighter: Fighter) f32 {
        const flight = fighter.slot.flight orelse return 0;
        return ai.cruiseSpeed(fighter.ship(), flight, fighter.ctx.world.view);
    }

    /// Steers at `at` the pilot's way, with its limit and its ease.
    pub fn steer(fighter: Fighter, at: Vector, flags: ai.Steering) void {
        _ = ai.steer(fighter.slot, at, fighter.pilot.turn_limit, fighter.pilot.turn_ease, flags, fighter.ctx.clock.frame_duration);
    }

    /// The ship's own random number from 0 to 1 (`object_random`).
    pub fn random(fighter: Fighter) f32 {
        return xtrabits.objectRandom(fighter.ship());
    }

    /// The ship's own random number from 0 to 32767 (`object_random15`).
    pub fn random15(fighter: Fighter) u15 {
        return xtrabits.objectRandom15(fighter.ship());
    }

    /// A number from `least` up to `most` as the game draws one: `least` plus the ship's random
    /// number modulo the span. Where the span is nothing the game divides by zero; the port takes
    /// `least`.
    pub fn randomBetween(fighter: Fighter, least: i32, most: i32) i32 {
        const drawn: i32 = fighter.random15();
        const span = most - least;
        return if (span == 0) least else least + @rem(drawn, span);
    }

    /// The players' ships still in the action (`GameObject.Flags.outOfAction`).
    pub fn players(fighter: Fighter) Players {
        const all = fighter.objects();
        return .{ .slots = all.slots[0..all.players] };
    }

    /// Whether a player's ship still in the action is within `reach` of the ship.
    pub fn playerWithin(fighter: Fighter, reach: f32) bool {
        var each = fighter.players();
        while (each.next()) |player| {
            if (fighter.apartSquared(player) < reach * reach) return true;
        }
        return false;
    }
};

/// An iterator over the players' ships still in the action (`Fighter.players`).
pub const Players = struct {
    slots: []create.Slot,

    pub fn next(each: *Players) ?*gameobj.GameObject {
        while (each.slots.len > 0) {
            const object = &each.slots[0].object;
            each.slots = each.slots[1..];
            if (!object.flags.outOfAction()) return object;
        }
        return null;
    }
};

/// The order's `init` (`order_fight_init`, `0x0040A4D0`): chooses the first maneuver and draws the
/// wait for the first missile, marks the ship as fighting its target and the target as fought one
/// more time, and forgets what the ship had lately taken.
///
/// Not ported: a multiplayer game's, where the host chooses the maneuvers and the ship starts on
/// 200 ticks of the first ([#55](https://github.com/vdmkenny/openreliant/issues/55)).
pub fn init(ctx: aigeneric.Context, index: u16) void {
    const fighter: Fighter = .of(ctx, index);
    const all = ctx.world.objects;
    // The game takes the target as it comes; the port leaves one past the slots for the update to
    // pop.
    const target = fighter.target().index;
    if (target < 0 or target >= all.count) return;
    choose(fighter);
    drawMissileWait(fighter);
    const ship = fighter.ship();
    ship.fighting = target;
    fighter.enemy().object.fought_by += 1;
    ship.recent_damage = 0;
}

/// The order's update (`order_fight`, `0x0040A5E0`): pops the order once its target can no longer
/// be fought. Otherwise it chooses the next maneuver once this one's time is up, starts a newly
/// chosen one, aims and fires, calls for help and runs the maneuver.
///
/// Not ported: the cloak a maneuver asks for (`fight_update_cloak`, `0x00409EC0`), which cloaks a
/// ship whose model can cloak from `cloak_at` and uncloaks it when the maneuver asks for none
/// ([#89](https://github.com/vdmkenny/openreliant/issues/89)); a multiplayer game's, where the host
/// chooses the maneuvers ([#55](https://github.com/vdmkenny/openreliant/issues/55)).
pub fn update(ctx: aigeneric.Context, index: u16) void {
    const fighter: Fighter = .of(ctx, index);
    if (!ai.targetValid(ctx.world.objects, fighter.target(), .{})) {
        _ = aigeneric.pop(ctx, index);
        return;
    }
    if (fighter.now() > fighter.state.maneuver_end) choose(fighter);
    const data = &fighter.entry().data.fight;
    if (data.fresh) begin(fighter, data);
    aim(fighter);
    callForHelp(fighter);
    aidefend.run(fighter);
}

/// Starts the maneuver `choose` left in the order's data: the state cleared, its first line still
/// to come, a random choice of the inputs it may mirror, and its time counted from now.
fn begin(fighter: Fighter, data: *FightData) void {
    const state = fighter.state;
    state.* = std.mem.zeroes(FightState);
    state.maneuver = @enumFromInt(data.maneuver);
    state.line = FightState.before_first;
    const allowed: Mirror = if (maneuvers.info(state.maneuver)) |info| info.mirror else .{};
    state.mirror = allowed.pick(fighter.random15());
    state.maneuver_end = @as(i32, @as(u16, @bitCast(data.ticks))) + fighter.now();
    state.ship = data.ship;
    data.fresh = false;
}

/// A maneuver `choose` picks, how long for where it says, and the ship it runs to where that is
/// what it does.
const Choice = struct {
    maneuver: Maneuver,
    /// Null to draw it from the maneuver's range.
    ticks: ?i16 = null,
    ship: ?u16 = null,
};

/// Against a target with components, a ship attacks it for this long (`fight_choose_against_
/// massive`, `0x0040A220`); a ship with components attacks as one for this long
/// (`fight_choose_as_massive`, `0x0040A390`); a ship out of the action sphere heads back for this
/// long.
const against_massive: Choice = .{ .maneuver = .attack_massive_object, .ticks = 20000 };
const as_massive: Choice = .{ .maneuver = .attack_medium_fighter, .ticks = 10000 };
const back_to_sphere: Choice = .{ .maneuver = .out_of_action_sphere, .ticks = 500 };

/// `fight_choose_maneuver` (`0x0040A3A0`): the next maneuver, into the order's data for the next
/// update to start. A target with components is attacked as a massive object, and a ship with
/// components attacks as one; between two ships without, a ship strays back to the action sphere
/// where it has left it, and otherwise chooses by where the two are (`byPosition`). Where the
/// choice gives no length, it is drawn from the maneuver's range.
fn choose(fighter: Fighter) void {
    const data = &fighter.entry().data.fight;
    data.fresh = true;
    const choice: Choice = if (fighter.enemy().object.flags.components)
        against_massive
    else if (fighter.ship().flags.components)
        as_massive
    else
        outOfSphere(fighter) orelse byPosition(fighter);
    data.maneuver = @intCast(@intFromEnum(choice.maneuver));
    if (choice.ship) |friend| data.ship = friend;
    data.ticks = choice.ticks orelse drawn: {
        const info = maneuvers.table[@intFromEnum(choice.maneuver)];
        // The game adds in 16 bits.
        break :drawn @truncate(fighter.randomBetween(info.min_ticks, info.max_ticks));
    };
}

/// How far off a ship outside the action sphere its target must be, inside it, for the ship to
/// fight on out there (`0x004DC4F0`, its square), and how near a player's ship keeps it fighting
/// (`0x004DC4EC`, its square).
const far_enemy: f32 = 200000;
const player_near: f32 = 100000;

/// `fight_choose_out_of_sphere` (`0x0040A230`): back to the action sphere, for a ship fighting
/// anything but a player's that has left the sphere. It fights on where its target is far off but
/// inside the sphere, and where a player's ship is near.
fn outOfSphere(fighter: Fighter) ?Choice {
    const all = fighter.objects();
    if (fighter.target().index < all.players) return null;
    const centre = fighter.sphereCentre();
    const reach = all.action_sphere.radius * all.action_sphere.radius;
    if (math.lengthSquared(fighter.position() - centre) < reach) return null;
    const enemy = fighter.enemyPosition();
    if (math.lengthSquared(fighter.position() - enemy) > far_enemy * far_enemy and math.lengthSquared(enemy - centre) < reach) return null;
    if (fighter.playerWithin(player_near)) return null;
    return back_to_sphere;
}

/// The least share of its top speed a target is taken to fly at (`0x004DC3D4`).
const least_pace: f32 = 0.25;

/// How far off a target a pilot pursues it, by skill, before the target's pace scales it
/// (`pursue_distances`, `0x004E193C`). The table holds three; past it the game reads the next
/// data, a string's bytes, as some 1.7e25, so a pilot of any other skill never pursues.
fn pursuit(skill: pilots.Pilot.Skill) f32 {
    return switch (skill) {
        .low => 300000,
        .medium => 200000,
        .high => 100000,
        .other => std.math.inf(f32),
    };
}

/// The cosines at which a direction is ahead of a nose, and behind it: the target from the ship's
/// (`0x004DC408`, `0x004DC41C`) and the ship from the target's (`0x004DC4E8`).
const ahead_cosine: f32 = 0.5;
const behind_cosine: f32 = -0.5;
const seen_behind_cosine: f32 = -0.1;

/// How close the ships are when the ship runs for it (`0x004DC43C`).
const close_quarters: f32 = 10000;

/// One in this many times a ship with its target behind looks for a friendly ship to run to.
const run_odds = 10;

/// `fight_choose_by_position` (`0x0040A000`), between two ships without components: pursuit of a
/// target far off for the pilot's skill; then, with the target behind, one time in `run_odds` a
/// run to a friendly capital ship where there is one; running away at close quarters; and
/// otherwise a random pick among `maneuvers.choices` by where each ship is from the other's nose.
///
/// The game also walks the player's weapons here while the player's guns are damaged, to no
/// effect.
fn byPosition(fighter: Fighter) Choice {
    const enemy = fighter.enemy();
    const toward = fighter.enemyPosition() - fighter.position();
    const apart = math.length(toward);
    const top = if (enemy.flight) |flight| flight.max_speed else 0;
    const pace = @max(enemy.object.speed / top, least_pace);
    if (apart > pace * pursuit(fighter.pilot.skill())) return .{ .maneuver = .attack_pursue };
    const where = bearing(math.dot(toward, fighter.heading()) / apart, behind_cosine);
    const seen = bearing(-math.dot(toward, enemy.object.nextHeading()) / apart, seen_behind_cosine);
    if (where == .behind and fighter.random15() % run_odds == 0) {
        if (shipToRunTo(fighter)) |friend| return .{ .maneuver = .run_to_ship, .ship = friend };
    }
    if (apart < close_quarters) return .{ .maneuver = .defend_runaway };
    const list = maneuvers.choices[@intFromEnum(where)][@intFromEnum(seen)];
    return .{ .maneuver = list[@as(usize, fighter.random15()) % list.len] };
}

comptime {
    for (maneuvers.choices) |row| for (row) |list| assert(list.len > 0);
}

/// Where a direction is from a nose, by the cosine of the angle between them.
fn bearing(cosine: f32, behind: f32) Bearing {
    if (cosine > ahead_cosine) return .ahead;
    return if (cosine <= behind) .behind else .abeam;
}

/// The nearest of the ships a search is offered, as the game's searches keep it: from further than
/// anything is from anything (`9e10`, a square), each nearer one in turn.
const Nearest = struct {
    index: ?u16 = null,
    apart: f32 = 9e10,

    fn offer(nearest: *Nearest, index: usize, apart: f32) void {
        if (apart < nearest.apart) nearest.take(index, apart);
    }

    fn take(nearest: *Nearest, index: usize, apart: f32) void {
        nearest.* = .{ .index = @intCast(index), .apart = apart };
    }
};

/// Whether an object is somewhere a search looks: not a stand-in, exploding or disabled.
fn searchable(flags: gameobj.GameObject.Flags) bool {
    return !(flags.stand_in or flags.exploding or flags.disabled);
}

/// How near the edge of a friendly capital ship counts as having run to it already
/// (`0x004DC494`).
const run_to_berth: f32 = 50000;

/// `fight_find_ship_to_run_to` (`0x00409F00`): the nearest capital or support ship with
/// components on the ship's side, to run to. None where the ship is already near one.
fn shipToRunTo(fighter: Fighter) ?u16 {
    const all = fighter.objects();
    var nearest: Nearest = .{};
    for (all.slots[0..all.count], 0..) |*slot, index| {
        if (!searchable(slot.object.flags) or !slot.object.flags.components) continue;
        if (slot.object.side != fighter.ship().side) continue;
        const combat = slot.combat orelse continue;
        if (combat.class != .capital and combat.class != .support) continue;
        const apart = fighter.apartSquared(&slot.object);
        const berth = slot.object.radius + run_to_berth;
        if (apart < berth * berth) return null;
        nearest.offer(index, apart);
    }
    return nearest.index;
}

/// The share of the target's velocity the aim drifts by (`fight_aim`).
const aim_drift: f32 = 0.25;

/// `fight_aim` (`0x00409BE0`): every `aim_interval` ticks the pilot aims afresh, ahead of the target
/// where it can lead it (`ai.leadAim`) and otherwise at it, and reckons the aim's drift as a quarter
/// of the target's velocity, turned on by half as many of the target's turns. Between times the
/// aim drifts on. Then it fires.
fn aim(fighter: Fighter) void {
    const state = fighter.state;
    const enemy = &fighter.enemy().object;
    if (state.next_aim < fighter.now()) {
        state.next_aim = @as(i32, fighter.pilot.aim_interval) + fighter.now();
        if (ai.leadAim(fighter.objects(), fighter.index, fighter.target(), 1)) |led| {
            state.aim = gameobj.vec3(led);
            state.led = true;
        } else {
            state.led = false;
            state.aim = if (fighter.target().component < 0) enemy.root.next_position else gameobj.vec3(fighter.aimed().position);
        }
        var drift = gameobj.vector(enemy.velocity) * @as(Vector, @splat(aim_drift));
        var turns = @divTrunc(fighter.pilot.aim_interval, 2);
        while (turns > 0) : (turns -= 1) drift = math.transform(enemy.rotation, drift);
        state.aim_velocity = gameobj.vec3(drift);
    }
    const step: f32 = @floatFromInt(fighter.ctx.clock.frame_duration);
    state.aim = gameobj.vec3(gameobj.vector(state.aim) + gameobj.vector(state.aim_velocity) * @as(Vector, @splat(step)));
    fire(fighter);
}

/// The share of a laser cannon's range within which a pilot fires (`0x004DC3D4`).
const fire_range: f32 = 0.25;

/// A friendly ship holds its fire while a player's ship is ahead of it, from nothing up to
/// `in_line_reach` along its nose, within `in_line_spread` of that distance, the player's radius
/// and `in_line_margin` of the line (`0x004DC3D0`, `0x004DC494`, `0x004DC4E4`, `0x004DC4A8`).
const in_line_reach: f32 = 50000;
const in_line_spread: f32 = 0.1;
const in_line_margin: f32 = 500;

/// `fight_fire` (`0x004096B0`): once `pause` has passed since the pilot last looked, it fires for
/// `burst` ticks where the aim point is within `fire_spread` of the target's radius of the line
/// along its nose and the part it aims at is within `fire_range` of a laser cannon's range; a
/// friendly ship holds its fire while a player's ship is in the way. A cloaked ship doesn't fire.
/// Then it times its missiles and countermeasures.
///
/// A cloaked target is fired at only where the ship can see through the cloak (`0x00463BD0`), but
/// the order doesn't keep a cloaked target (`ai.target_barred`), so that doesn't come up here.
///
/// Not ported: the missile racks, and firing the missiles and countermeasures
/// ([#39](https://github.com/vdmkenny/openreliant/issues/39)). No missile is ever ready, so the wait
/// for the next is drawn afresh each update, as the game does for a ship without them.
fn fire(fighter: Fighter) void {
    const ship = fighter.ship();
    if (ship.flags.cloaked) return;
    const all = fighter.objects();
    const timings = fighter.pilot.timings;
    const aimed = fighter.aimed();
    const radius = if (fighter.target().component < 0) fighter.enemy().object.radius else aimed.radius;
    if (fighter.now() > ship.fire_at) {
        const laser = guns.GunType.laser_cannon.stats(&all.gun_stats);
        const range = @as(f32, @floatFromInt(laser.lifetime)) * laser.speed * fire_range;
        if (ai.alongNose(fighter.slot.drawn, gameobj.vector(fighter.state.aim), radius * fighter.pilot.fire_spread) and
            math.distance(fighter.position(), aimed.position) < range and
            !(ship.side == .friendly and playerInLine(fighter)))
        {
            guns.fire(ship, fighter.slot.trigger(fighter.now()), timings.burst);
        }
        ship.fire_at = @as(i32, timings.pause) + fighter.now();
    }
    fighter.state.missile_ready = false;
    drawMissileWait(fighter);
    if (ship.missile_homing == 0) ship.countermeasure_at = @as(i32, timings.countermeasures.least) + fighter.now();
}

/// Whether a player's ship still in the action is in the way of the ship's guns.
fn playerInLine(fighter: Fighter) bool {
    const nose = fighter.heading();
    var each = fighter.players();
    while (each.next()) |player| {
        const toward = player.nextPosition() - fighter.position();
        const along = math.dot(nose, toward);
        if (!(along >= 0 and along <= in_line_reach)) continue;
        const off = math.distance(toward, nose * @as(Vector, @splat(along)));
        if (off < along * in_line_spread + player.radius + in_line_margin) return true;
    }
    return false;
}

/// Draws the wait for the ship's next missile from the pilot's range (`missile_at`).
fn drawMissileWait(fighter: Fighter) void {
    const range = fighter.pilot.timings.missiles;
    fighter.ship().missile_at = fighter.randomBetween(range.least, range.most) + fighter.now();
}

/// The share of its armour class times six a ship must lately have taken from the player to call
/// for help (`0x004DC3F8`), and the share an armour quadrant must be below (`0x004DC408`).
const help_damage: f32 = 0.2;
const help_armor: f32 = 0.5;

/// `fight_call_for_help` (`0x00409D10`): a ship fighting the player that the player has lately hurt
/// badly, with an armour quadrant below half, forgets the damage and sends its nearest wingman
/// (`wingman`) at the player too.
fn callForHelp(fighter: Fighter) void {
    const all = fighter.objects();
    const ship = fighter.ship();
    if (fighter.target().index != all.player) return;
    const combat = fighter.slot.combat orelse return;
    const worth: f32 = @floatFromInt(combat.armor_class * 6);
    if (ship.recent_damage < worth * help_damage) return;
    if (ship.last_attacker != all.player) return;
    for (ship.armor.values()) |armor| {
        if (armor < worth * help_armor) break;
    } else return;
    ship.recent_damage = 0;
    const helper = wingman(fighter) orelse return;
    _ = aigeneric.pushShip(fighter.ctx, helper, .fight, all.player, -1) catch return;
}

/// The wingman `callForHelp` calls: the nearest fighter on the ship's side, not the ship itself nor
/// one told not to be disturbed, that is fighting or milling. The first milling one found takes
/// over from any fighting one found before it, however near; from there the nearest wins.
fn wingman(fighter: Fighter) ?u16 {
    const all = fighter.objects();
    var nearest: Nearest = .{};
    var milling = false;
    for (all.slots[0..all.count], 0..) |*slot, index| {
        if (index == fighter.index) continue;
        if (!searchable(slot.object.flags) or slot.object.flags.do_not_disturb) continue;
        if (slot.object.side != fighter.ship().side) continue;
        const combat = slot.combat orelse continue;
        if (combat.class != .fighter or slot.object.order_count == 0) continue;
        const order = slot.orders[0].order;
        if (order != .fight and order != .mill) continue;
        const apart = fighter.apartSquared(&slot.object);
        if (order == .mill and !milling) {
            milling = true;
            nearest.take(index, apart);
        } else nearest.offer(index, apart);
    }
    return nearest.index;
}

test {
    std.testing.refAllDecls(@This());
}

/// Fixtures for the tests here and in `aidefend.zig`.
pub const testing = struct {
    /// The player's Predator, and a Sabre `apart` ahead of it, facing away, under a Fight order
    /// against it that has yet to start.
    pub fn fighter(mission: *gameobj.testing.Mission, apart: f32) !Fighter {
        const ctx = mission.orders();
        const player = try mission.add(.predator, @splat(0));
        const index = try mission.add(.sabre, .{ 0, 0, apart });
        try std.testing.expect(try aigeneric.pushShip(ctx, index, .fight, player, -1));
        return .of(ctx, index);
    }
};

/// `testing.fighter`, with the order started.
fn testFight(mission: *gameobj.testing.Mission, apart: f32) !Fighter {
    const fighter = try testing.fighter(mission, apart);
    aigeneric.objectOrders(fighter.ctx, fighter.index);
    return fighter;
}

test init {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const fighter = try testFight(&mission, 300000);
    const all = mission.objects;

    // The ship fights the player, who is fought once, and the wait for the first missile is drawn
    // from the pilot's range.
    try std.testing.expectEqual(0, fighter.ship().fighting);
    try std.testing.expectEqual(1, all.slots[0].object.fought_by);
    const missiles = fighter.pilot.timings.missiles;
    try std.testing.expect(fighter.ship().missile_at >= missiles.least and fighter.ship().missile_at < missiles.most);
    // The player is at rest, so taken at a quarter of its top speed, and far off for a pilot of
    // middling skill: the Sabre pursues it for a length drawn from the maneuver's range.
    try std.testing.expectEqual(Maneuver.attack_pursue, fighter.state.maneuver);
    try std.testing.expect(!fighter.entry().data.fight.fresh);
    const info = maneuvers.table[@intFromEnum(Maneuver.attack_pursue)];
    try std.testing.expect(fighter.state.maneuver_end >= info.min_ticks and fighter.state.maneuver_end < info.max_ticks);
}

test choose {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const fighter = try testFight(&mission, 300000);
    const data = &fighter.entry().data.fight;

    // Close in, with the player behind it and no friendly capital ship to run to, it runs.
    fighter.ship().root.next_position = .{ .x = 0, .y = 0, .z = 5000 };
    choose(fighter);
    try std.testing.expect(data.fresh);
    try std.testing.expectEqual(@intFromEnum(Maneuver.defend_runaway), data.maneuver);
    // A target with components is attacked as a massive object, for its fixed time.
    fighter.enemy().object.flags.components = true;
    choose(fighter);
    try std.testing.expectEqual(@intFromEnum(Maneuver.attack_massive_object), data.maneuver);
    try std.testing.expectEqual(against_massive.ticks.?, data.ticks);

    // The next update starts it.
    fighter.state.maneuver_end = -1;
    mission.clock.frame_start = 5;
    update(fighter.ctx, fighter.index);
    try std.testing.expectEqual(Maneuver.attack_massive_object, fighter.state.maneuver);
    try std.testing.expectEqual(20005, fighter.state.maneuver_end);
}

test "a target that can't be fought ends the order" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const fighter = try testFight(&mission, 300000);
    fighter.enemy().object.flags.exploding = true;
    update(fighter.ctx, fighter.index);
    try std.testing.expectEqual(0, fighter.ship().order_count);
}

test bearing {
    try std.testing.expectEqual(Bearing.ahead, bearing(0.6, behind_cosine));
    try std.testing.expectEqual(Bearing.abeam, bearing(0.5, behind_cosine));
    try std.testing.expectEqual(Bearing.behind, bearing(-0.5, behind_cosine));
    try std.testing.expectEqual(Bearing.abeam, bearing(-0.2, behind_cosine));
    try std.testing.expectEqual(Bearing.behind, bearing(-0.2, seen_behind_cosine));
}

test "Fighter.randomBetween" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const fighter = try testFight(&mission, 300000);
    for (0..20) |_| {
        const drawn = fighter.randomBetween(10, 20);
        try std.testing.expect(drawn >= 10 and drawn < 20);
    }
    // No span, where the game would divide by zero.
    try std.testing.expectEqual(7, fighter.randomBetween(7, 7));
}

test playerInLine {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const fighter = try testFight(&mission, 20000);
    const player = &fighter.objects().slots[0].object;

    // The Sabre faces away from the player, so the player is not in its way.
    try std.testing.expect(!playerInLine(fighter));
    // Ahead of it along its nose, it is.
    player.root.next_position = .{ .x = 0, .y = 0, .z = 40000 };
    try std.testing.expect(playerInLine(fighter));
    // Well off the line, or past the reach, it isn't.
    player.root.next_position = .{ .x = 10000, .y = 0, .z = 40000 };
    try std.testing.expect(!playerInLine(fighter));
    player.root.next_position = .{ .x = 0, .y = 0, .z = 80000 };
    try std.testing.expect(!playerInLine(fighter));
}

test callForHelp {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const ctx = mission.orders();
    const fighter = try testFight(&mission, 20000);
    const far = try mission.add(.sabre, .{ 0, 0, 90000 });
    const near = try mission.add(.sabre, .{ 0, 0, 30000 });
    const milling = try mission.add(.sabre, .{ 0, 0, 120000 });
    const none: aigeneric.Target = .none;
    try std.testing.expect(try aigeneric.push(ctx, far, .mill, none));
    try std.testing.expect(try aigeneric.push(ctx, near, .fly, none));
    try std.testing.expect(try aigeneric.push(ctx, milling, .mill, none));

    // Not hurt enough: nobody is called.
    const ship = fighter.ship();
    ship.last_attacker = 0;
    callForHelp(fighter);
    try std.testing.expectEqual(Order.fly, mission.objects.slots[near].orders[0].order);

    // Hurt badly by the player, with a quadrant of armour below half: the first milling Sabre is
    // called, being nearer than the other milling one, and the flying one isn't.
    ship.recent_damage = 100;
    ship.armor.aft = 1;
    callForHelp(fighter);
    try std.testing.expectEqual(0, ship.recent_damage);
    try std.testing.expectEqual(Order.fight, mission.objects.slots[far].orders[0].order);
    try std.testing.expectEqual(Order.mill, mission.objects.slots[milling].orders[0].order);
}

test "a Sabre fights the player" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    var devices: @import("../input.zig").Devices = .{};
    const fighter = try testFight(&mission, 100000);
    const state = fighter.state;

    // A minute of frames: the Sabre closes on the player and goes from one maneuver to another.
    var nearest = std.math.inf(f32);
    var changes: usize = 0;
    var last = state.maneuver;
    for (0..1500) |_| {
        mission.clock.advanceTimer(4);
        _ = mission.clock.runTicks(&devices, mission.world());
        mission.clock.frameBegin();
        @import("main.zig").missionFrame(fighter.ctx, 0);
        nearest = @min(nearest, math.length(fighter.position()));
        if (state.maneuver != last) changes += 1;
        last = state.maneuver;
    }
    try std.testing.expectEqual(1, fighter.ship().order_count);
    try std.testing.expect(nearest < 20000);
    try std.testing.expect(changes > 1);
}
