//! `C:\lancer\game\aifight.cpp`: the Fight order, which runs one combat maneuver after another
//! against its target. [`aidefend.zig`](aidefend.zig) has the maneuvers.

const std = @import("std");
const assert = std.debug.assert;

const Vec3 = @import("../../formats/shp.zig").Vec3;
const Mirror = @import("aidefend.zig").Mirror;

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
