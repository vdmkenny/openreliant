//! `C:\lancer\game\aigeneric.cpp`: each object's stack of orders, the current one on top, which the
//! AI, the mission scripts and the player's controls push and pop. [`ai.zig`](ai.zig) has the order
//! table.

const std = @import("std");
const assert = std.debug.assert;

const lancer = @import("../../lancer.zig");
const Pointer = lancer.Pointer;
const dte = @import("../../formats/dte.zig");
const aifight = @import("aifight.zig");
const Order = @import("ai/orders.zig").Order;

/// Orders an object's stack holds; `order_push` refuses another.
pub const max_stack = 20;

/// Orders from other players an object's queue holds; `order_queue` stops with a fatal error past
/// the last.
pub const max_queued = 20;

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
    /// The order's own data, zero when the order is pushed.
    data: Data,

    pub const Data = extern union {
        /// `player_controls` keeps the mouse's stick position in the first two.
        words: [8]i16,
        /// Fight's: the maneuver to start next.
        fight: aifight.FightData,
    };

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
    /// The tick, counted by `mission_ticks`, from which `object_orders` may start it.
    due: i32,

    comptime {
        assert(@offsetOf(Queued, "due") == 0x20);
        assert(@sizeOf(Queued) == 0x24);
    }
};

/// What the current order keeps between updates, zeroed when an order starts; each order uses it
/// its own way.
pub const State = extern union {
    bytes: [0x90]u8,
    fight: aifight.FightState,

    comptime {
        assert(@sizeOf(State) == 0x90);
    }
};

test {
    std.testing.refAllDecls(@This());
}
