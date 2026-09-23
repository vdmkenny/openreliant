//! `C:\lancer\game\shieldfx.cpp`: what a hit leaves where it struck (`0x004A0310`, 12 bytes), which
//! `0x004992D0` (`objects.cpp`) hangs from the part struck as a node of kind 6, by what struck:
//!
//! | Kind | Struck by | What it leaves |
//! |---|---|---|
//! | 2 | A shot or a missile through to a hull (`bullet_hull_hit`, `0x00495BB0`) | The hit's sound (`hullHit`), and an emitter of `0x0049FD20`'s orange template on the part's surface nearest the point (`0x0049FEF0`), facing out from it |
//! | 3 | A shot or a missile on a component (`bullet_hit`, `0x0047B840`, `0x00495AC0`) | A burst of 20 of the orange template's particles |
//! | 4 | Nothing | An emitter of the grey template |
//! | 5 | Nothing | Sound 71, and `0x00472780` |
//!
//! Nothing sends the emitters' particles out: `node_draw` updates a node of kind 6 through
//! `0x00458AB0`, which is the one routine the build keeps of every routine that only returns 1, so
//! a hull's emitter shows nothing.
//!
//! Not ported: the nodes and their emitters, which show nothing; a component's burst
//! ([#40](https://github.com/vdmkenny/openreliant/issues/40)); and a missile's hits
//! ([#39](https://github.com/vdmkenny/openreliant/issues/39)). The game hangs a part no more than a
//! hundred nodes, so a part struck a hundred times no longer sounds; the port keeps no nodes, and
//! every hit sounds.

const std = @import("std");

const math = @import("../surrender/math.zig");
const Vector = math.Vector;
const gameobj = @import("gameobj.zig");
const sound3d = @import("sound3d.zig");

/// How long after a shot last sounded on the player's hull another does (`0x00593794`).
const player_hit_pause = 30;

/// `0x004A0310`'s sound for a shot through to the hull of the object in slot `index` at `at`:
/// `ARMOUR01` there, facing the camera; on the player's own ship `PLAYERHIT` instead, following it,
/// no more than once in `player_hit_pause` ticks.
///
/// **Improvement:** the game plays `ARMOUR01` at the point struck in the part's own frame, taken
/// for one in the world, so it is heard from near the world's origin; the port plays it where the
/// shot struck.
pub fn hullHit(world: gameobj.World, index: u16, at: Vector) void {
    const hearing = world.hearing orelse return;
    const all = world.objects;
    const now = world.clock.frame_start;
    const facing = math.normalize(hearing.camera.position - at);
    if (index != all.player) {
        _ = sound3d.play(hearing.sound, hearing.scene(world), at, facing, -1, .armour01, 1, .not_reserved);
        return;
    }
    if (now - hearing.sound.player_hit_at < player_hit_pause) return;
    hearing.sound.player_hit_at = now;
    _ = sound3d.play(hearing.sound, hearing.scene(world), all.slots[index].drawn.position, facing, index, .playerhit, 1, .guaranteed);
}

test {
    std.testing.refAllDecls(@This());
}

test hullHit {
    const mss = @import("../mss.zig");
    const hog_snd = @import("hog_snd.zig");
    var mixer: mss.Mixer = .init(22050);
    var sound: hog_snd.Sound = undefined;
    sound.init(mixer.driver(), 2, null);
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const view: @import("camera.zig").Place = .{ .position = @splat(0), .orientation = math.identity };
    var world = mission.world();
    world.hearing = .{ .sound = &sound, .camera = &view, .clock = &mission.clock };
    const player = try mission.add(.predator, @splat(0));
    const other = try mission.add(.sabre, .{ 0, 0, 1000 });

    // The player's hull sounds a hit, then none for thirty ticks.
    mission.clock.frame_start = 100;
    hullHit(world, player, .{ 0, 0, 10 });
    try std.testing.expectEqual(100, sound.player_hit_at);
    mission.clock.frame_start = 120;
    hullHit(world, player, .{ 0, 0, 10 });
    try std.testing.expectEqual(100, sound.player_hit_at);
    mission.clock.frame_start = 130;
    hullHit(world, player, .{ 0, 0, 10 });
    try std.testing.expectEqual(130, sound.player_hit_at);
    // Another ship's hull sounds every hit, and leaves the player's pause alone.
    hullHit(world, other, .{ 0, 0, 990 });
    try std.testing.expectEqual(130, sound.player_hit_at);
}
