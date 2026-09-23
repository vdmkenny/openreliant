//! `C:\lancer\game\explode.cpp`: an object's end, as it is seen and heard. The Explode order
//! ([`aiexplode.zig`](aiexplode.zig)) runs the ship down to it; here are the blast that ends it
//! and what the explosions leave for the frames after.
//!
//! Ported so far: the final blasts' sound, their bursts of flame and sparkle
//! ([`particles.zig`](particles.zig)) and their fireballs, and the point the camera watches a
//! break-up from. **Not ported:** the rest of what they show, the burning bits (`0x004717D0`) and
//! the shockwave, and the break-up that cuts a ship's parts into pieces that fly apart
//! (`0x0046C550`, `0x0046BF20`), with the rest of the explosions' update
//! ([#41](https://github.com/vdmkenny/openreliant/issues/41)).

const std = @import("std");
const Allocator = std.mem.Allocator;

const math = @import("../surrender/math.zig");
const Vector = math.Vector;
const srapiext = @import("../surrender/surrenderlib/srapiext.zig");
const srcore = @import("../surrender/surrenderlib/srcore.zig");
const srlight = @import("../surrender/surrenderlib/srlight.zig");
const srtexture = @import("../surrender/surrenderlib/srtexture.zig");
const gameobj = @import("gameobj.zig");
const libcmt = @import("../libcmt.zig");
const matmanager = @import("matmanager.zig");
const particles = @import("particles.zig");
const sound3d = @import("sound3d.zig");
const xtrabits = @import("xtrabits.zig");
const Clock = @import("main.zig").Clock;

/// What the explosions leave for the frames after them.
pub const Explosions = struct {
    images: Images,
    /// The fireballs going off (`explosion_fireballs`, `0x00553398`).
    fireballs: [max_fireballs]?Fireball = @splat(null),
    /// The point view `0x1B` watches (`0x0055AD0C`), which the player's ship's break-up leaves where
    /// the ship blew up; null until it has.
    marker: ?Marker = null,

    /// The fireballs the game keeps room for; one more is not set off.
    pub const max_fireballs = 30;

    pub const Marker = struct {
        position: Vector,
        /// How far it drifts a tick (`0x0055AD10`): a quarter of the ship's velocity, which is a
        /// step's.
        drift: Vector,
    };

    /// The textures an explosion shows (`explosions_init`, `0x0046B240`).
    pub const Images = struct {
        /// The bang's frames, `explosion\bang_00000` to `bang_00015` (`0x00558734`).
        bang: [16]*srtexture.Image,
        /// Nine frames in a three by three sheet, `explosion\explosion sheet` (`0x00558730`).
        sheet: *srtexture.Image,

        /// The names `explosions_init` makes of `explosion\bang_000%02d`.
        const bang_names = names: {
            var names: [16][]const u8 = undefined;
            for (&names, 0..) |*name, n| name.* = std.fmt.comptimePrint("explosion\\bang_000{d:0>2}", .{n});
            break :names names;
        };

        pub fn load(textures: *srtexture.Table) (Allocator.Error || matmanager.Error)!Images {
            var images: Images = undefined;
            for (&images.bang, bang_names) |*image, name| image.* = try matmanager.textureRequire(textures, name);
            images.sheet = try matmanager.textureRequire(textures, "explosion\\explosion sheet");
            return images;
        }
    };

    pub fn init(images: Images) Explosions {
        return .{ .images = images };
    }

    /// As a mission starts again: nothing going off, and no marker.
    pub fn reset(explosions: *Explosions) void {
        explosions.* = .init(explosions.images);
    }

    /// `explosions_update` (`0x0046E480`), once a frame, as far as the port goes: the marker drifts
    /// on, and each fireball plays on (`Fireball.frame`), until it is done.
    ///
    /// **Improvement:** the marker drifts by `drift` a tick, where the game adds it once a frame,
    /// which comes to the same at a frame a tick.
    pub fn frame(explosions: *Explosions, clock: *const Clock) void {
        if (explosions.marker) |*marker| marker.position += marker.drift * @as(Vector, @splat(@floatFromInt(@max(clock.frame_duration, 0))));
        for (&explosions.fireballs) |*slot| {
            const fireball = &(slot.* orelse continue);
            if (!fireball.frame(explosions.images, clock)) slot.* = null;
        }
    }

    /// The rest of `explosions_update`: each fireball showing goes into the world's layer, and its
    /// light among the lights.
    pub fn draw(explosions: *Explosions, gpa: Allocator, scene: *srcore.Scene) Allocator.Error!void {
        for (&explosions.fireballs) |*slot| {
            const fireball = &(slot.* orelse continue);
            if (!fireball.showing) continue;
            fireball.set.sprites = &fireball.sprite;
            try xtrabits.sceneAdd(gpa, scene, .{ .sprites = &fireball.set }, .world);
            if (fireball.light) |*light| try xtrabits.sceneAdd(gpa, scene, .{ .light = light }, .background);
        }
    }

    /// `explosion_fireball` (`0x0046BD00`): sets a fireball off at `at`, into the first free slot,
    /// and not at all where there is none.
    pub fn setOff(explosions: *Explosions, at: Vector, spec: Fireball.Spec, clock: *const Clock, random: *libcmt.Rand) void {
        for (&explosions.fireballs) |*slot| {
            if (slot.* != null) continue;
            slot.* = .init(explosions.images, at, spec, clock, random);
            return;
        }
    }
};

/// A fireball going off (0x2C bytes): a sprite that plays an animation of fire where it was set
/// off, drifting, with a light that fades as it plays where it has one.
pub const Fireball = struct {
    /// Its one sprite, and the set that draws it (`ExplodeParticle BMO`); its light
    /// (`ExplodeParticle Light`).
    sprite: [1]srapiext.Sprite,
    set: srapiext.SpriteSet,
    light: ?srlight.Light,
    /// How far it drifts a tick (`+0x08`).
    velocity: Vector,
    /// When it was set off, how long it plays and how long it waits first, in ticks (`+0x14`,
    /// `+0x18`, `+0x20`).
    born: i32,
    life: i32,
    delay: i32,
    look: Look,
    /// Whether it is coloured by how far it has played, from black to white (`+0x24`).
    lit: bool,
    /// Whether it showed at the last frame: past its wait, and not yet done.
    showing: bool = false,

    /// How it plays, and whether it is mirrored (`+0x1C`): a word the game builds from its kind
    /// and two random bits.
    pub const Look = packed struct(u32) {
        /// The sheet's frames mirrored left for right, and top for bottom.
        mirror_u: bool,
        mirror_v: bool,
        /// The bang's sixteen frames, which it plays unmirrored; otherwise the sheet's nine.
        bang: bool,
        _: u29 = 0,
    };

    /// What `explosion_fireball` is given.
    pub const Spec = struct {
        kind: Kind = .bang,
        /// How far it reaches either side of its centre.
        size: f32,
        life: i32 = 150,
        /// Whether it lights what is around it.
        light: bool = false,
        delay: i32 = 0,
        lit: bool = false,
        velocity: Vector = @splat(0),
    };

    pub const Kind = enum { bang, sheet };

    /// The light's intensity as it goes off, fading to nothing as it plays, and its colour; it
    /// reaches out by the square root of its size times `light_reach` (`0x004DC48C`).
    const light_intensity: f32 = 10;
    const light_colour = [3]f32{ 1, 0.5, 0.1 };
    const light_reach: f32 = 50;

    /// The sheet's frames: each `sheet_step` across and down from the last, `sheet_cell` across
    /// (`0x004DC82C`, `0x004DC828`: 82 and 81 of its 256 texels).
    const sheet_step: f32 = 82.0 / 256.0;
    const sheet_cell: f32 = 81.0 / 256.0;

    fn init(images: Explosions.Images, at: Vector, spec: Spec, clock: *const Clock, random: *libcmt.Rand) Fireball {
        var set: srapiext.SpriteSet = .{ .sprites = &.{} };
        set.surface.material.lit[0] = spec.lit;
        set.surface.material.blend[0] = .premultiplied;
        const image = switch (spec.kind) {
            .bang => images.bang[0],
            .sheet => images.sheet,
        };
        set.surface.textures = .{ .{ .image = image }, .none };
        const mirrors: u2 = @truncate(random.rand());
        return .{
            .sprite = .{.{ .offset = at, .half_size = .{ spec.size, spec.size }, .bias = -spec.size }},
            .set = set,
            .light = if (spec.light) .{
                .mask = 0,
                .intensity = light_intensity,
                .colour = light_colour,
                .kind = .{ .point = .{ .position = at, .range = @sqrt(spec.size) * light_reach } },
            } else null,
            .velocity = spec.velocity,
            .born = clock.frame_start,
            .life = spec.life,
            .delay = spec.delay,
            .look = .{ .mirror_u = mirrors & 1 != 0, .mirror_v = mirrors & 2 != 0, .bang = spec.kind == .bang },
            .lit = spec.lit,
        };
    }

    /// Plays on for the frame, once its wait is over: the frame of its animation this far through
    /// its life, its drift, its colour where it is lit, and its light's fade. Whether it is still
    /// going.
    fn frame(fireball: *Fireball, images: Explosions.Images, clock: *const Clock) bool {
        const age = clock.frame_start - fireball.delay - fireball.born;
        fireball.showing = false;
        if (age < 0) return true;
        if (age >= fireball.life) return false;
        const sprite = &fireball.sprite[0];
        if (fireball.look.bang) {
            fireball.set.surface.textures[0].image = images.bang[@intCast(@divTrunc(age * 16, fireball.life))];
        } else {
            const at: u32 = @intCast(@divTrunc(age * 9, fireball.life));
            const u = @as(f32, @floatFromInt(at % 3)) * sheet_step;
            const v = @as(f32, @floatFromInt(at / 3)) * sheet_step;
            const across: [2]f32 = if (fireball.look.mirror_u) .{ u + sheet_cell, u } else .{ u, u + sheet_cell };
            const down: [2]f32 = if (fireball.look.mirror_v) .{ v + sheet_cell, v } else .{ v, v + sheet_cell };
            sprite.uv = .{ across[0], across[1], down[0], down[1] };
        }
        sprite.offset += fireball.velocity * @as(Vector, @splat(@floatFromInt(clock.frame_duration)));
        const played = @as(f32, @floatFromInt(age)) / @as(f32, @floatFromInt(fireball.life));
        if (fireball.lit) sprite.colour = @splat(played);
        if (fireball.light) |*light| light.intensity = light_intensity - @as(f32, @floatFromInt(age)) * light_intensity / @as(f32, @floatFromInt(fireball.life));
        fireball.showing = true;
        return true;
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

/// Sets a fireball off at `at`, where the world has explosions.
pub fn fireballAt(world: gameobj.World, at: Vector, spec: Fireball.Spec) void {
    const explosions = world.explosions orelse return;
    explosions.setOff(at, spec, world.clock, world.random);
}

/// The fireballs a burst sets off about the ship, lit and each a little late, within
/// `burst_spread` of its radius, 0.8 of it across (`0x004DC4C0`, `0x004DC410`).
const burst_fireballs = 18;
const burst_spread: f32 = 0.3;
const burst_size: f32 = 0.8;
const burst_delay: f32 = 10;

/// `0x0046C980`: a ship's blast at the end of its Explode order: a burst of flame, fast and wide,
/// one of sparkle, a lit fireball of the ship's size drifting on with the sparkle, and the sound,
/// heard on a sure voice close to the camera.
///
/// Not ported: the cloak dropped, the break-up, the burning bits, and the shockwave one blast in
/// four.
pub fn blast(world: gameobj.World, index: u16) void {
    const slot = &world.objects.slots[index];
    const at = slot.drawn.position;
    const velocity = gameobj.vector(slot.object.velocity);
    flames(world, at, velocity, .{ .speed = 200, .speed_range = 300, .carried = .{ .share_or_more = 0.25 }, .count = 400 });
    const carried = 0.25;
    sparkles(world, at, velocity, carried);
    fireballAt(world, at, .{ .size = slot.object.radius, .light = true, .velocity = velocity * @as(Vector, @splat(carried)) });
    sound(world, at, soundClass(world, at) orelse return);
}

/// `0x00471DB0`: the blast of a ship that bursts: a slower burst of flame and one of sparkle, heard
/// among the explosions. The player's leaves the marker the camera watches, drifting on at the
/// ship's speed. **Unverified:** it lies after this file's known code.
///
/// Its 18 fireballs, lit and each up to a tenth of a second late, stand at random within 0.3 of
/// its radius and drift on with the sparkle.
///
/// Not ported: the cloak dropped, the break-up and the burning bits.
pub fn burst(world: gameobj.World, index: u16) void {
    const slot = &world.objects.slots[index];
    const at = slot.drawn.position;
    const velocity = gameobj.vector(slot.object.velocity);
    const radius = slot.object.radius;
    if (index == world.objects.player) if (world.explosions) |explosions| {
        explosions.marker = .{ .position = at, .drift = velocity * @as(Vector, @splat(0.25)) };
    };
    flames(world, at, velocity, .{ .speed = 20, .speed_range = 5, .carried = .{ .share = 0.25 }, .count = 200 });
    const carried = 0.5;
    sparkles(world, at, velocity, carried);
    const random = world.random;
    for (0..burst_fireballs) |_| {
        const out: Vector = .{ random.fraction() * radius * burst_spread, 0, 0 };
        const roll = random.fraction() * std.math.tau;
        const yaw = random.fraction() * std.math.tau;
        const pitch = random.fraction() * std.math.tau;
        const place = math.transform(math.fromAngles(pitch, yaw, roll), out) + at;
        const delay: i32 = @intFromFloat(@trunc(random.fraction() * burst_delay));
        fireballAt(world, place, .{ .size = radius * burst_size, .light = true, .delay = delay, .velocity = velocity * @as(Vector, @splat(carried)) });
    }
    sound(world, at, .explosions);
}

const testing = struct {
    /// Textures that are never looked into, one for each frame, told apart by where they are.
    var bang: [16]srtexture.Image = undefined;
    var sheet: srtexture.Image = undefined;

    fn images() Explosions.Images {
        var found: Explosions.Images = .{ .bang = undefined, .sheet = &sheet };
        for (&found.bang, &bang) |*image, *texture| image.* = texture;
        return found;
    }
};

test Explosions {
    var explosions: Explosions = .init(testing.images());
    var clock: Clock = .{};
    clock.frame_duration = 10;
    explosions.frame(&clock);
    try std.testing.expectEqual(null, explosions.marker);
    explosions.marker = .{ .position = .{ 0, 0, 100 }, .drift = .{ 0, 0, 5 } };
    explosions.frame(&clock);
    try std.testing.expectEqual(Vector{ 0, 0, 150 }, explosions.marker.?.position);
}

test Fireball {
    var explosions: Explosions = .init(testing.images());
    var clock: Clock = .{};
    var random: libcmt.Rand = .{};
    explosions.setOff(.{ 0, 0, 100 }, .{ .size = 40, .light = true, .delay = 10, .velocity = .{ 1, 0, 0 } }, &clock, &random);
    const bang = &explosions.fireballs[0].?;
    try std.testing.expectEqual(-40, bang.sprite[0].bias);

    // Waiting, it doesn't show.
    clock.frame_start = 5;
    explosions.frame(&clock);
    try std.testing.expect(!bang.showing);

    // Halfway through its life, the bang's middle frame, drifted on, its light half faded.
    clock.frame_start = 10 + 75;
    clock.frame_duration = 20;
    explosions.frame(&clock);
    try std.testing.expect(bang.showing);
    try std.testing.expectEqual(&testing.bang[8], bang.set.surface.textures[0].image);
    try std.testing.expectEqual(Vector{ 20, 0, 100 }, bang.sprite[0].offset);
    try std.testing.expectApproxEqAbs(5, bang.light.?.intensity, 1e-6);

    // The sheet steps through its cells, mirrored as its look says.
    explosions.setOff(@splat(0), .{ .kind = .sheet, .size = 10, .life = 90 }, &clock, &random);
    const sheet = &explosions.fireballs[1].?;
    sheet.look.mirror_u = true;
    sheet.look.mirror_v = false;
    clock.frame_start += 50;
    explosions.frame(&clock);
    const u = 2 * Fireball.sheet_step;
    const v = 1 * Fireball.sheet_step;
    try std.testing.expectEqual([4]f32{ u + Fireball.sheet_cell, u, v, v + Fireball.sheet_cell }, sheet.sprite[0].uv);

    // Done, it is gone.
    clock.frame_start += 200;
    explosions.frame(&clock);
    try std.testing.expectEqual(null, explosions.fireballs[0]);
    try std.testing.expectEqual(null, explosions.fireballs[1]);
}

test burst {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    var explosions: Explosions = .init(testing.images());
    var world = mission.world();
    world.explosions = &explosions;
    const player = try mission.add(.predator, .{ 0, 0, 0 });
    const other = try mission.add(.sabre, .{ 0, 0, 1000 });
    mission.objects.slots[player].object.velocity = .{ .x = 0, .y = 0, .z = 40 };

    // Another ship's burst leaves no marker, but 18 lit fireballs, each up to a tenth of a second
    // late; the player's leaves one drifting at its speed.
    burst(world, other);
    try std.testing.expectEqual(null, explosions.marker);
    for (explosions.fireballs[0..burst_fireballs]) |slot| {
        const set = slot.?;
        try std.testing.expect(set.light != null and set.delay < 10);
    }
    try std.testing.expectEqual(null, explosions.fireballs[burst_fireballs]);
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
    var explosions: Explosions = .init(testing.images());
    var world = mission.world();
    world.particles = &pool;
    world.camera = &watching;
    world.explosions = &explosions;
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
    // And one lit fireball of the ship's size.
    try std.testing.expect(explosions.fireballs[0].?.light != null);
    try std.testing.expectEqual(null, explosions.fireballs[1]);
}
