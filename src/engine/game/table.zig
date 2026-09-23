//! The fixed tables the game keeps its effects in, as the port holds them. Not from any file of
//! the original: its tables find a slot for a new record in one of two ways, which these share.

const std = @import("std");

/// A table of `capacity` records where each new one takes the slot after the last, round the
/// first so many, in the place of whatever was there: the explosions' bits and pieces, and the
/// sparks.
pub fn Ring(comptime T: type, comptime capacity: usize) type {
    return struct {
        slots: [capacity]?T = @splat(null),
        /// The slot the next record takes.
        next: usize = 0,

        const Self = @This();
        pub const len = capacity;

        /// The slot the next record goes in, round the first `used`, which the caller lets go of
        /// and fills. A `used` of none, or more than there are, is taken as all of them.
        pub fn take(ring: *Self, used: usize) *?T {
            const round = if (used == 0 or used > capacity) capacity else used;
            const at = ring.next % round;
            ring.next = (at + 1) % round;
            return &ring.slots[at];
        }
    };
}

/// The first free slot of `slots`, or null where every one is taken: the fireballs and the
/// shockwaves.
pub fn firstFree(comptime T: type, slots: []?T) ?*?T {
    for (slots) |*slot| if (slot.* == null) return slot;
    return null;
}

test Ring {
    var ring: Ring(u8, 4) = .{};
    // Round the first three, the fourth left alone.
    for (0..4) |n| ring.take(3).* = @intCast(n);
    try std.testing.expectEqual([4]?u8{ 3, 1, 2, null }, ring.slots);
    try std.testing.expectEqual(1, ring.next);
    // Round all of them once more are used.
    _ = ring.take(4);
    try std.testing.expectEqual(2, ring.next);
}

test firstFree {
    var slots: [3]?u8 = .{ 1, null, null };
    try std.testing.expectEqual(&slots[1], firstFree(u8, &slots).?);
    slots = .{ 1, 2, 3 };
    try std.testing.expectEqual(null, firstFree(u8, &slots));
}
