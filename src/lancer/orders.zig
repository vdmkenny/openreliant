//! Orders: what each object is doing. An object keeps a stack of orders, the current one on top,
//! which the AI, the mission scripts and the player's controls push and pop, and `object_orders`
//! runs the current one. [`src/formats/orders.zig`](../formats/orders.zig) lists the orders.

const std = @import("std");
const assert = std.debug.assert;

const lancer = @import("../lancer.zig");
const Pointer = lancer.Pointer;
const dte = @import("../formats/dte.zig");
const Order = @import("../formats/orders.zig").Order;

/// An order's `init`, `update` or `exit`.
pub const Routine = @import("game.zig").Routine;

/// Orders an object's stack holds; `order_push` refuses another.
pub const max_stack = 20;

/// Orders from other players an object's queue holds; `order_queue` stops with a fatal error past
/// the last.
pub const max_queued = 20;

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
        /// While it runs, the ship lists the objects near it, up to ten of each of two kinds, at
        /// `GameObject` offsets `0x6B4` and `0x6E0`; `docs/engine/orders.md` says which.
        list_nearby: bool,
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

/// What an order is aimed at, as the `SetAI` command gives it.
pub const Target = extern struct {
    kind: Kind,
    /// The ship's slot, or the flight group's or squad's index; -1 for none.
    index: i16,
    /// A component of the ship, or -1 for the whole ship.
    component: i16,

    /// The kinds of the mission's object table, as a word.
    pub const Kind = enum(i16) {
        ship = 0,
        flight_group = 1,
        squad = 2,
        _,
    };

    comptime {
        for (std.enums.values(dte.Object.Kind)) |kind| {
            assert(@intFromEnum(@field(Kind, @tagName(kind))) == @intFromEnum(kind));
        }
    }
};

/// An order on an object's stack.
pub const Entry = extern struct {
    order: Order,
    target: Target,
    /// A running count from `0x5185A8` while the byte at `0x5185B1` is set, otherwise zero.
    sequence: i16,
    /// The order's own data, zero when the order is pushed. `player_controls` keeps the mouse's
    /// stick position in the first two words.
    data: [8]i16,

    comptime {
        assert(@offsetOf(Entry, "target") == 0x2);
        assert(@offsetOf(Entry, "data") == 0xA);
        assert(@sizeOf(Entry) == 0x1A);
    }
};

/// An order from another player in a multiplayer game, waiting for its frame: an entry of an
/// object's queue.
pub const Queued = extern struct {
    entry: Entry,
    _unknown_1a: u16,
    /// **Unknown.** A byte the sender passes to `order_queue`.
    _unknown_1c: u32,
    /// The frame from which `object_orders` may start it, a count kept at `0x587CC4`.
    due: i32,

    comptime {
        assert(@offsetOf(Queued, "due") == 0x20);
        assert(@sizeOf(Queued) == 0x24);
    }
};

/// What the current order keeps between updates, zeroed when an order starts; each order uses it
/// its own way.
pub const State = extern struct {
    bytes: [0x90]u8,
};

test {
    std.testing.refAllDecls(@This());
}
