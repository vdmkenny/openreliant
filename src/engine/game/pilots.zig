//! `C:\lancer\game\pilots.cpp`: pilots. `stats_load_pilots` (`0x0049CAE0`) fills `pilot_stats` from
//! `pilotstats.bin`, [`formats/stats.zig`](../../formats/stats.zig), and `object_set_pilot`
//! (`0x0049CCE0`) gives an object its pilot. **Unverified:** the two lie between `particles.cpp`'s
//! code and this file's.

const std = @import("std");
const assert = std.debug.assert;

const GameObject = @import("gameobj.zig").GameObject;

/// One pilot of `pilot_stats`. The loader fills every slot with defaults, then applies the
/// records: each tier field sets a group of these, in `formats/stats.zig`'s preset tables.
pub const Pilot = extern struct {
    /// The two floats `Pilot.tier_c` sets.
    tier_c_values: [2]f32,
    /// The 16-bit value `Pilot.tier_c` sets.
    tier_c_count: u16,
    _unknown_0a: u16,
    /// The value `Pilot.tier_b` sets.
    tier_b_value: f32,
    /// The six values `Pilot.tier_a` sets. Level 2 of `tier_c` then replaces the last two.
    tier_a_values: [6]u16,
    /// The low halves of the record's `values`, in the order 2, 1, 3, 0.
    values: [4]u16,

    comptime {
        assert(@offsetOf(Pilot, "tier_b_value") == 0x0C);
        assert(@offsetOf(Pilot, "tier_a_values") == 0x10);
        assert(@offsetOf(Pilot, "values") == 0x1C);
        assert(@sizeOf(Pilot) == 0x24);
    }
};

test {
    std.testing.refAllDecls(@This());
}

/// `object_set_pilot` (`0x0049CCE0`): gives the object pilot `pilot`, a record of `pilot_stats`.
/// The game points the object at the record and at the pilot's entry of a table at `0x005048D8`
/// as well (`GameObject.pilot_stats`, `pilot_record`); the port looks the pilot up by number.
pub fn setPilot(object: *GameObject, pilot: i32) void {
    object.pilot = pilot;
}
