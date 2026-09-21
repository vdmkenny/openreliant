//! `C:\lancer\game\missiles.cpp`: missiles. `stats_load_missiles` (`0x00494BC0`) fills
//! `missile_stats` and `missile_flight_stats` from `missilestats.bin`,
//! [`formats/stats.zig`](../../formats/stats.zig). **Unverified:** the loader lies between
//! `matmanager.cpp`'s code and this file's.

const std = @import("std");
const assert = std.debug.assert;

/// The rest of a missile, one per missile in `missile_stats`. Its speed and turn rate are in
/// `missile_flight_stats`.
pub const Missile = extern struct {
    /// `100 * Missile.flight_time`, truncated.
    flight_time: i32,
    damage: [2]f32,
    /// `Missile._unknown_60`.
    _unknown_0c: f32,
    _unknown_10: u32,
    /// `Missile.lock_time`, truncated: hundredths of a second.
    lock_time: i32,
    /// `Missile._unknown_58`, truncated.
    _unknown_18: i32,
    /// `Missile._unknown_5c`.
    _unknown_1c: f32,
    _unknown_20: [2]u32,

    comptime {
        assert(@offsetOf(Missile, "lock_time") == 0x14);
        assert(@sizeOf(Missile) == 0x28);
    }
};

test {
    std.testing.refAllDecls(@This());
}
