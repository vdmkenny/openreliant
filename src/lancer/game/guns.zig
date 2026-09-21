//! `C:\lancer\game\guns.cpp`: guns. `stats_load_guns` (`0x004788F0`) fills `gun_stats` from
//! `gunstats.bin`, [`formats/stats.zig`](../../formats/stats.zig).

const std = @import("std");
const assert = std.debug.assert;

/// One gun of `gun_stats`.
pub const Gun = extern struct {
    /// `Gun.range`, truncated.
    range: i32,
    /// `Gun._unknown_44`.
    _unknown_04: f32,
    damage: [2]f32,
    /// `100 / Gun.fire_rate`, truncated: the interval between shots.
    refire_interval: i32,
    /// `Gun._unknown_54`, truncated.
    _unknown_14: i32,
    _unknown_18: [5]u32,

    comptime {
        assert(@offsetOf(Gun, "refire_interval") == 0x10);
        assert(@sizeOf(Gun) == 0x2C);
    }
};

test {
    std.testing.refAllDecls(@This());
}
