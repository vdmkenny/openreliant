//! `C:\lancer\game\aidefend.cpp`: the combat maneuvers, scripts in the developers' own language
//! that the Fight order runs. [`aidefend/maneuvers.zig`](aidefend/maneuvers.zig) holds the
//! maneuvers, their scripts and the handlers of each opcode;
//! [`aidefend/script.zig`](aidefend/script.zig) compiles the scripts as the payload does.

const std = @import("std");
const assert = std.debug.assert;

const engine = @import("../../engine.zig");
const Pointer = engine.Pointer;

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

test {
    std.testing.refAllDecls(@This());
}
