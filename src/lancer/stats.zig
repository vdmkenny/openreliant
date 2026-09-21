//! The stat tables the `*STATS.BIN` loaders fill: what the engine keeps of each record, and where
//! each field comes from in `formats/stats.zig`.

const std = @import("std");
const assert = std.debug.assert;

/// How a ship or a missile flies. `ship_flight_stats` holds one per ship, `missile_flight_stats`
/// one per missile; a missile's has only its speed and rates set.
pub const FlightModel = extern struct {
    /// `Ship.max_speed`, or `Missile.speed`.
    max_speed: f32,
    /// `Ship.roll_rate`, or `Missile.turn_rate`.
    roll_rate: f32,
    /// `Ship.pitch_rate`, or `Missile.turn_rate`.
    pitch_rate: f32,
    /// `Ship.yaw_rate`, or `Missile.turn_rate`.
    yaw_rate: f32,
    /// `Ship.inertia`.
    inertia: f32,
    roll_inertia: f32,
    pitch_inertia: f32,
    yaw_inertia: f32,
    /// `max_speed / pitch_rate`, which the ship loader computes after reading the file.
    speed_per_pitch_rate: f32,
    _unknown_24: u32,

    comptime {
        assert(@offsetOf(FlightModel, "inertia") == 0x10);
        assert(@offsetOf(FlightModel, "speed_per_pitch_rate") == 0x20);
        assert(@sizeOf(FlightModel) == 0x28);
    }
};

/// A ship's defences, one per ship in `ship_combat_stats`.
pub const ShipCombat = extern struct {
    /// `Ship.shield_power`, truncated.
    shield_power: i32,
    /// `Ship.armor_class`, truncated.
    armor_class: i32,
    /// `Ship.afterburner_fuel`, truncated.
    afterburner_fuel: i32,
    /// `Ship.shield_recharge`, or 10 in place of zero.
    shield_recharge: f32,
    /// `Ship._unknown_70`.
    _unknown_10: f32,
    /// `Ship._unknown_74`.
    _unknown_14: f32,
    /// `Ship._unknown_78`, truncated.
    _unknown_18: i32,
    _unknown_1c: [5]u32,

    comptime {
        assert(@offsetOf(ShipCombat, "shield_recharge") == 0x0C);
        assert(@sizeOf(ShipCombat) == 0x30);
    }
};

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
