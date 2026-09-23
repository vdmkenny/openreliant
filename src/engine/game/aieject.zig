//! The orders of a pilot's ejection: Eject (30), Eject Spin (108), Eject Fighter Attack (113) and
//! Eject Player (118). `object_destroyed` ([`ai.zig`](ai.zig)) gives the player's ship Eject Player
//! and an AI ship Eject Spin. **Unknown:** its source file. The code lies after `airipper.cpp`'s
//! and before `jump.cpp`'s, and no string places it; this module is named for its orders.
//!
//! Ported so far: Eject Player. **Not ported:** the others
//! ([#30](https://github.com/vdmkenny/openreliant/issues/30)), which no ship of the sandbox's is
//! given: its AI ships' pilots never eject.

const std = @import("std");
const assert = std.debug.assert;

const ai = @import("ai.zig");
const aigeneric = @import("aigeneric.zig");
const Context = aigeneric.Context;
const gameobj = @import("gameobj.zig");

/// What Eject Player keeps in the object's order state.
pub const PlayerState = extern struct {
    /// The tick after which the ship blows up.
    end: i32,
    /// How often the ship has reached its end: `object_destroyed` pops the order once it has.
    ended: i32,
    _unknown_08: [0x90 - 0x08]u8,

    comptime {
        assert(@offsetOf(PlayerState, "ended") == 0x4);
        assert(@sizeOf(PlayerState) == 0x90);
    }
};

/// How long the player's ship drifts after the pilot ejects: this, and up to as long again as
/// `blow_up_spread`, in ticks.
const blow_up_after = 400;
const blow_up_spread = 200;

/// `order_eject_player_init` (`0x00416310`): the player ejects, and the ship drifts on unpowered
/// until it blows up, four to six seconds later.
///
/// Not ported: the eject marker's flash on the display (`player_ejected`, `hud_eject_ticks`), the
/// cockpit's parts it sets going, and the pilot's line on the radio
/// ([#48](https://github.com/vdmkenny/openreliant/issues/48)).
pub fn playerInit(ctx: Context, index: u16) void {
    const slot = &ctx.world.objects.slots[index];
    const state = &slot.state.eject_player;
    state.ended = 0;
    state.end = @as(i32, ctx.world.random.rand() % blow_up_spread) + blow_up_after + ctx.clock.frame_start;
    slot.object.flags.unpowered = true;
    slot.object.flags.ejected = true;
    ctx.world.player.ending = .ejecting;
}

/// `order_eject_player` (`0x00416450`): the player's controls run on until the ship's end, when it
/// is destroyed once more, now to explode, and its new order runs at once.
pub fn player(ctx: Context, index: u16) void {
    const state = &ctx.world.objects.slots[index].state.eject_player;
    if (state.end < ctx.clock.frame_start) {
        state.ended += 1;
        ai.objectDestroyed(ctx, index, false, false);
        aigeneric.objectOrders(ctx, index);
        return;
    }
    aigeneric.playerControl(ctx, index);
}

test player {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const ctx = mission.orders();
    const index = try mission.add(.predator, @splat(0));
    const slot = &mission.objects.slots[index];

    // The player's ship ejects, and drifts until its end, which comes four to six seconds later.
    try std.testing.expect(try aigeneric.push(ctx, index, .eject_player, .none));
    aigeneric.objectOrders(ctx, index);
    try std.testing.expect(slot.object.flags.ejected and slot.object.flags.unpowered);
    try std.testing.expectEqual(.ejecting, mission.player.ending);
    const end = slot.state.eject_player.end;
    try std.testing.expect(end >= 400 and end < 600);

    // Past it, the ship explodes, and may not spin out.
    mission.clock.frame_start = end + 1;
    aigeneric.objectOrders(ctx, index);
    try std.testing.expect(slot.object.flags.exploding);
    try std.testing.expect(!slot.orders[0].data.destroyed.may_spin);
    try std.testing.expectEqual(.destroyed, mission.player.ending);
}
