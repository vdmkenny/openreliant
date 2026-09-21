//! `C:\lancer\game\Ai.cpp`: the order table, every order objects follow.
//! [`ai/orders.zig`](ai/orders.zig) transcribes it. **Unverified:** the table lies in the data
//! before this file's path, which holds this file's data or an earlier file's.

const std = @import("std");
const assert = std.debug.assert;

const engine = @import("../../engine.zig");
const Pointer = engine.Pointer;
const Routine = @import("gameobj.zig").Routine;

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
