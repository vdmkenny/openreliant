//! `C:\lancer\game\Ai.cpp`: the order table, every order objects follow.
//! [`ai/orders.zig`](ai/orders.zig) transcribes it. **Unverified:** the table lies in the data
//! before this file's path, which holds this file's data or an earlier file's.

const std = @import("std");
const assert = std.debug.assert;

const engine = @import("../../engine.zig");
const Pointer = engine.Pointer;
const gameobj = @import("gameobj.zig");
const Routine = gameobj.Routine;
const camera = @import("camera.zig");
const create = @import("create.zig");

pub const orders = @import("ai/orders.zig");

/// A record of the order table. `order_groups` points at the records of each hundred order
/// numbers: order `n` is record `n % 100` of group `n / 100`.
pub const Record = extern struct {
    /// Runs before the order's first update. Null for none.
    init: Pointer(Routine),
    /// Runs each time `object_orders` runs the order.
    update: Pointer(Routine),
    /// Runs when the order is popped or replaced after it has started. Null for none.
    exit: Pointer(Routine),
    flags: Flags,
    /// The developers' name for the order, which fatal errors show.
    name: Pointer(u8),
    /// Zero for an order that any other replaces. Otherwise, once it has started, only `explode`, a
    /// one-shot order or an order of higher priority may be pushed on it, and pushing another is a
    /// fatal error.
    priority: i32,

    pub const Flags = packed struct(u32) {
        /// It may be given to a player's ship. A player's ship refuses the other orders numbered
        /// below 100.
        players: bool,
        /// **Unknown.** Bits set on some orders that nothing in the payload tests.
        _unknown_1: u4,
        /// It runs its update once, then pops itself, and the order below carries on without
        /// starting again. Its `init` never runs.
        one_shot: bool,
        /// While it runs, a ship that takes enough damage turns to fight its attacker
        /// (`order_retaliate`).
        retaliate: bool,
        /// While it runs, `avoidance_scan` lists the objects the ship could hit, up to ten of each
        /// of two kinds at `GameObject` offsets `0x6B4` and `0x6E0`, unless the object has
        /// `no_avoidance`; `docs/engine/orders.md` says which.
        avoidance: bool,
        _unknown_8: u2,
        /// While it runs, a multiplayer game sends the ship's steering inputs, throttle, rates and
        /// velocity.
        send_flight: bool,
        _unknown_11: u21,
    };

    comptime {
        assert(@offsetOf(Record, "flags") == 0xC);
        assert(@sizeOf(Record) == 0x18);
    }
};

test {
    std.testing.refAllDecls(@This());
}

/// The view `object_cruise_speed` leaves a ship its undamaged speed in, whatever its armor.
const full_speed_view: camera.View = @enumFromInt(13);

/// `object_cruise_speed` (`0x00403060`), which lies after this file's known code, before
/// `aidefend.cpp`'s: `max_speed` scaled by `speed_factor`, by the share of its
/// engines left, and, unless the camera is in view 13 or the object is invulnerable, by
/// `armor_speed_factor` as well. So losing engines or armor slows a ship.
///
/// The port takes the flight stats and the view rather than reaching them through the object and a
/// global, since `GameObject` holds the binary's own 32-bit pointers.
pub fn cruiseSpeed(object: *const gameobj.GameObject, flight: *const create.FlightModel, view: camera.View) f32 {
    var speed = flight.max_speed * object.speed_factor * object.engines_intact;
    if (view != full_speed_view and object.invulnerable == 0) speed *= object.armor_speed_factor;
    return speed;
}

test cruiseSpeed {
    var object = gameobj.testing.object();
    try std.testing.expectEqual(320, cruiseSpeed(&object, &gameobj.testing.flight, .chase));
    // Losing half its engines and a fifth of its armor slows it.
    object.engines_intact = 0.5;
    object.armor_speed_factor = 0.8;
    try std.testing.expectEqual(128, cruiseSpeed(&object, &gameobj.testing.flight, .chase));
    // The armor tells in every view but 13, and not at all while it is invulnerable.
    try std.testing.expectEqual(160, cruiseSpeed(&object, &gameobj.testing.flight, @enumFromInt(13)));
    object.invulnerable = 1;
    try std.testing.expectEqual(160, cruiseSpeed(&object, &gameobj.testing.flight, .chase));
}
