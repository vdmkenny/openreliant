//! Window 2, the missile display: the player's missiles in a ring, a type an entry, round the one
//! armed at six o'clock (`hud_missile_ring`, `0x00501CC8`, and `hud_missile_armed`, `0x005656B0`).
//! `hud_missile_ring_build` (`0x00484060`) builds it from the player's racks as a mission starts and
//! after each re-arm, and each launch counts one off the armed entry (`input.launchMissile`).
//!
//! Not ported: drawing it, and ROTATE MISSILES, which turns it
//! ([#93](https://github.com/vdmkenny/openreliant/issues/93)).

const std = @import("std");
const assert = std.debug.assert;

const gameobj = @import("../gameobj.zig");
const missiles = @import("../missiles.zig");

/// How many entries the ring holds.
pub const max_entries = 10;

/// An entry of the ring (five halfwords).
pub const Entry = extern struct {
    /// Missiles left, or -1 for no entry.
    count: i16 = -1,
    /// Where it stands round the ring, from 0, the armed one at six o'clock.
    place: i16 = 0,
    /// The first of its type's ten shapes in the display's set, one a place: the shape drawn is
    /// this and its place.
    shape: i16 = 0,
    /// Its name's text.
    name: i16 = 0,
    type: missiles.Type = .none,

    comptime {
        assert(@sizeOf(Entry) == 10);
    }
};

/// Each type's first shape and name, for the Screamer to the Hawk (`hud_missile_ring_build`'s own
/// tables); the rest have none.
const shapes = [_]i16{ 0x56, 0x4C, 0x24, 0x42, 0x1A, 0x6A, 0x60, 0x38, 0x2E };
const names = [_]i16{ 0x124, 0x123, 0x121, 0x11E, 0x127, 0x126, 0x125, 0x120, 0x122 };

pub const Ring = struct {
    entries: [max_entries]Entry = @splat(.{}),
    /// The armed entry.
    armed: u16 = 0,
    /// `player_missiles_left` (`0x0052A400`): the entries' counts together, which nothing reads.
    left: i32 = 0,
    /// `0x00569978`: until when Betty says no more that the armed missile has run out, as a launch
    /// is refused for want of a lock.
    empty_warned_until: u32 = 0,

    /// `hud_missile_ring_build`: an entry for each missile type the ship's racks hold, but the fuel
    /// pod, in the order its racks first come, with the missiles of all its racks; the middle entry
    /// armed, those before it round the ring from it one way and those after it the other.
    pub fn build(ring: *Ring, object: *const gameobj.GameObject) void {
        ring.entries = @splat(.{});
        var count: usize = 0;
        for (object.racks[0..@intCast(@max(object.rack_count, 0))]) |rack| {
            if (rack.type == .fuel_pod) continue;
            const left: i16 = @truncate(rack.count);
            for (ring.entries[0..count]) |*entry| {
                if (entry.type == rack.type) {
                    entry.count += left;
                    break;
                }
            } else {
                if (count == max_entries) continue;
                const index = rack.type.index() orelse 0;
                ring.entries[count] = .{
                    .count = left,
                    .place = @intCast(count),
                    .shape = if (index < shapes.len) shapes[index] else 0,
                    .name = if (index < names.len) names[index] else 0,
                    .type = rack.type,
                };
                count += 1;
            }
        }
        ring.armed = @intCast(count / 2);
        for (ring.entries[0..count]) |*entry| entry.place = @intCast(@mod(@as(i16, @intCast(ring.armed)) - entry.place, max_entries));
        ring.left = 0;
        for (ring.entries) |entry| {
            if (entry.count != -1) ring.left += entry.count;
        }
    }

    pub fn armedEntry(ring: *Ring) *Entry {
        return &ring.entries[ring.armed];
    }
};

test "Ring.build" {
    var object = gameobj.testing.object();
    // Screamers on two racks, a fuel pod, a Havoc and a Raptor pod.
    object.rack_count = 5;
    const loadout = [_]struct { missiles.Type, i32 }{ .{ .screamer, 20 }, .{ .fuel_pod, 1 }, .{ .havoc, 1 }, .{ .screamer, 20 }, .{ .raptor, 3 } };
    for (loadout, 0..) |rack, i| object.racks[i] = .{ .type = rack[0], .count = rack[1] };
    var ring: Ring = .{};
    ring.build(&object);
    // One entry a type, their missiles together, the fuel pod left out.
    try std.testing.expectEqual(40, ring.entries[0].count);
    try std.testing.expectEqual(Type.havoc, ring.entries[1].type);
    try std.testing.expectEqual(3, ring.entries[2].count);
    try std.testing.expectEqual(-1, ring.entries[3].count);
    try std.testing.expectEqual(44, ring.left);
    // The middle armed at six o'clock, the one before it next round, the one after it last.
    try std.testing.expectEqual(1, ring.armed);
    try std.testing.expectEqual(0, ring.armedEntry().place);
    try std.testing.expectEqual(1, ring.entries[0].place);
    try std.testing.expectEqual(9, ring.entries[2].place);
    try std.testing.expectEqual(0x24, ring.armedEntry().shape);
    try std.testing.expectEqual(0x121, ring.armedEntry().name);
}

const Type = missiles.Type;
