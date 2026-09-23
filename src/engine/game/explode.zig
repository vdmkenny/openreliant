//! `C:\lancer\game\explode.cpp`: an object's end, as it is seen and heard. The Explode order
//! ([`aiexplode.zig`](aiexplode.zig)) runs the ship down to it; here are the blast that ends it
//! and what the explosions leave for the frames after.
//!
//! Ported so far: the final blasts' sound and their bursts of flame and sparkle
//! ([`particles.zig`](particles.zig)), and the point the camera watches a break-up from.
//! **Not ported:** the rest of what they show, the fireballs (`0x0046BD00`), the burning bits
//! (`0x004717D0`) and the shockwave, and the break-up that cuts a ship's parts into pieces that fly
//! apart (`0x0046C550`, `0x0046BF20`)
//! ([#41](https://github.com/vdmkenny/openreliant/issues/41)).

const std = @import("std");

const math = @import("../surrender/math.zig");
const Vector = math.Vector;
const gameobj = @import("gameobj.zig");
const libcmt = @import("../libcmt.zig");
const particles = @import("particles.zig");
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

/// The flame a blast bursts into (`0x00553348`): five to six seconds of it, growing from nothing
/// to a half-size of 400 as it goes from yellowish white through orange to nothing. It thins
/// slowly with distance.
pub const flame: particles.Template = .{
    .life = 500,
    .life_spread = 100,
    .size = .through(0, 100, 400),
    .colour = .{ .through(1, 0.75, 0), .through(1, 0.25, 0), .through(0, 0, 0) },
    .distance = 0.05,
};

/// The sparkle a blast leaves (`0x0055334C`): specks of white, 25 across either way, that last one
/// to six seconds and fade out.
pub const sparkle: particles.Template = .{
    .life = 100,
    .life_spread = 500,
    .size = .through(0, 25, 25),
    .colour = .{ .through(1, 1, 0), .through(1, 1, 0), .through(1, 1, 0) },
};

/// How much of a ship's velocity, a step's, the particles of its blast carry on with, a tick's.
const Carried = union(enum) {
    /// This share of it.
    share: f32,
    /// This share and up to as much again, at random.
    share_or_more: f32,

    fn of(carried: Carried, random: *libcmt.Rand) f32 {
        return switch (carried) {
            .share => |share| share,
            .share_or_more => |share| (random.fraction() + 1) * share,
        };
    }
};

/// How a blast's flame leaves it: how fast, a tick, how much of the ship's velocity it carries, and
/// how many.
const Flames = struct {
    speed: f32,
    speed_range: f32,
    carried: Carried,
    count: i32,
};

/// Sends `emitter` off from a ship at `at`, moving at `velocity`, carrying `carried` of it: `count`
/// particles at once, as the camera sees them.
fn send(world: gameobj.World, emitter: particles.Emitter, at: Vector, velocity: Vector, carried: f32, count: i32) void {
    const pool = world.particles orelse return;
    const view = (world.camera orelse return).place;
    var from = emitter;
    from.place.position = at;
    from.inherited = velocity * @as(Vector, @splat(carried));
    pool.burst(&from, null, count, view, world.clock, world.random);
}

/// A burst of `flame`, spreading out mostly across the view: the emitter stands turned 60 degrees
/// back and a random way about the camera's forward axis, from the camera's orientation.
fn flames(world: gameobj.World, at: Vector, velocity: Vector, how: Flames) void {
    const view = (world.camera orelse return).place;
    const turn = math.fromAngles(-std.math.pi / 3.0, 0, world.random.fraction() * std.math.tau);
    const emitter: particles.Emitter = .{
        .born = world.clock.frame_start,
        .template = &flame,
        .place = .{ .orientation = math.product(turn, view.orientation) },
        .spread = .{ 1, 1, 0.2 },
        .speed = how.speed,
        .speed_range = how.speed_range,
    };
    send(world, emitter, at, velocity, how.carried.of(world.random), how.count);
}

/// A burst of 150 of `sparkle`, drifting every way.
fn sparkles(world: gameobj.World, at: Vector, velocity: Vector, carried: f32) void {
    const emitter: particles.Emitter = .{
        .born = world.clock.frame_start,
        .template = &sparkle,
        .spread = .{ 1, 1, 1 },
        .speed_range = 7,
    };
    send(world, emitter, at, velocity, carried, 150);
}

/// `0x0046C980`: a ship's blast at the end of its Explode order: a burst of flame, fast and wide,
/// and one of sparkle, and the sound, heard on a sure voice close to the camera.
///
/// Not ported: the cloak dropped, the break-up, the burning bits, the shockwave one blast in four,
/// and the fireball.
pub fn blast(world: gameobj.World, index: u16) void {
    const slot = &world.objects.slots[index];
    const at = slot.drawn.position;
    const velocity = gameobj.vector(slot.object.velocity);
    flames(world, at, velocity, .{ .speed = 200, .speed_range = 300, .carried = .{ .share_or_more = 0.25 }, .count = 400 });
    sparkles(world, at, velocity, 0.25);
    sound(world, at, soundClass(world, at) orelse return);
}

/// `0x00471DB0`: the blast of a ship that bursts: a slower burst of flame and one of sparkle, heard
/// among the explosions. The player's leaves the marker the camera watches, drifting on at the
/// ship's speed. **Unverified:** it lies after this file's known code.
///
/// Not ported: the cloak dropped, the break-up, the burning bits, and the 18 fireballs about it.
pub fn burst(world: gameobj.World, index: u16) void {
    const slot = &world.objects.slots[index];
    const at = slot.drawn.position;
    const velocity = gameobj.vector(slot.object.velocity);
    if (index == world.objects.player) if (world.explosions) |explosions| {
        explosions.marker = .{ .position = at, .drift = velocity * @as(Vector, @splat(0.25)) };
    };
    flames(world, at, velocity, .{ .speed = 20, .speed_range = 5, .carried = .{ .share = 0.25 }, .count = 200 });
    sparkles(world, at, velocity, 0.5);
    sound(world, at, .explosions);
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

test blast {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    var image: @import("../surrender/surrenderlib/srtexture.zig").Image = undefined;
    var pool: particles.Pool = try .init(std.testing.allocator, 1000, &image);
    defer pool.deinit();
    var watching: @import("camera.zig").Camera = .{};
    var world = mission.world();
    world.particles = &pool;
    world.camera = &watching;
    mission.clock.frame_start = 10;
    _ = try mission.add(.predator, @splat(0));
    const ship = try mission.add(.sabre, @splat(0));
    mission.objects.slots[ship].drawn.position = .{ 0, 0, 5000 };

    // In view 5000 off, all 400 of the flame, which thins slowly, and three quarters of the 150
    // of the sparkle: its half-size of 25 times 150, over the distance. The rounding is even.
    blast(world, ship);
    var sent: usize = 0;
    for (pool.particles) |particle| {
        if (particle.template != null) sent += 1;
    }
    try std.testing.expectEqual(400 + 112, sent);
}
