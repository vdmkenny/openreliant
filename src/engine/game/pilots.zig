//! `C:\lancer\game\pilots.cpp`: pilots. `stats_load_pilots` (`0x0049CAE0`) fills `pilot_stats` from
//! `pilotstats.bin`, [`formats/stats.zig`](../../formats/stats.zig), and `object_set_pilot`
//! (`0x0049CCE0`) gives an object its pilot. **Unverified:** the two lie between `particles.cpp`'s
//! code and this file's.

const std = @import("std");
const assert = std.debug.assert;

const stats = @import("../../formats/stats.zig");
const GameObject = @import("gameobj.zig").GameObject;

/// One pilot of `pilot_stats`. The loader fills every slot with defaults, then applies the
/// records: each tier field sets a group of these, in `formats/stats.zig`'s preset tables. The
/// Fight order ([`aifight.zig`](aifight.zig)) and its maneuvers read them.
pub const Pilot = extern struct {
    /// How hard it turns: the most of each turning input it steers with (`Pilot.tier_c`'s first
    /// float, `ai.steer`'s `limit`), which also scales the turns a maneuver sets.
    turn_limit: f32,
    /// How far it lets a turn swing (`tier_c`'s second float, `ai.steer`'s `ease`).
    turn_ease: f32,
    /// The ticks between its aims at its target (`tier_c`'s 16-bit value), which also sets how far
    /// ahead it reckons the target's turn.
    aim_interval: i16,
    _unknown_0a: u16,
    /// How far off the line along its nose the aim point may be for it to fire, in the target's
    /// radii (`Pilot.tier_b`).
    fire_spread: f32,
    /// How it times its guns, missiles and countermeasures (`Pilot.tier_a`).
    timings: Timings,
    /// The low halves of the record's `values`, in the order 2, 1, 3, 0.
    values: [4]u16,

    /// What the loader fills every slot with before it reads the records.
    pub const default: Pilot = .{
        .turn_limit = stats.tier_c_default[0],
        .turn_ease = stats.tier_c_default[1],
        .aim_interval = @bitCast(stats.tier_c_default[2]),
        ._unknown_0a = 0,
        .fire_spread = stats.tier_b_default,
        .timings = @bitCast(stats.tier_a_default),
        .values = @splat(1),
    };

    /// The six values `Pilot.tier_a` sets, in ticks, which the game reads as signed words.
    pub const Timings = extern struct {
        /// How long it holds the trigger once it has its aim.
        burst: i16,
        /// How long after it last had the chance to fire it looks again.
        pause: i16,
        /// The range the wait for its next missile falls in.
        missiles: Range,
        /// The range the wait for its next countermeasure falls in. Level 2 of `tier_c` sets
        /// these.
        countermeasures: Range,
    };

    pub const Range = extern struct {
        least: i16,
        most: i16,
    };

    /// Which of a record's `values` each of the pilot's takes.
    const value_order = [4]usize{ 2, 1, 3, 0 };

    /// The pilot a record makes of the defaults: each tier a preset where it names one, and the
    /// four values copied through. `tier_c`'s level 2 also writes over `tier_a`'s countermeasures.
    fn of(record: stats.Pilot) Pilot {
        var pilot: Pilot = .default;
        for (&pilot.values, value_order) |*value, from| value.* = record.values[from].low;
        if (record.tier_b.index()) |level| pilot.fire_spread = stats.tier_b_presets[level];
        if (record.tier_a.index()) |level| pilot.timings = @bitCast(stats.tier_a_presets[level]);
        if (record.tier_c.index()) |level| {
            const preset = stats.tier_c_presets[level];
            pilot.turn_limit = preset[0];
            pilot.turn_ease = preset[1];
            pilot.aim_interval = @bitCast(preset[2]);
            if (level == 2) pilot.timings.countermeasures = @bitCast(stats.tier_c_level_2_override);
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
        assert(@offsetOf(Pilot, "aim_interval") == 0x08);
        assert(@offsetOf(Pilot, "fire_spread") == 0x0C);
        assert(@offsetOf(Pilot, "timings") == 0x10);
        assert(@sizeOf(Timings) == @sizeOf(@TypeOf(stats.tier_a_default)));
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
        const loaded = @min(records.len, count);
        for (table.pilots[0..loaded], records[0..loaded]) |*pilot, record| pilot.* = .of(record);
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
    try std.testing.expectEqual(Pilot.Timings{
        .burst = 10,
        .pause = 40,
        .missiles = .{ .least = 800, .most = 1600 },
        .countermeasures = .{ .least = 50, .most = 100 },
    }, pilot.timings);
    try std.testing.expectEqual(stats.tier_b_default, pilot.fire_spread);
    try std.testing.expectEqual(25, pilot.aim_interval);
    try std.testing.expectEqual(1, pilot.turn_limit);
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
