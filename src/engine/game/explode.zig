//! `C:\lancer\game\explode.cpp`: an object's end, as it is seen and heard. The Explode order
//! ([`aiexplode.zig`](aiexplode.zig)) runs the ship down to it; here are the blast that ends it
//! and what the explosions leave for the frames after.
//!
//! Ported so far: the final blasts' sound, and the point the camera watches a break-up from.
//! **Not ported:** what they show, the fireballs (`0x0046BD00`), the burning bits
//! (`0x004717D0`), the particles and the shockwave, and the break-up that cuts a ship's parts into
//! pieces that fly apart (`0x0046C550`, `0x0046BF20`)
//! ([#41](https://github.com/vdmkenny/openreliant/issues/41)).

const std = @import("std");

const math = @import("../surrender/math.zig");
const Vector = math.Vector;
const gameobj = @import("gameobj.zig");
const sound3d = @import("sound3d.zig");

/// What the explosions leave for the frames after them.
pub const Explosions = struct {
    /// The point view `0x1B` watches (`0x0055AD0C`), which the player's ship's break-up leaves where
    /// the ship blew up; null until it has.
    marker: ?Marker = null,

    pub const Marker = struct {
        position: Vector,
        /// How far it drifts a tick (`0x0055AD10`): a quarter of the ship's velocity, which is a
        /// step's.
        drift: Vector,
    };

    /// `0x0046E480`, the explosions' update, as far as the port goes: the marker drifts on.
    /// **Improvement:** it drifts by `drift` a tick, where the game adds it once a frame, which
    /// comes to the same at a frame a tick.
    pub fn update(explosions: *Explosions, ticks: i32) void {
        const marker = &(explosions.marker orelse return);
        marker.position += marker.drift * @as(Vector, @splat(@floatFromInt(@max(ticks, 0))));
    }
};

/// Within this far of the camera an explosion is sure of a voice (`0x004DC4BC`, its square).
const close: f32 = 20000;

/// The voice class an explosion at `at` is heard on: sure of a voice close to the camera, one of the
/// explosions' own further off.
pub fn soundClass(world: gameobj.World, at: Vector) ?sound3d.Class {
    const hearing = world.hearing orelse return null;
    const offset = at - hearing.camera.position;
    return if (math.dot(offset, offset) < close * close) .guaranteed else .explosions;
}

/// Plays the first explosion's sound at `at`, on `class`.
pub fn sound(world: gameobj.World, at: Vector, class: sound3d.Class) void {
    const hearing = world.hearing orelse return;
    _ = sound3d.play(hearing.sound, hearing.scene(world), at, null, -1, .explosion01, 1, class);
}

/// `0x0046C980`: a ship's blast at the end of its Explode order, which is heard on a sure voice
/// close to the camera.
pub fn blast(world: gameobj.World, index: u16) void {
    const at = world.objects.slots[index].drawn.position;
    sound(world, at, soundClass(world, at) orelse return);
}

/// `0x00471DB0`: the blast of a ship that bursts, heard among the explosions. The player's leaves
/// the marker the camera watches, drifting on at the ship's speed. **Unverified:** it lies after
/// this file's known code.
pub fn burst(world: gameobj.World, index: u16) void {
    const slot = &world.objects.slots[index];
    if (index == world.objects.player) if (world.explosions) |explosions| {
        explosions.marker = .{
            .position = slot.drawn.position,
            .drift = gameobj.vector(slot.object.velocity) * @as(Vector, @splat(0.25)),
        };
    };
    sound(world, slot.drawn.position, .explosions);
}

test Explosions {
    var explosions: Explosions = .{};
    explosions.update(10);
    try std.testing.expectEqual(null, explosions.marker);
    explosions.marker = .{ .position = .{ 0, 0, 100 }, .drift = .{ 0, 0, 5 } };
    explosions.update(10);
    try std.testing.expectEqual(Vector{ 0, 0, 150 }, explosions.marker.?.position);
}

test burst {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    var explosions: Explosions = .{};
    var world = mission.world();
    world.explosions = &explosions;
    const player = try mission.add(.predator, .{ 0, 0, 0 });
    const other = try mission.add(.sabre, .{ 0, 0, 1000 });
    mission.objects.slots[player].object.velocity = .{ .x = 0, .y = 0, .z = 40 };

    // Another ship's burst leaves no marker; the player's leaves one drifting at its speed.
    burst(world, other);
    try std.testing.expectEqual(null, explosions.marker);
    burst(world, player);
    try std.testing.expectEqual(Vector{ 0, 0, 10 }, explosions.marker.?.drift);
}
