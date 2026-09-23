//! `C:\lancer\game\gameflow.cpp`: the campaign's flow from one mission to the next.
//! **Unverified:** that `mission_end_record` is this file's: it lies after the file's known code,
//! before `gameobj.cpp`'s.
//!
//! Ported so far: what a mission's end keeps of the pilot's kills (`endMission`).

const std = @import("std");

const input = @import("../input.zig");
const Ending = @import("main.zig").Ending;

/// Whether a mission that ends so keeps the pilot's kills: every ending but the player's ship
/// destroyed or its ejected pilot killed or captured.
pub fn keepsKills(ending: Ending) bool {
    return switch (ending) {
        .destroyed, .captured => false,
        else => true,
    };
}

/// `mission_end_record` (`0x00475A90`) as a mission ends: keeps the pilot's kills, where the
/// ending keeps them (`keepsKills`), for the next mission's start (`winmain.startMission`).
/// **Not ported:** the rest of what it keeps and does, which the campaign needs: promoting the
/// pilot by the kills each rank needs (`rank_kills`, 0, 35, 72, 115, 150, 200, 255, 275 and 300),
/// the medals, the mission's rank and moving `mission_number` on
/// ([#74](https://github.com/vdmkenny/openreliant/issues/74)).
pub fn endMission(player: *input.Player) void {
    if (keepsKills(player.ending)) player.kills.kept = player.kills.count;
}

test endMission {
    var player: input.Player = .{ .kills = .{ .count = 7, .kept = 2 } };
    // Destroyed, or captured after ejecting, the attempt's kills are not kept.
    player.ending = .destroyed;
    endMission(&player);
    try std.testing.expectEqual(2, player.kills.kept);
    player.ending = .captured;
    endMission(&player);
    try std.testing.expectEqual(2, player.kills.kept);
    // Picked up, they are.
    player.ending = .rescued;
    endMission(&player);
    try std.testing.expectEqual(7, player.kills.kept);
}
