//! `C:\lancer\game\aidefend.cpp`: the combat maneuvers, scripts in the developers' own language
//! that the Fight order runs. [`aidefend/maneuvers.zig`](aidefend/maneuvers.zig) holds the
//! maneuvers, their scripts and the handlers of each opcode;
//! [`aidefend/script.zig`](aidefend/script.zig) compiles the scripts as the payload does.

const std = @import("std");
const assert = std.debug.assert;

const engine = @import("../../engine.zig");
const Pointer = engine.Pointer;
const math = @import("../surrender/math.zig");
const Vector = math.Vector;
const ai = @import("ai.zig");
const aifight = @import("aifight.zig");
const Fighter = aifight.Fighter;
const gameobj = @import("gameobj.zig");

pub const maneuvers = @import("aidefend/maneuvers.zig");
pub const script = @import("aidefend/script.zig");

/// What a compiled instruction does: its first byte.
pub const Opcode = enum(u8) {
    set_yaw = 0,
    set_pitch = 1,
    set_roll = 2,
    set_speed = 3,
    wait = 4,
    goto = 5,
    label = 6,
    set_afterburner = 7,
    runaway = 8,
    attack = 9,
    attack_massive = 10,
    out_of_action_sphere = 11,
    set_mirror = 12,
    @"if" = 13,
    @"else" = 14,
    endif = 15,
    avoid = 16,
    cloak = 17,
    attack_medium_fighter = 18,
    new_attack_run = 19,
    run_to_ship = 20,
    end_script = 21,
};

/// Which of the turning inputs a maneuver may mirror, and which it does once it has chosen.
pub const Mirror = packed struct(u8) {
    yaw: bool = false,
    pitch: bool = false,
    roll: bool = false,
    _unused: u5 = 0,

    pub const all: Mirror = .{ .yaw = true, .pitch = true, .roll = true };

    /// A random choice among the inputs `allowed` may mirror, by the low bits of a ship's random
    /// number.
    pub fn pick(allowed: Mirror, drawn: u15) Mirror {
        return @bitCast(@as(u8, @truncate(drawn)) & @as(u8, @bitCast(allowed)));
    }
};

/// What an `if` asks.
pub const Condition = enum(u8) {
    /// Whether the ship is on course to hit its target.
    going_to_crash = 0,
    _,
};

/// An entry of `maneuvers`.
pub const Maneuver = extern struct {
    /// The inputs the maneuver may mirror: each time it starts, a random choice among them.
    mirror: Mirror,
    _unknown_01: [3]u8,
    script: Pointer(ScriptLine),
    /// The developers' name, such as "loop the loop".
    name: Pointer(u8),
    /// The ticks it runs for, a random number from `min_ticks` to `max_ticks` unless Fight gives
    /// its own.
    min_ticks: u16,
    max_ticks: u16,

    comptime {
        assert(@offsetOf(Maneuver, "script") == 0x4);
        assert(@sizeOf(Maneuver) == 0x10);
    }
};

/// A line of a maneuver's script, which a null `text` ends.
pub const ScriptLine = extern struct {
    text: Pointer(u8),
    /// Its compiled form in `maneuver_code`, which the line gets the first time it runs.
    instruction: Pointer(Instruction),
};

/// What an opcode's `start` and `run` are: code for the ship in a slot running an instruction.
/// True from `start` makes the instruction wait, calling `run` each update until it returns false;
/// false moves on to the next line at once.
pub const Handler = engine.Code("bool __fastcall (int slot, FightState *state, ManeuverInstruction *instruction)");

/// An entry of `maneuver_handlers`, one for each opcode. Null for none.
pub const Handlers = extern struct {
    start: Pointer(Handler),
    run: Pointer(Handler),
};

/// A compiled instruction: byte records packed one after another, as long as their opcode needs.
pub const Instruction = extern union {
    opcode: Opcode,
    /// `set_yaw`, `set_pitch`, `set_roll`, `set_speed`: a value picked from a range.
    range: Range,
    /// `wait`, `runaway`, `attack`, `out_of_action_sphere`, `avoid`, `attack_medium_fighter`,
    /// `attack_massive`, `run_to_ship`, `end_script`: a number of ticks picked from a range, which
    /// the last three leave unset.
    ticks: Ticks,
    /// `set_afterburner`, `cloak`, `new_attack_run`.
    flag: Flag,
    /// `goto`, and `else`, which jumps to its `endif`.
    jump: Jump,
    /// `if`.
    branch: Branch,

    pub const Range = extern struct {
        opcode: Opcode,
        _pad: [3]u8,
        min: f32 align(1),
        max: f32 align(1),
    };

    pub const Ticks = extern struct {
        opcode: Opcode,
        _pad: u8,
        min: u16 align(1),
        max: u16 align(1),
    };

    pub const Flag = extern struct {
        opcode: Opcode,
        on: bool,
    };

    pub const Jump = extern struct {
        opcode: Opcode,
        /// The line to go on after: a `goto`'s label, an `else`'s `endif`.
        line: u8,
    };

    pub const Branch = extern struct {
        opcode: Opcode,
        condition: Condition,
        /// The line to go on after when the condition fails: the `if`'s `else` or `endif`.
        otherwise: u8,
    };

    comptime {
        assert(@alignOf(Instruction) == 1);
        assert(@sizeOf(Range) == 12);
        assert(@sizeOf(Ticks) == 6);
        assert(@sizeOf(Branch) == 3);
    }
};

/// The most lines a maneuver starts in one update. A script loop with no command that waits would
/// run on for ever; none of the game's has one, and the port stops at this rather than hang.
const most_lines = 256;

/// `maneuver_run` (`0x004069B0`): runs the Fight order's maneuver for an update. While no line
/// waits it starts the next, each command running at once until one waits; then it runs the
/// waiting one.
///
/// A script that runs off its end would stop the game with a syntax error; the port ends the
/// maneuver there instead, so Fight chooses another.
pub fn run(fighter: Fighter) void {
    const number = @intFromEnum(fighter.state.maneuver);
    if (number < maneuvers.compiled.len) runScript(fighter, maneuvers.compiled[number]);
}

fn runScript(fighter: Fighter, program: []const script.Instruction) void {
    const state = fighter.state;
    if (state.afterburner) fighter.ship().afterburner = true;
    var started: usize = 0;
    while (!state.waiting) : (started += 1) {
        if (started == most_lines) return;
        state.line +%= 1;
        if (state.line >= program.len) return endManeuver(fighter);
        state.waiting = start(fighter, program[state.line]);
    }
    state.waiting = update(fighter, program[state.line]);
}

/// The start of an instruction (`maneuver_handlers`' first routines): true for one that waits.
fn start(fighter: Fighter, instruction: script.Instruction) bool {
    const state = fighter.state;
    switch (instruction) {
        .set_yaw => |range| setInput(fighter, .yaw, range),
        .set_pitch => |range| setInput(fighter, .pitch, range),
        .set_roll => |range| setInput(fighter, .roll, range),
        .set_speed => |range| fighter.ship().throttle = std.math.lerp(range.min, range.max, fighter.random()),
        .wait, .attack, .avoid, .attack_medium_fighter => |ticks| {
            startTimer(fighter, ticks);
            return true;
        },
        .attack_massive => {
            // Its line holds no ticks; the game's compiler leaves the bytes zeroed.
            startTimer(fighter, .{ .min = 0, .max = 0 });
            return true;
        },
        .goto, .@"else" => |line| state.line = line,
        .label, .endif => {},
        .set_afterburner => |on| state.afterburner = on and fighter.pilot.turn_limit == afterburner_limit and fighter.playerWithin(afterburner_reach),
        .runaway => |ticks| {
            startTimer(fighter, ticks);
            const own = fighter.position();
            flyTo(fighter, own + math.normalize(own - fighter.enemyPosition()) * @as(Vector, @splat(runaway_reach)));
            return true;
        },
        .out_of_action_sphere => |ticks| {
            startTimer(fighter, ticks);
            flyTo(fighter, fighter.sphereCentre());
            return true;
        },
        .set_mirror => state.mirror = Mirror.all.pick(fighter.random15()),
        .@"if" => |branch| if (!(branch.condition == .going_to_crash and goingToCrash(fighter))) {
            state.line = branch.otherwise;
        },
        .cloak => |on| {
            state.cloak = on;
            state.cloak_at = fighter.now() + cloak_delay;
        },
        .new_attack_run => |clear| {
            startAttackRun(fighter);
            if (clear) fighter.ship().fighting = -1;
            return true;
        },
        .run_to_ship => {
            flyTo(fighter, friend(fighter).nextPosition());
            return true;
        },
        .end_script => return true,
    }
    return false;
}

/// Each update of an instruction that waits (`maneuver_handlers`' second routines): true while it
/// still waits.
fn update(fighter: Fighter, instruction: script.Instruction) bool {
    return switch (instruction) {
        .wait => fighter.now() < fighter.state.timer,
        .runaway, .out_of_action_sphere => flyOn(fighter),
        .attack => attack(fighter),
        .attack_massive => attackMassive(fighter),
        .avoid => avoid(fighter),
        .attack_medium_fighter => attackMediumFighter(fighter),
        .new_attack_run => |far| attackRun(fighter, far),
        .run_to_ship => runToShip(fighter),
        .end_script => {
            endManeuver(fighter);
            return true;
        },
        .set_yaw, .set_pitch, .set_roll, .set_speed, .goto, .label, .set_afterburner, .set_mirror, .@"if", .@"else", .endif, .cloak => false,
    };
}

/// `maneuver_start_timer` (`0x00405B20`): the instruction's time is up a random share of its range
/// after its least.
fn startTimer(fighter: Fighter, ticks: script.Ticks) void {
    const spread: f32 = @floatFromInt(@as(i32, ticks.max) - ticks.min);
    fighter.state.timer = @as(i32, ticks.min) + fighter.now() + math.round(fighter.random() * spread);
}

/// Ends the maneuver, its end the tick before, so Fight chooses another.
fn endManeuver(fighter: Fighter) void {
    fighter.state.maneuver_end = fighter.now() - 1;
}

fn timeUp(fighter: Fighter) bool {
    return fighter.state.timer < fighter.now();
}

/// A turning input a script sets.
const Axis = enum {
    yaw,
    pitch,
    roll,

    /// The object's input for the axis (`yaw_input` and so on).
    fn input(axis: Axis, object: *gameobj.GameObject) *f32 {
        return switch (axis) {
            inline else => |named| &@field(object, @tagName(named) ++ "_input"),
        };
    }

    /// Whether the maneuver mirrors the axis.
    fn mirrored(axis: Axis, mirror: Mirror) bool {
        return switch (axis) {
            inline else => |named| @field(mirror, @tagName(named)),
        };
    }
};

/// `maneuver_set_yaw_start` (`0x00405960`) and the pitch's and roll's: the input a random share of
/// the range, times the pilot's turn limit, the other way about where the maneuver mirrors it.
fn setInput(fighter: Fighter, axis: Axis, range: script.Range) void {
    const value = std.math.lerp(range.min, range.max, fighter.random()) * fighter.pilot.turn_limit;
    axis.input(fighter.ship()).* = if (axis.mirrored(fighter.state.mirror)) -value else value;
}

/// The point the ship flies to, straight at it again (`maneuver_stop_weaving`, `0x00405C50`).
fn flyTo(fighter: Fighter, point: Vector) void {
    fighter.state.point = gameobj.vec3(point);
    fighter.state.weaving = false;
}

/// `maneuver_fly_to_point` (`0x00405E60`): steers at the point until the time is up.
fn flyOn(fighter: Fighter) bool {
    if (timeUp(fighter)) return false;
    steerToPoint(fighter);
    return true;
}

/// `maneuver_steer_to_point` (`0x00405C60`): at full throttle at the point, and once it is within
/// `weave_start` of the nose, pitching at the pilot's full rate until it is past `weave_end`, so
/// the ship weaves.
///
/// Not ported: with something to avoid, it steers at the point with no pilot's limits and
/// avoidance on ([#140](https://github.com/vdmkenny/openreliant/issues/140)); nothing is avoided
/// yet.
fn steerToPoint(fighter: Fighter) void {
    const state = fighter.state;
    const ship = fighter.ship();
    const point = gameobj.vector(state.point);
    const toward = point - fighter.position();
    const off = math.dot(toward, fighter.heading()) / math.length(toward);
    ship.throttle = 1;
    if (state.weaving) {
        if (off < weave_end) state.weaving = false;
        ship.pitch_input = fighter.pilot.turn_limit;
        ship.yaw_input = 0;
        ship.roll_input = 0;
        return;
    }
    _ = ai.steer(fighter.slot, point, fighter.pilot.turn_limit, 0, .{ .avoid_near = true, .avoid_ahead = true, .pitch_up = true }, fighter.ctx.clock.frame_duration);
    if (off > weave_start) state.weaving = true;
}

/// `maneuver_attack_run` (`0x00405E80`): until the time is up, steers at the aim point at full
/// throttle. Close in, it matches the aim point's speed along its nose instead, and with the
/// target behind where the ship will be in `lookahead` updates, a pilot of the highest skill lights
/// the afterburner. The throttle stays at `least_throttle` or more.
fn attack(fighter: Fighter) bool {
    if (timeUp(fighter)) return false;
    const ship = fighter.ship();
    const apart = math.distance(fighter.position(), fighter.enemyPosition());
    fighter.steer(gameobj.vector(fighter.state.aim), .{ .avoid_near = true, .avoid_ahead = true });
    const ahead = fighter.position() + gameobj.vector(ship.velocity) * @as(Vector, @splat(lookahead));
    const nose = math.forward(ship.root.orientation);
    if (math.dot(nose, fighter.enemyPosition() - ahead) >= 0) {
        ship.throttle = if (apart >= fighter.enemy().object.radius + ship.radius + close_in)
            1
        else
            math.dot(nose, gameobj.vector(fighter.state.aim_velocity)) / fighter.cruise();
    } else if (fighter.pilot.skill() == .high) {
        ship.afterburner = true;
    } else {
        ship.throttle = 1;
    }
    ship.throttle = @max(ship.throttle, least_throttle);
    return true;
}

/// Whether the ship is within `reach_steps` of its cruise speed, both sizes aside, of the part of
/// the target it aims at.
fn closeToPart(fighter: Fighter) bool {
    const aimed = fighter.aimed();
    const reach = fighter.cruise() * reach_steps + fighter.ship().radius + aimed.radius;
    return math.lengthSquared(fighter.position() - aimed.position) < reach * reach;
}

/// `maneuver_attack_massive_run` (`0x00406030`): at full throttle at the aim point until it is
/// close to the part it aims at.
fn attackMassive(fighter: Fighter) bool {
    if (closeToPart(fighter)) return false;
    fighter.ship().throttle = 1;
    fighter.steer(gameobj.vector(fighter.state.aim), .{ .avoid_near = true, .avoid_ahead = true });
    return true;
}

/// `maneuver_avoid_run` (`0x004062D0`): until the time is up, with the target ahead it pitches hard
/// away from it at half throttle; with it behind, it flies straight on at full throttle.
fn avoid(fighter: Fighter) bool {
    if (timeUp(fighter)) return false;
    const ship = fighter.ship();
    const local = math.transformTransposed(ship.root.next_orientation, fighter.enemyPosition() - fighter.position());
    ship.yaw_input = 0;
    ship.pitch_input = 0;
    ship.roll_input = 0;
    if (local[2] < 0) {
        ship.throttle = 1;
        return true;
    }
    ship.pitch_input = if (local[1] >= 0) 1 else -1;
    ship.throttle = 0.5;
    return true;
}

/// `maneuver_attack_medium_fighter_run` (`0x00406400`): until the time is up, at full throttle
/// toward where the target will be, leading it by its velocity less a tenth of the ship's over the
/// time the ship takes to get there. At close quarters with the target off its nose by more than
/// `medium_cone`, straight on instead.
fn attackMediumFighter(fighter: Fighter) bool {
    if (timeUp(fighter)) return false;
    const ship = fighter.ship();
    ship.throttle = 1;
    const toward = fighter.enemyPosition() - fighter.position();
    const apart = math.length(toward);
    const direction = if (apart < close_quarters and math.dot(fighter.heading(), toward) < apart * medium_cone)
        fighter.heading()
    else lead: {
        const closing = gameobj.vector(fighter.enemy().object.velocity) - gameobj.vector(ship.velocity) * @as(Vector, @splat(own_share));
        break :lead math.normalize(closing * @as(Vector, @splat(apart / fighter.cruise())) + toward);
    };
    fighter.steer(fighter.position() + direction * @as(Vector, @splat(medium_reach)), .{ .avoid_near = true });
    return true;
}

/// `maneuver_new_attack_run_start` (`0x004065D0`): the way out from the part of the target it aims
/// at that is clear of the target's hull (`ai.escapeDirection`), in the target's frame.
///
/// Not ported: for a component of the target, the point the model gives the component
/// ([#40](https://github.com/vdmkenny/openreliant/issues/40)); the port finds the way out for it
/// as for any other part.
fn startAttackRun(fighter: Fighter) void {
    const enemy = fighter.enemy();
    const out = ai.escapeDirection(enemy, fighter.aimed().position);
    fighter.state.point = gameobj.vec3(math.transformTransposed(enemy.object.root.next_orientation, out));
}

/// `maneuver_new_attack_run_run` (`0x00406680`): flies to a point out from the part it aims at,
/// along the way out as the part turns (`ai.Aimed.orientation`), `run_out` away, or twice the
/// target's radius for a larger one where `far`. It flies at full throttle on the afterburner
/// while that way lies along its course, at half throttle while it lies against it. Within
/// `run_done` of the point, the run is over and the ship is fighting the target again.
fn attackRun(fighter: Fighter, far: bool) bool {
    const ship = fighter.ship();
    const enemy = &fighter.enemy().object;
    const aimed = fighter.aimed();
    const out = math.transform(aimed.orientation, gameobj.vector(fighter.state.point));
    if (math.dot(out, gameobj.vector(ship.velocity)) >= 0) {
        ship.throttle = 1;
        ship.afterburner = true;
    } else {
        ship.throttle = 0.5;
    }
    const reach = if (far and enemy.radius > run_out) enemy.radius * 2 else run_out;
    const staging = out * @as(Vector, @splat(reach)) + aimed.position;
    if (math.lengthSquared(staging - fighter.position()) < run_done * run_done) {
        ship.fighting = fighter.target().index;
        return false;
    }
    fighter.steer(staging, .{ .avoid_near = true, .avoid_ahead = true });
    return true;
}

/// `maneuver_run_to_ship_run` (`0x00406840`): flies to the friendly ship, its point following it.
/// By a ship with components it is done within `run_to_reach` of the ship's edge; by one without,
/// it matches the ship's speed along its own nose and closes by the distance past `run_to_reach`.
fn runToShip(fighter: Fighter) bool {
    const to = friend(fighter);
    fighter.state.point = to.root.next_position;
    steerToPoint(fighter);
    const apart = math.distance(to.nextPosition(), fighter.position());
    if (to.flags.components) return apart >= to.radius + run_to_reach;
    const ship = fighter.ship();
    const pace = math.dot(fighter.heading(), gameobj.vector(to.velocity)) / fighter.cruise();
    ship.throttle = @max(pace + (apart - run_to_reach) * run_to_closing, least_throttle);
    return true;
}

/// The friendly ship `RunToShip` flies to.
fn friend(fighter: Fighter) *gameobj.GameObject {
    return &fighter.objects().slots[fighter.state.ship].object;
}

/// `If Goingtocrash` (`maneuver_if_start`, `0x00406170`): against a target without components, on
/// course to hit it within `crash_steps` with the berth the pilot's skill gives
/// (`ai.collisionCourse`); against one with components, close to the part it aims at.
fn goingToCrash(fighter: Fighter) bool {
    if (fighter.enemy().object.flags.components) return closeToPart(fighter);
    const berth: f32 = switch (fighter.pilot.skill()) {
        .low => 5000,
        .medium => 3500,
        .high => 2000,
        .other => return false,
    };
    return ai.collisionCourse(fighter.ctx.world, fighter.index, @intCast(fighter.target().index), crash_steps, berth);
}

/// `SetAfterburner(on)` lights the afterburner only for a pilot whose turn limit is this
/// (`0x004DC480`), and only with a player's ship within `afterburner_reach` (`0x004DC47C`, its
/// square). No pilot preset's limit is above 1, so as the game ships it never lights.
const afterburner_limit: f32 = 2;
const afterburner_reach: f32 = 50000;
/// How far away `Runaway` flies.
const runaway_reach: f32 = 1000000;
/// How long after `Cloak` it cloaks.
const cloak_delay = 500;
/// The cosines of the angles off the nose at which a ship flying to a point starts weaving
/// (`0x004DC470`) and steers at the point again (`0x004DC484`).
const weave_start: f32 = 0.9;
const weave_end: f32 = 0.7;
/// `Attack`'s look ahead, in updates of the ship's velocity; how close in, both sizes aside, it
/// matches the aim point's speed (`0x004DC488`); and the least throttle it or `RunToShip` holds
/// (`0x004DC408`).
const lookahead: f32 = 20;
const close_in: f32 = 12000;
const least_throttle: f32 = 0.5;
/// How many updates of cruise speed count as close to a part (`0x004DC48C`).
const reach_steps: f32 = 50;
/// `AttackMediumFighter`: how close counts as close quarters (`0x004DC43C`), the cosine of the cone
/// off the nose the target must be within there (`0x004DC414`), the share of the ship's own
/// velocity the lead takes off, and how far out it steers at.
const close_quarters: f32 = 10000;
const medium_cone: f32 = 0.95;
const own_share: f32 = 0.1;
const medium_reach: f32 = 20000;
/// `NewAttackRun`: how far out it stages (`0x004DC494`), and how close to that point it is done
/// (`0x004DC490`, its square).
const run_out: f32 = 50000;
const run_done: f32 = 2000;
/// `RunToShip`: how close to the ship's edge it is done (`0x004DC46C`), and how much throttle each
/// unit past that adds (`0x004DC498`).
const run_to_reach: f32 = 5000;
const run_to_closing: f32 = 0.0002;
/// `If Goingtocrash`: how many updates ahead a crash is looked for.
const crash_steps: f32 = 100;

test {
    std.testing.refAllDecls(@This());
}

test Mirror {
    try std.testing.expectEqual(Mirror{ .yaw = true, .roll = true }, Mirror.all.pick(0b101));
    // Only what the maneuver allows is mirrored, whatever the number.
    try std.testing.expectEqual(Mirror{ .pitch = true }, (Mirror{ .pitch = true }).pick(0x7FFF));
    try std.testing.expectEqual(Mirror{}, Mirror.all.pick(0b1000));
}

test run {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const fighter = try aifight.testing.fighter(&mission, 50000);
    const state = fighter.state;
    const ship = fighter.ship();
    state.maneuver = .loop_the_loop;
    state.line = aifight.FightState.before_first;
    state.mirror = .{ .pitch = true };

    // Every line up to the first that waits runs at once: the loop's pitch, mirrored, at the
    // pilot's limit, and half throttle. Then it waits on its Wait, the eighth line.
    run(fighter);
    try std.testing.expectEqual(-fighter.pilot.turn_limit, ship.pitch_input);
    try std.testing.expectEqual(0, ship.yaw_input);
    try std.testing.expectEqual(0.5, ship.throttle);
    try std.testing.expect(state.cloak);
    try std.testing.expect(state.waiting);
    try std.testing.expectEqual(7, state.line);
    try std.testing.expectEqual(1000, state.timer);

    // Once the time is up it stops waiting; the next update goes round the loop to the Wait again.
    mission.clock.frame_start = state.timer;
    run(fighter);
    try std.testing.expect(!state.waiting);
    run(fighter);
    try std.testing.expect(state.waiting);
    try std.testing.expectEqual(7, state.line);
    try std.testing.expectEqual(2000, state.timer);
}

test "a script that ends or never waits" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const fighter = try aifight.testing.fighter(&mission, 50000);
    const state = fighter.state;
    mission.clock.frame_start = 100;

    // Running off the end of a script ends the maneuver.
    state.line = aifight.FightState.before_first;
    runScript(fighter, &comptime script.compile(&.{"SetSpeed(1)"}));
    try std.testing.expectEqual(1, fighter.ship().throttle);
    try std.testing.expectEqual(99, state.maneuver_end);

    // A loop with nothing in it that waits is given up on rather than run for ever.
    state.line = aifight.FightState.before_first;
    runScript(fighter, &comptime script.compile(&.{ "loop:", "Goto loop" }));
    try std.testing.expect(!state.waiting);
}

test steerToPoint {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const fighter = try aifight.testing.fighter(&mission, 50000);
    const state = fighter.state;
    const ship = fighter.ship();

    // A point dead ahead: full throttle, and it starts weaving.
    flyTo(fighter, .{ 0, 0, 200000 });
    steerToPoint(fighter);
    try std.testing.expectEqual(1, ship.throttle);
    try std.testing.expect(state.weaving);
    // Weaving, it pitches at the pilot's full rate and nothing else.
    steerToPoint(fighter);
    try std.testing.expectEqual(fighter.pilot.turn_limit, ship.pitch_input);
    try std.testing.expectEqual(0, ship.yaw_input);
    // With the point well off its nose, it stops weaving.
    state.point = .{ .x = 100000, .y = 0, .z = 50000 };
    steerToPoint(fighter);
    try std.testing.expect(!state.weaving);
}

test avoid {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const fighter = try aifight.testing.fighter(&mission, 50000);
    const ship = fighter.ship();
    fighter.state.timer = 10;

    // The player is behind the Sabre, which faces away from it: it flies straight on.
    try std.testing.expect(avoid(fighter));
    try std.testing.expectEqual(1, ship.throttle);
    try std.testing.expectEqual(0, ship.pitch_input);
    // Turned about to face the player, it pitches hard away at half throttle.
    ship.root.next_orientation = math.rotation(.y, std.math.pi);
    try std.testing.expect(avoid(fighter));
    try std.testing.expectEqual(0.5, ship.throttle);
    try std.testing.expectEqual(1, ship.pitch_input);
    // Its time up, it is done.
    mission.clock.frame_start = 11;
    try std.testing.expect(!avoid(fighter));
}
