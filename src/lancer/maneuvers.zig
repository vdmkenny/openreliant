//! Combat maneuvers: the scripts the Fight order runs, written in the developers' own small
//! language, and what the payload keeps while it runs them. `src/formats/maneuvers.zig` holds the
//! maneuvers and their scripts, and `src/formats/maneuver_script.zig` compiles them.

const std = @import("std");
const assert = std.debug.assert;

const lancer = @import("../lancer.zig");
const Pointer = lancer.Pointer;
const Vec3 = @import("../formats/shp.zig").Vec3;

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
    yaw: bool,
    pitch: bool,
    roll: bool,
    _unused: u5 = 0,
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
pub const Handler = lancer.Code("bool __fastcall (int slot, FightState *state, ManeuverInstruction *instruction)");

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
    _unknown_20: u32,
    /// The tick from which `cloak` cloaks the ship.
    cloak_at: i32,
    /// The maneuver running.
    maneuver: u16,
    /// **Unknown.** Set when `0x00401280` answers yes as it aims.
    _unknown_2a: u8,
    /// The script line running (`AIFight_line`): 0xFF before the first.
    line: u8,
    /// Set while the line's instruction waits.
    waiting: bool,
    /// **Unknown.** In a multiplayer game, set once the choice of maneuver is sent.
    _unknown_2d: u8,
    /// Whether `Cloak` asked for the cloak.
    cloak: bool,
    _unknown_2f: u8,
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
    /// Set once the point is nearly dead ahead: the ship then pitches at full rate, weaving, until
    /// the point is 45 degrees off its nose.
    weaving: bool,
    _unknown_4d: u8,
    /// The ship `run_to_ship` flies to.
    ship: u16,
    _unknown_50: [0x40]u8,

    comptime {
        assert(@offsetOf(FightState, "maneuver_end") == 0x18);
        assert(@offsetOf(FightState, "maneuver") == 0x28);
        assert(@offsetOf(FightState, "line") == 0x2B);
        assert(@offsetOf(FightState, "timer") == 0x34);
        assert(@offsetOf(FightState, "point") == 0x40);
        assert(@offsetOf(FightState, "ship") == 0x4E);
        assert(@sizeOf(FightState) == 0x90);
    }
};

/// What the Fight order keeps in its entry's `data`: the maneuver to start next.
pub const FightData = extern struct {
    /// Its length in ticks, or -1 to pick from the maneuver's range.
    ticks: i16,
    /// The ship to run to, for "run to ship".
    ship: u16,
    maneuver: u8,
    /// Set when a new maneuver has been chosen and has yet to start.
    fresh: bool,
    _unknown_06: [10]u8,

    comptime {
        assert(@sizeOf(FightData) == 16);
    }
};

test {
    std.testing.refAllDecls(@This());
}
