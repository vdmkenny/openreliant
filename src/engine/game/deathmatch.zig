//! `C:\lancer\game\deathmatch.cpp`: the players' tallies and the rules of a multiplayer game.
//! **Unverified:** that `kills_add` is this file's: it lies after the file's known code, before
//! `dmscenarios.cpp`'s, among the code that keeps each player's tally.
//!
//! Ported so far: the player's own kills (`addKills`).

const std = @import("std");

const create = @import("create.zig");
const gameobj = @import("gameobj.zig");
const input = @import("../input.zig");

/// `kills_add` (`0x004B14F0`): adds `count` kills to the player of `slot`: to the pilot's own,
/// `skull_count`, where that is the local player. **Not ported:** each player's tally
/// (`0x005DB684`), the kills a campaign keeps for each mission (`0x00562E64`) and a team's in a
/// multiplayer game, and what it tells a multiplayer game when asked to.
pub fn addKills(player: *input.Player, all: *const create.Objects, slot: u16, count: i32) void {
    if (slot == all.player) player.kills += count;
}

test addKills {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const player = try mission.add(.predator, @splat(0));
    const other = try mission.add(.sabre, .{ 0, 0, 1000 });
    addKills(&mission.player, mission.objects, player, 1);
    addKills(&mission.player, mission.objects, player, 2);
    // Another player's kills are not the local pilot's.
    addKills(&mission.player, mission.objects, other, 5);
    try std.testing.expectEqual(3, mission.player.kills);
}
