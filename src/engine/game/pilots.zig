//! `C:\lancer\game\pilots.cpp`: pilots. `stats_load_pilots` (`0x0049CAE0`) fills `pilot_stats` from
//! `pilotstats.bin`, [`formats/stats.zig`](../../formats/stats.zig), and `object_set_pilot`
//! (`0x0049CCE0`) gives an object its pilot. **Unverified:** the two lie between `particles.cpp`'s
//! code and this file's.

const std = @import("std");
const assert = std.debug.assert;

const stats = @import("../../formats/stats.zig");
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

    /// What the loader fills every slot with before it reads the records.
    pub const default: Pilot = .{
        .tier_c_values = .{ stats.tier_c_default[0], stats.tier_c_default[1] },
        .tier_c_count = stats.tier_c_default[2],
        ._unknown_0a = 0,
        .tier_b_value = stats.tier_b_default,
        .tier_a_values = stats.tier_a_default,
        .values = @splat(1),
    };

    /// Which of a record's `values` each of the pilot's takes.
    const value_order = [4]usize{ 2, 1, 3, 0 };

    /// The pilot a record makes of the defaults: each tier a preset where it names one, and the
    /// four values copied through. `tier_c`'s level 2 also writes over the last two of `tier_a`'s.
    fn of(record: stats.Pilot) Pilot {
        var pilot: Pilot = .default;
        for (&pilot.values, value_order) |*value, from| value.* = record.values[from].low;
        if (record.tier_b.index()) |level| pilot.tier_b_value = stats.tier_b_presets[level];
        if (record.tier_a.index()) |level| pilot.tier_a_values = stats.tier_a_presets[level];
        if (record.tier_c.index()) |level| {
            const preset = stats.tier_c_presets[level];
            pilot.tier_c_values = .{ preset[0], preset[1] };
            pilot.tier_c_count = preset[2];
            if (level == 2) pilot.tier_a_values[4..].* = stats.tier_c_level_2_override;
        }
        return pilot;
    }

    /// Its skill, the record's first value (`values[3]`), which the maneuvers read as 0, 1 or 2:
    /// how far off it pursues, how wide a berth it gives what it could hit, whether it lights its
    /// afterburner in an attack. **Unknown:** its name in the game.
    pub fn skill(pilot: *const Pilot) Skill {
        return switch (pilot.values[3]) {
            0 => .low,
            1 => .medium,
            2 => .high,
            else => .other,
        };
    }

    pub const Skill = enum { low, medium, high, other };

    comptime {
        assert(@offsetOf(Pilot, "tier_b_value") == 0x0C);
        assert(@offsetOf(Pilot, "tier_a_values") == 0x10);
        assert(@offsetOf(Pilot, "values") == 0x1C);
        assert(@sizeOf(Pilot) == 0x24);
    }
};

/// `pilot_stats` (`0x0058A968`): every pilot, which `stats_load_pilots` (`0x0049CAE0`) fills:
/// the defaults in every slot, then `pilotstats.bin`'s records in order.
pub const Table = struct {
    pilots: [count]Pilot = @splat(.default),

    pub const count = 194;

    pub fn load(table: *Table, records: []align(1) const stats.Pilot) void {
        for (table.pilots[0..@min(records.len, count)], records[0..@min(records.len, count)]) |*pilot, record| pilot.* = .of(record);
    }

    /// The pilot numbered `pilot`, or the defaults for a number past the table.
    pub fn get(table: *const Table, pilot: i32) *const Pilot {
        if (pilot < 0 or pilot >= count) return &Pilot.default;
        return &table.pilots[@intCast(pilot)];
    }
};

test {
    std.testing.refAllDecls(@This());
}

test Table {
    var record: stats.Pilot = std.mem.zeroes(stats.Pilot);
    record.tier_a = .level_0;
    record.tier_b = @enumFromInt(9);
    record.tier_c = .level_2;
    for (&record.values, 0..) |*value, n| value.* = .{ .low = @intCast(n + 10), .ignored = 0xFFFF };
    var table: Table = .{};
    table.load(&.{record});

    // A preset for each tier named, the last two of tier A from tier C's level 2, tier B left at
    // its default, and the values reordered.
    const pilot = table.get(0);
    try std.testing.expectEqual([6]u16{ 10, 40, 800, 1600, 50, 100 }, pilot.tier_a_values);
    try std.testing.expectEqual(stats.tier_b_default, pilot.tier_b_value);
    try std.testing.expectEqual(25, pilot.tier_c_count);
    try std.testing.expectEqual([4]u16{ 12, 11, 13, 10 }, pilot.values);
    try std.testing.expectEqual(Pilot.Skill.other, pilot.skill());
    // The rest keep the defaults.
    try std.testing.expectEqual(Pilot.default, table.get(1).*);
    try std.testing.expectEqual(Pilot.Skill.medium, table.get(Table.count).skill());
}

/// `object_set_pilot` (`0x0049CCE0`): gives the object pilot `pilot`, a record of `pilot_stats`.
/// The game points the object at the record and at the pilot's entry of a table at `0x005048D8`
/// as well (`GameObject.pilot_stats`, `pilot_record`); the port looks the pilot up by number.
pub fn setPilot(object: *GameObject, pilot: i32) void {
    object.pilot = pilot;
}
