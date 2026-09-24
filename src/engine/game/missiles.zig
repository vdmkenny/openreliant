//! `C:\lancer\game\missiles.cpp`: missiles. `stats_load_missiles` (`0x00494BC0`) fills
//! `missile_stats` and `missile_flight_stats` from `missilestats.bin`,
//! [`formats/stats.zig`](../../formats/stats.zig). **Unverified:** the file spans
//! `0x00494BC0`-`0x00498443`, the loader and `order_torpedo` among it, by the strings and the data
//! its code uses; the assertions name the path only from `0x00494CB0` to `0x00496B0E`.
//! [`missiles.md`](../../../docs/engine/missiles.md) describes the file.

const std = @import("std");
const assert = std.debug.assert;

const formats = @import("../../formats/stats.zig");
const create = @import("create.zig");
const FlightModel = create.FlightModel;

/// How many missile types the tables hold: the loader reads no more records than this.
pub const type_count = 11;

/// A missile type: the id of a missile hardpoint (attachment kind 0), the type of a missile's
/// object, and the index into every missile table.
pub const Type = enum(i16) {
    /// A hardpoint that holds none, where a player's loadout leaves it empty.
    none = -1,
    screamer = 0,
    raptor = 1,
    havoc = 2,
    jack_hammer = 3,
    bandit = 4,
    vagabond = 5,
    solomon = 6,
    imp = 7,
    hawk = 8,
    /// Only the torpedoes' trail and sound: nothing launches a missile of this type.
    torpedo = 9,
    fuel_pod = 10,
    _,

    /// Its index into the tables, or null for none or a type past them.
    pub fn index(missile: Type) ?usize {
        const number = @intFromEnum(missile);
        if (number < 0 or number >= type_count) return null;
        return @intCast(number);
    }

    /// The type a hardpoint's id names.
    pub fn of(id: u16) Type {
        return @enumFromInt(@as(i16, @bitCast(id)));
    }
};

/// A missile's order (`missile_orders`, `0x00503D20`): the launch it starts with, the guidance
/// that follows, which `Stats.order` names for each type, or the jettison of what is let fall.
pub const Order = enum(u32) {
    /// From a pod: 50 ticks at full thrust (`missile_order_pod_launch`, `0x00496B20`).
    pod_launch = 0,
    /// From a rail: a drop, a stop, and a burn (`missile_order_rail_launch`, `0x00496B60`).
    rail_launch = 1,
    screamer = 2,
    raptor = 3,
    havoc = 4,
    jack_hammer = 5,
    bandit = 6,
    vagabond = 7,
    solomon = 8,
    imp = 9,
    hawk = 10,
    /// Let fall, and blown up 100 ticks later: an empty pod, or a fuel pod
    /// (`missile_order_jettison`, `0x00498410`).
    jettison = 11,
};

/// A missile type's figures (`missile_stats`, `0x005037A0`, `0x28` bytes a type): the
/// executable's own words, and what `stats_load_missiles` reads of `missilestats.bin`.
pub const Stats = extern struct {
    /// 30 for every type. **Unknown:** nothing reads it.
    _unknown_00: f32,
    /// The 3D sound its launch plays, which follows the missile (`sound3d.sounds`); 0 for none.
    launch_sound: i32,
    /// `Missile.flight_time`, in ticks: `100 * ` the file's seconds, truncated.
    flight_time: i32,
    /// What a hit does to a shield, to a hull, and to a component of a ship that lists them.
    shield_damage: f32,
    hull_damage: f32,
    component_damage: f32,
    /// The guidance it flies under once its launch is over.
    order: Order,
    /// `Missile.lock_time`, truncated: the ticks a lock on a target takes.
    lock_time: i32,
    /// `Missile.decoy_chance`, truncated: in percent.
    decoy_chance: i32,
    /// `Missile.lock_range`.
    lock_range: f32,

    comptime {
        assert(@offsetOf(Stats, "flight_time") == 0x08);
        assert(@offsetOf(Stats, "lock_time") == 0x1C);
        assert(@offsetOf(Stats, "lock_range") == 0x24);
        assert(@sizeOf(Stats) == 0x28);
    }
};

/// `missile_stats` and `missile_flight_stats` (`0x005035E8`): every missile type's figures.
pub const Table = struct {
    stats: [type_count]Stats,
    flight: [type_count]FlightModel,

    /// The tables as the executable holds them before `stats_load_missiles` runs.
    pub const initial: Table = built: {
        var table: Table = undefined;
        for (&table.stats, &table.flight, 0..) |*record, *flight, number| {
            const missile: Type = @enumFromInt(number);
            record.* = .{
                ._unknown_00 = 30,
                .launch_sound = switch (missile) {
                    // `MISSILE01` to `MISSILE09`, then `MISSILE10`.
                    .fuel_pod => 0,
                    else => launch_sounds + @as(i32, @intCast(number)),
                },
                .flight_time = switch (missile) {
                    .torpedo, .fuel_pod => 12000,
                    else => 1000,
                },
                .shield_damage = 290,
                .hull_damage = 180,
                .component_damage = 180,
                .order = switch (missile) {
                    .torpedo => .pod_launch,
                    .fuel_pod => .jettison,
                    else => @enumFromInt(number + @intFromEnum(Order.screamer)),
                },
                .lock_time = 200,
                .decoy_chance = 50,
                .lock_range = 50000,
            };
            flight.* = switch (missile) {
                .torpedo => flightOf(50, 0.05),
                .fuel_pod => std.mem.zeroes(FlightModel),
                else => flightOf(300, 0.14),
            };
        }
        break :built table;
    };

    /// The first missile's launch sound: `MISSILE01`.
    const launch_sounds = 15;

    fn flightOf(speed: f32, turn_rate: f32) FlightModel {
        return .{
            .max_speed = speed,
            .roll_rate = turn_rate,
            .pitch_rate = turn_rate,
            .yaw_rate = turn_rate,
            .inertia = 0.84,
            .roll_inertia = 0.71,
            .pitch_inertia = 0.71,
            .yaw_inertia = 0.71,
            .speed_per_pitch_rate = 0,
            ._unknown_24 = 1,
        };
    }

    /// `stats_load_missiles` (`0x00494BC0`): each record of `missilestats.bin` in turn, up to the
    /// last type, keeping in whole numbers what the runtime's `__ftol` cuts down. The flight model
    /// takes the speed, and the turn rate for all three rates.
    pub fn load(table: *Table, file: []align(1) const formats.Missile) void {
        const count = @min(file.len, type_count);
        for (table.stats[0..count], table.flight[0..count], file[0..count]) |*record, *flight, missile| {
            flight.max_speed = missile.speed;
            flight.pitch_rate = missile.turn_rate;
            flight.yaw_rate = missile.turn_rate;
            flight.roll_rate = missile.turn_rate;
            record.flight_time = std.math.lossyCast(i32, missile.flight_time * 100);
            record.shield_damage = missile.damage[0];
            record.hull_damage = missile.damage[1];
            record.component_damage = missile.component_damage;
            record.lock_time = std.math.lossyCast(i32, missile.lock_time);
            record.decoy_chance = std.math.lossyCast(i32, missile.decoy_chance);
            record.lock_range = missile.lock_range;
        }
    }

    /// The figures of `missile`, or null for none or a type past the tables.
    pub fn of(table: *const Table, missile: Type) ?*const Stats {
        return &table.stats[missile.index() orelse return null];
    }
};

test "Table.initial" {
    const table = Table.initial;
    // The executable's own words: the launch sounds, the orders, and the torpedo's flight model.
    try std.testing.expectEqual(15, table.of(.screamer).?.launch_sound);
    try std.testing.expectEqual(24, table.of(.torpedo).?.launch_sound);
    try std.testing.expectEqual(0, table.of(.fuel_pod).?.launch_sound);
    try std.testing.expectEqual(Order.hawk, table.of(.hawk).?.order);
    try std.testing.expectEqual(Order.pod_launch, table.of(.torpedo).?.order);
    try std.testing.expectEqual(Order.jettison, table.of(.fuel_pod).?.order);
    try std.testing.expectEqual(50, table.flight[9].max_speed);
    try std.testing.expectEqual(0.84, table.flight[0].inertia);
    try std.testing.expectEqual(0, table.flight[10].inertia);
    try std.testing.expectEqual(null, table.of(.none));
}

test "Table.load" {
    var table = Table.initial;
    var record = std.mem.zeroes(formats.Missile);
    record.speed = 500;
    record.turn_rate = 0.2;
    record.flight_time = 50.009;
    record.damage = .{ 250, 200 };
    record.lock_time = 300.9;
    record.decoy_chance = 30.5;
    record.lock_range = 160000;
    record.component_damage = 120;
    table.load(&.{ record, record });
    const raptor = table.of(.raptor).?;
    try std.testing.expectEqual(5000, raptor.flight_time);
    try std.testing.expectEqual(300, raptor.lock_time);
    try std.testing.expectEqual(30, raptor.decoy_chance);
    try std.testing.expectEqual(120, raptor.component_damage);
    try std.testing.expectEqual(0.2, table.flight[1].roll_rate);
    // What the file doesn't reach keeps the executable's figures, and its own words stay.
    try std.testing.expectEqual(1000, table.of(.havoc).?.flight_time);
    try std.testing.expectEqual(Order.raptor, raptor.order);
}

test {
    std.testing.refAllDecls(@This());
}
