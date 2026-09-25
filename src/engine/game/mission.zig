//! `C:\lancer\game\mission.cpp`'s wings: the ships a mission lists in the player's wing, which the
//! wing status window shows.
//!
//! Not ported: listing a mission's flight groups in the wings (`mission_wings_build`,
//! `0x0045AC60`), which needs the mission's ships
//! ([#256](https://github.com/vdmkenny/openreliant/issues/256)), and the second and third wings'
//! lists (`0x00515D7C`, `0x00515D94`), which nothing reads.

const std = @import("std");

pub const bind = @import("mission/bind.zig");
pub const Mission = bind.Mission;

const create = @import("create.zig");
const gameobj = @import("gameobj.zig");

/// How many ships a wing lists.
pub const wing_size = 6;

/// A wing's ships (`player_wing`, `0x00515D88`, for the player's): a slot each, null for none.
pub const WingSlots = [wing_size]?u16;

/// `mission_wings_build`'s listing of a flight group of `ships` in the player's wing: each takes
/// the wing's next slot, from the first, and joins the wing (`GameObject.wing`), and the slot after
/// the last is emptied. A group of more ships than the wing holds lists as many as fit.
///
/// **Fix:** the game empties only the slot after the last, and the slots past it keep the ships of
/// the mission before, which the wing status window shows again where they are in the wing. The
/// port empties every slot first.
pub fn listPlayerWing(all: *create.Objects, ships: []const u16) void {
    all.wing = @splat(null);
    for (all.wing[0..@min(ships.len, wing_size)], ships[0..@min(ships.len, wing_size)]) |*slot, ship| {
        slot.* = ship;
        all.slots[ship].object.wing = .player;
    }
}

test listPlayerWing {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const player = try mission.add(.predator, @splat(0));
    const wingman = try mission.add(.grendel, .{ 1000, 0, 0 });
    const outsider = try mission.add(.sabre, .{ 0, 0, 5000 });

    // The ships listed take the first slots and join the wing; the rest stay out of it.
    all.wing = @splat(outsider);
    listPlayerWing(all, &.{ player, wingman });
    try std.testing.expectEqual(WingSlots{ player, wingman, null, null, null, null }, all.wing);
    try std.testing.expectEqual(.player, all.slots[wingman].object.wing);
    try std.testing.expectEqual(.none, all.slots[outsider].object.wing);

    // More ships than the wing holds list as many as fit.
    listPlayerWing(all, &(.{wingman} ** (wing_size + 1)));
    try std.testing.expectEqual(@as(WingSlots, @splat(wingman)), all.wing);
}

test {
    std.testing.refAllDecls(@This());
}
