//! `C:\lancer\game\Create.cpp`: creating live objects. `create_object` (`0x00466C10`) makes an
//! object of a ship type. `stats_load_ships` (`0x00466500`) fills `ship_flight_stats` and
//! `ship_combat_stats` from `shipstats.bin`, [`formats/stats.zig`](../../formats/stats.zig);
//! [`create/models.zig`](create/models.zig) names each ship type's and attachment's models.
//! **Unverified:** the loader and the ship type table lie between `collision.cpp`'s code and data
//! and this file's.

const std = @import("std");
const assert = std.debug.assert;

const engine = @import("../../engine.zig");
const stats = @import("../../formats/stats.zig");
const Pointer = engine.Pointer;

pub const models = @import("create/models.zig");
const objects = @import("objects.zig");

/// The flight stats `stats_load_ships` (`0x00466500`) builds for a ship type: the speed, rates and
/// inertias as the record holds them, and `speed_per_pitch_rate` worked out once the file is read.
pub fn flightModel(ship: stats.Ship) FlightModel {
    return .{
        .max_speed = ship.max_speed,
        .roll_rate = ship.roll_rate,
        .pitch_rate = ship.pitch_rate,
        .yaw_rate = ship.yaw_rate,
        .inertia = ship.inertia,
        .roll_inertia = ship.roll_inertia,
        .pitch_inertia = ship.pitch_inertia,
        .yaw_inertia = ship.yaw_inertia,
        .speed_per_pitch_rate = ship.max_speed / ship.pitch_rate,
        ._unknown_24 = 0,
    };
}

/// A ship's combat stats as `stats_load_ships` (`0x00466500`) keeps them: its figures cut down to
/// whole numbers where the record keeps them so, as the runtime's `__ftol` does, and a
/// `shield_recharge` of zero replaced by `stats.Ship.default_shield_recharge`.
pub fn shipCombat(ship: stats.Ship) ShipCombat {
    return .{
        .shield_power = std.math.lossyCast(i32, ship.shield_power),
        .armor_class = std.math.lossyCast(i32, ship.armor_class),
        .afterburner_fuel = std.math.lossyCast(i32, ship.afterburner_fuel),
        .shield_recharge = if (ship.shield_recharge == 0) stats.Ship.default_shield_recharge else ship.shield_recharge,
        .gun_energy = ship.gun_energy,
        ._unknown_14 = ship._unknown_74,
        ._unknown_18 = std.math.lossyCast(i32, ship._unknown_78),
        ._unknown_1c = @splat(0),
    };
}

/// How far `create_object` has a part's `startup` track move on each simulation step.
const startup_speed: f32 = 4;

/// What `create_object` (`0x00466C10`) starts once it has built the object: each part's
/// `startup` track, from its start, as the track says to play it, at 4 a step.
pub fn startUp(model: *objects.Model) void {
    for (model.parts, 0..) |part, index| {
        if (part.animation.tracks.len > 0) model.play(index, .startup, 0, null, startup_speed);
    }
}

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
    /// `Ship.gun_energy`: the most the guns' charge holds.
    gun_energy: f32,
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

/// An entry of `ship_types`, one for each ship type; [`create/models.zig`](create/models.zig) has the names.
pub const ShipType = extern struct {
    model_name: Pointer(u8),
    schematic_name: Pointer(u8),
    /// Objects of the type, which `create_object` counts up, loading the model for the first.
    objects: u16,
    _unknown_0a: u16,
    /// The model, once loaded.
    model: Pointer(anyopaque),
    /// What its objects keep as `GameObject.type_data`.
    type_data: Pointer(anyopaque),

    comptime {
        assert(@offsetOf(ShipType, "model") == 0x0C);
        assert(@sizeOf(ShipType) == 0x14);
    }
};

/// An entry of `attachment_models`: what attachment points of one kind and id mount, as loaded.
/// [`create/models.zig`](create/models.zig) has the file names.
pub const MountedModel = extern struct {
    model: Pointer(anyopaque),
    /// A second model: the missile, for a missile pod.
    second_model: Pointer(anyopaque),
    /// **Unknown.** 1 unless the loader sets it.
    count: u32,
    sprite: Pointer(anyopaque),

    comptime {
        assert(@sizeOf(MountedModel) == 0x10);
    }
};

test {
    std.testing.refAllDecls(@This());
}
