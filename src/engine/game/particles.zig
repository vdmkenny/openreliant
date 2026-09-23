//! `C:\lancer\game\particles.cpp`: particles, sprites that fly off an emitter and change size and
//! colour over their life. A template says how its particles live, and an emitter sends them out
//! of it, all at once (`Pool.burst`) or over its own life (`Pool.stream`). Every particle comes
//! from one pool of a thousand, drawn as one set of sprites over `gunflare\partic4`, added and
//! coloured by each sprite's colour.
//!
//! **Not ported:** the sparks a template of kind `sometimes_sparks` or `sparks` sends out
//! (`particle_spark`, `0x0049C340`), which are `explode.cpp`'s burning bits
//! ([#41](https://github.com/vdmkenny/openreliant/issues/41)); and what `particles_frame` runs first
//! (`0x004A1BB0`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const math = @import("../surrender/math.zig");
const Matrix = math.Matrix;
const Vector = math.Vector;
const srapiext = @import("../surrender/surrenderlib/srapiext.zig");
const srcore = @import("../surrender/surrenderlib/srcore.zig");
const srtexture = @import("../surrender/surrenderlib/srtexture.zig");
const camera = @import("camera.zig");
const libcmt = @import("../libcmt.zig");
const matmanager = @import("matmanager.zig");
const xtrabits = @import("xtrabits.zig");
const Clock = @import("main.zig").Clock;

/// A quadratic over a particle's life, from 0 at its birth to 1 at its end.
pub const Curve = extern struct {
    a: f32,
    b: f32,
    c: f32,

    /// `particle_curve_set` (`0x0049C180`): the curve through `start`, `middle` and `end` at the
    /// beginning, halfway and the end.
    pub fn through(start: f32, middle: f32, end: f32) Curve {
        return .{ .a = start + end + start + end - middle * 4, .b = middle * 4 - (start * 3 + end), .c = start };
    }

    /// Its value `t` of the way through, summed as the game sums it.
    pub fn at(curve: Curve, t: f32) f32 {
        return curve.b * t + curve.a * t * t + curve.c;
    }
};

/// How a template's particles live (`particle_template_create`, `0x0049C5D0`, 0x50 bytes).
pub const Template = struct {
    /// `+0x00`.
    kind: Kind = .particles,
    /// How long each particle lives, in ticks, and up to how many more at random (`+0x04`,
    /// `+0x08`).
    life: i32,
    life_spread: i32 = 0,
    /// How many particles a tick an emitter streams, in hundredths, over its own life (`+0x0C`).
    rate: Curve = .through(0, 0, 0),
    /// A particle's half-size, and its red, green and blue, over its life (`+0x18` to `+0x47`).
    size: Curve,
    red: Curve,
    green: Curve,
    blue: Curve,
    /// How much a burst thins with distance; none at zero (`+0x4C`).
    distance: f32 = 1,

    pub const Kind = enum(u32) {
        particles = 0,
        /// Particles, and a spark one time in 200.
        sometimes_sparks = 1,
        sparks = 2,
    };

    /// How far a burst or a stream is thinned: its particles' half-size halfway through their
    /// life, times this, over their distance (`0x004DC594`).
    const thin_by: f32 = 150;

    /// What share of a burst's or a stream's particles are sent: their half-size halfway through
    /// their life times `thin_by`, over `over` where it is given, and at most all of them.
    fn share(template: *const Template, over: ?f32) f32 {
        const full = template.size.at(0.5) * thin_by;
        return @min(if (over) |by| full / by else full, 1);
    }
};

/// What sends particles out (`particle_emitter_create`, `0x0049C600`, 0xFC bytes).
pub const Emitter = struct {
    /// How long it streams, in ticks from its birth (`+0x00`, `+0x04`).
    life: i32 = 0,
    born: i32,
    /// Where it stands from its parent, or in the world where it has none: its frame's place
    /// (`+0x08`, the frame's `+0x18` and `+0x3C`).
    orientation: Matrix = math.identity,
    position: Vector = @splat(0),
    /// Where that puts it in the world, which it works out each time it sends particles out (the
    /// frame's `+0x4C` and `+0x70`).
    world: camera.Place = .{ .position = @splat(0), .orientation = math.identity },
    /// Which way its particles leave, in its own frame, and how far they stray from it along each
    /// axis, half of it either way (`+0xBC`, `+0xC8`).
    direction: Vector = @splat(0),
    spread: Vector = @splat(0),
    /// How fast they leave, a tick: `speed` and up to `speed_range` more (`+0xD4`, `+0xD8`).
    speed: f32 = 0,
    speed_range: f32 = 0,
    /// Added to each particle's velocity, a tick: what it carries of what it leaves (`+0xDC`).
    inherited: Vector = @splat(0),
    /// The span of the texture its particles show: left, right, top and bottom (`+0xE8`).
    uv: [4]f32 = .{ 0, 1, 0, 1 },
    template: *const Template,

    /// `particle_emitter_create`: of `template`, born now, unturned.
    pub fn init(template: *const Template, clock: *const Clock) Emitter {
        return .{ .born = clock.frame_start, .template = template };
    }

    /// Its place in the world, from its parent's where it hangs from one
    /// (`SR_object_concate_parents`, `0x004C3570`, one level up).
    fn place(emitter: *Emitter, parent: ?camera.Place) void {
        const from = parent orelse {
            emitter.world = .{ .position = emitter.position, .orientation = emitter.orientation };
            return;
        };
        emitter.world = .{
            .position = math.transform(from.orientation, emitter.position) + from.position,
            .orientation = math.product(from.orientation, emitter.orientation),
        };
    }

    /// A particle's velocity from its emitter, but for what it inherits: along `direction`,
    /// strayed by `spread`, at a speed from `speed`, turned into the world. The game draws the
    /// third axis's first.
    fn velocity(emitter: *const Emitter, random: *libcmt.Rand) Vector {
        const z = random.centred() * emitter.spread[2] + emitter.direction[2];
        const y = random.centred() * emitter.spread[1] + emitter.direction[1];
        const x = random.centred() * emitter.spread[0] + emitter.direction[0];
        var v: Vector = .{ x, y, z };
        const length = math.length(v);
        if (length > 0) v *= @splat((random.fraction() * emitter.speed_range + emitter.speed) / length);
        return math.transform(emitter.world.orientation, v);
    }
};

/// A particle's record (0x18 bytes); its sprite is the one of the same index.
pub const Particle = struct {
    /// When it was born and how long it lives, in ticks: free once they are past.
    born: i32 = 0,
    life: i32 = 0,
    /// How far it moves a tick.
    velocity: Vector = @splat(0),
    template: ?*const Template = null,

    fn alive(particle: Particle, now: i32) bool {
        return now < particle.born + particle.life;
    }
};

/// The one pool the game's particles come from (`particle_pool`, `0x0058A94C`), the only one of the
/// ten `particle_pools` (`0x0058A948`) the game fills.
pub const Pool = struct {
    gpa: Allocator,
    particles: []Particle,
    sprites: []srapiext.Sprite,
    /// Drawn with as many of `sprites` as `used`.
    set: srapiext.SpriteSet,
    /// One past the last particle alive at the last frame (`+0x0C`), up to which the frame looks.
    used: u32 = 0,

    /// The size of the game's pool.
    pub const size = 1000;
    pub const image_name = "gunflare\\partic4";

    /// `particles_init` (`0x0049BF60`) and `particle_pool_create` (`0x0049C050`): the pool of
    /// `count` particles over `image`, their sprites showing the whole texture, added and coloured
    /// by each sprite's colour.
    pub fn init(gpa: Allocator, count: usize, image: *srtexture.Image) Allocator.Error!Pool {
        const particles = try gpa.alloc(Particle, count);
        errdefer gpa.free(particles);
        const sprites = try gpa.alloc(srapiext.Sprite, count);
        @memset(particles, .{});
        @memset(sprites, .{});
        var set: srapiext.SpriteSet = .{ .sprites = sprites[0..0] };
        set.surface.material.lit[0] = true;
        set.surface.textures = .{ .{ .image = image }, .none };
        return .{ .gpa = gpa, .particles = particles, .sprites = sprites, .set = set };
    }

    /// The game's pool, over the texture it requires.
    pub fn load(gpa: Allocator, textures: *srtexture.Table) (Allocator.Error || matmanager.Error)!Pool {
        return .init(gpa, size, try matmanager.textureRequire(textures, image_name));
    }

    /// `particles_shutdown` (`0x0049C010`) and `particle_pool_free` (`0x0049C140`).
    pub fn deinit(pool: *Pool) void {
        pool.gpa.free(pool.particles);
        pool.gpa.free(pool.sprites);
    }

    /// `particles_reset` (`0x0049BFB0`), as a mission starts or ends: every particle free.
    pub fn reset(pool: *Pool) void {
        @memset(pool.particles, .{});
        pool.used = 0;
        pool.set.sprites = pool.sprites[0..0];
    }

    /// `particle_emit` (`0x0049C1C0`): particle `index` born from `emitter`, now, where the emitter
    /// stands.
    pub fn emit(pool: *Pool, emitter: *const Emitter, index: usize, clock: *const Clock, random: *libcmt.Rand) void {
        const particle = &pool.particles[index];
        const sprite = &pool.sprites[index];
        if (pool.used <= index) pool.used = @intCast(index + 1);
        const template = emitter.template;
        particle.* = .{ .born = clock.frame_start, .life = template.life, .template = template };
        if (template.life_spread > 0) particle.life += @rem(@as(i32, random.rand()), template.life_spread);
        particle.velocity = emitter.velocity(random);
        sprite.offset = emitter.world.position;
        sprite.uv = emitter.uv;
        particle.velocity += emitter.inherited;
    }

    /// `particle_burst` (`0x0049C450`): `count` particles from `emitter` at once, into the free
    /// ones, where `parent` puts it. Half as many where it stands behind the camera, and fewer
    /// with distance, the more so the smaller they are.
    pub fn burst(pool: *Pool, emitter: *Emitter, parent: ?camera.Place, count: i32, view: camera.Place, clock: *const Clock, random: *libcmt.Rand) void {
        emitter.place(parent);
        const offset = emitter.world.position - view.position;
        var wanted = count;
        if (math.dot(offset, math.forward(view.orientation)) < 0) wanted = @divTrunc(wanted, 2);
        const template = emitter.template;
        const share = template.share(if (template.distance > 0) math.length(offset) * template.distance else null);
        var left = math.round(@as(f32, @floatFromInt(wanted)) * share);
        for (pool.particles, 0..) |particle, index| {
            if (left < 1) return;
            if (particle.born + particle.life < clock.frame_start) {
                pool.emit(emitter, index, clock, random);
                left -= 1;
            }
        }
    }

    /// `particle_stream` (`0x0049C680`): what `emitter` sends out over the frame, by its template's
    /// rate at this point in its life, a roll a tick; each particle moved on as if it had left at
    /// the frame's start. Thinned as a burst is, but by its distance alone, from where it stood
    /// last. Whether the emitter still lives.
    pub fn stream(pool: *Pool, emitter: *Emitter, parent: ?camera.Place, view: camera.Place, clock: *const Clock, random: *libcmt.Rand) bool {
        const now = clock.frame_start;
        if (emitter.life + emitter.born <= now) return false;
        const template = emitter.template;
        const t = @as(f32, @floatFromInt(now - emitter.born)) / @as(f32, @floatFromInt(emitter.life));
        const chance = template.rate.at(t) * rate_scale;
        if (!(chance > 0) or clock.frame_duration <= 0) return true;
        var wanted: i32 = 0;
        for (0..@intCast(clock.frame_duration)) |_| {
            if (random.fraction() < chance) wanted += 1;
        }
        if (wanted == 0) return true;
        const offset = emitter.world.position - view.position;
        if (math.dot(offset, math.forward(view.orientation)) < 0) wanted = @divTrunc(wanted, 2);
        var left = math.round(@as(f32, @floatFromInt(wanted)) * template.share(math.length(offset)));
        emitter.place(parent);
        const ticks: Vector = @splat(@floatFromInt(clock.frame_duration));
        for (pool.particles, 0..) |particle, index| {
            if (left < 1) return true;
            const kind: Template.Kind = switch (template.kind) {
                .sometimes_sparks => if (random.rand() % 200 != 0) .particles else .sparks,
                else => |kind| kind,
            };
            switch (kind) {
                .particles => if (particle.born + particle.life <= now) {
                    pool.emit(emitter, index, clock, random);
                    _ = random.rand();
                    pool.sprites[index].offset += pool.particles[index].velocity * ticks;
                    left -= 1;
                },
                .sometimes_sparks, .sparks => {},
            }
        }
        return true;
    }

    /// A stream's rate, from hundredths (`0x004DC730`).
    const rate_scale: f32 = 0.01;

    /// `particles_frame` (`0x0049C8E0`), once a frame after the shots': each particle alive moves
    /// on by its velocity and takes its size and colour from its template's curves at this point
    /// in its life; the others are hidden, and the set drawn stops after the last alive.
    /// **Unverified:** it lies just after this file's known code.
    pub fn frame(pool: *Pool, clock: *const Clock) void {
        const now = clock.frame_start;
        const ticks: Vector = @splat(@floatFromInt(clock.frame_duration));
        var last: u32 = 0;
        for (pool.particles[0..pool.used], pool.sprites[0..pool.used], 0..) |particle, *sprite, index| {
            const template = particle.template orelse {
                sprite.hidden = true;
                continue;
            };
            if (!particle.alive(now)) {
                sprite.hidden = true;
                continue;
            }
            sprite.offset += particle.velocity * ticks;
            const t = @as(f32, @floatFromInt(now - particle.born)) / @as(f32, @floatFromInt(particle.life));
            const half = template.size.at(t);
            sprite.half_size = .{ half, half };
            sprite.colour = .{
                std.math.clamp(template.red.at(t), 0, 1),
                std.math.clamp(template.green.at(t), 0, 1),
                std.math.clamp(template.blue.at(t), 0, 1),
            };
            sprite.hidden = false;
            last = @intCast(index);
        }
        pool.used = last + 1;
        pool.set.sprites = pool.sprites[0..pool.used];
    }

    /// The rest of `particles_frame`: the set goes into the world's layer.
    pub fn draw(pool: *Pool, gpa: Allocator, scene: *srcore.Scene) Allocator.Error!void {
        if (pool.used == 0) return;
        try xtrabits.sceneAdd(gpa, scene, .{ .sprites = &pool.set }, .world);
    }
};

test Curve {
    const curve: Curve = .through(1, 0.25, 0);
    try std.testing.expectApproxEqAbs(1, curve.at(0), 1e-6);
    try std.testing.expectApproxEqAbs(0.25, curve.at(0.5), 1e-6);
    try std.testing.expectApproxEqAbs(0, curve.at(1), 1e-6);
}

const testing = struct {
    const template: Template = .{
        .life = 100,
        .size = .through(10, 20, 30),
        .red = .through(1, 0.5, 0),
        .green = .through(1, 1, 1),
        .blue = .through(0, 0, 0),
        .distance = 0,
    };

    fn pool() !Pool {
        var image: srtexture.Image = undefined;
        return .init(std.testing.allocator, 8, &image);
    }
};

test "Pool.burst" {
    var pool = try testing.pool();
    defer pool.deinit();
    var clock: Clock = .{};
    clock.frame_start = 10;
    var random: libcmt.Rand = .{};
    var emitter: Emitter = .init(&testing.template, &clock);
    emitter.position = .{ 0, 0, 1000 };
    emitter.spread = .{ 1, 1, 1 };
    emitter.speed = 5;
    emitter.inherited = .{ 0, 0, 1 };
    const view: camera.Place = .{ .position = @splat(0), .orientation = math.identity };

    // Ahead of the camera, the whole burst, each particle leaving where the emitter stands at its
    // speed plus what it inherits.
    pool.burst(&emitter, null, 3, view, &clock, &random);
    try std.testing.expectEqual(3, pool.used);
    try std.testing.expectEqual(Vector{ 0, 0, 1000 }, pool.sprites[0].offset);
    const own = pool.particles[0].velocity - emitter.inherited;
    try std.testing.expectApproxEqAbs(5, math.length(own), 1e-4);

    // Behind it, half; and never past the pool.
    emitter.position = .{ 0, 0, -1000 };
    pool.burst(&emitter, null, 20, view, &clock, &random);
    try std.testing.expectEqual(8, pool.used);

    // Hung from a parent, it stands where the parent puts it.
    pool.reset();
    emitter.position = .{ 0, 0, 10 };
    pool.burst(&emitter, .{ .position = .{ 100, 0, 0 }, .orientation = math.identity }, 1, view, &clock, &random);
    try std.testing.expectEqual(Vector{ 100, 0, 10 }, pool.sprites[0].offset);
}

test "Pool.frame" {
    var pool = try testing.pool();
    defer pool.deinit();
    var clock: Clock = .{};
    // A particle is free once its life is before the frame, so none is before the first tick.
    clock.frame_start = 1;
    var random: libcmt.Rand = .{};
    var emitter: Emitter = .init(&testing.template, &clock);
    const view: camera.Place = .{ .position = .{ 0, 0, -10 }, .orientation = math.identity };
    pool.burst(&emitter, null, 2, view, &clock, &random);
    pool.particles[0].velocity = .{ 1, 0, 0 };

    // Halfway through its life, a particle has moved on by its velocity, and takes the curves'
    // middles.
    clock.frame_start = 51;
    clock.frame_duration = 50;
    pool.frame(&clock);
    try std.testing.expectEqual(Vector{ 50, 0, 0 }, pool.sprites[0].offset);
    try std.testing.expectApproxEqAbs(20, pool.sprites[0].half_size[0], 1e-4);
    try std.testing.expectApproxEqAbs(0.5, pool.sprites[0].colour[0], 1e-6);
    try std.testing.expect(!pool.sprites[0].hidden);

    // Past it, both are hidden and the set drawn shrinks to one.
    clock.frame_start = 200;
    pool.frame(&clock);
    try std.testing.expect(pool.sprites[0].hidden and pool.sprites[1].hidden);
    try std.testing.expectEqual(1, pool.used);
}

test "Pool.stream" {
    var pool = try testing.pool();
    defer pool.deinit();
    var clock: Clock = .{};
    var random: libcmt.Rand = .{};
    var streaming = testing.template;
    streaming.rate = .through(100, 100, 100);
    var emitter: Emitter = .init(&streaming, &clock);
    emitter.life = 100;
    emitter.position = .{ 0, 0, 1 };
    emitter.world.position = .{ 0, 0, 1 };
    const view: camera.Place = .{ .position = @splat(0), .orientation = math.identity };

    // At a particle a tick for four ticks, four particles.
    clock.frame_duration = 4;
    try std.testing.expect(pool.stream(&emitter, null, view, &clock, &random));
    try std.testing.expectEqual(4, pool.used);

    // Once its life is over, it sends nothing and says so.
    clock.frame_start = 100;
    try std.testing.expect(!pool.stream(&emitter, null, view, &clock, &random));
}
