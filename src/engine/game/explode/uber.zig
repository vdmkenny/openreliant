//! `C:\lancer\game\explode.cpp`'s Uber Explode: the huge explosion the Huuuuuuuge Explosion order
//! sets off ([`aiexplode.huge`](../aiexplode.zig)), one at a time. Two halves of a sphere of fire
//! open out from where it goes off and fade, as two rings spread from it; then a ball of flame
//! spreads through what is near, knocking each ship it reaches spinning and setting it alight, as
//! burning bits fly at the camera, the view shakes and at last flashes white. At its end each ship
//! it reached is destroyed.
//!
//! The game also makes two squares, `UberWave1` over `bigshock1` and `UberWave2` over `bigshock2`,
//! and a light, `UberExplosion_Light`, and grows the first square as the blast goes on, but never
//! puts any of them in the scene; the port leaves them out.
//!
//! **Improvement:** the game opens the halves and spreads the ball by rounded factors (3.33333 and
//! 1.42857 a share, 0.19635 and 0.349066 radians); the port divides.
//!
//! Not ported: what a blast in a multiplayer game spares, counts and tells the players, which is
//! multiplayer's ([#55](https://github.com/vdmkenny/openreliant/issues/55)), and the event the
//! owner's explosion raises at the end (`event_post_explosion`, `0x0045AB50`), which needs the
//! mission's events ([#37](https://github.com/vdmkenny/openreliant/issues/37)).

const std = @import("std");
const Allocator = std.mem.Allocator;

const math = @import("../../surrender/math.zig");
const Vector = math.Vector;
const srapi = @import("../../surrender/surrenderlib/srapi.zig");
const srapiext = @import("../../surrender/surrenderlib/srapiext.zig");
const srcore = @import("../../surrender/surrenderlib/srcore.zig");
const srtexture = @import("../../surrender/surrenderlib/srtexture.zig");
const ai = @import("../ai.zig");
const aigeneric = @import("../aigeneric.zig");
const Slot = @import("../create.zig").Slot;
const explode = @import("../explode.zig");
const gameobj = @import("../gameobj.zig");
const matmanager = @import("../matmanager.zig");
const shield = @import("../shield.zig");
const shockwave = @import("../shockwave.zig");
const sound3d = @import("../sound3d.zig");
const xtrabits = @import("../xtrabits.zig");

/// The hemisphere both halves show (`uber_hemisphere_create`, `0x00473BF0`): the first `rings`
/// bands of a sphere on this grid, a ring each round a pole, and a last pole that no triangle uses.
const hemisphere: shield.Grid = .{ .around = 18, .down = 16 };
const rings = 7;
const hemisphere_vertices = rings * hemisphere.around + 2;

/// What the halves never colour: the last ring and the last pole.
const rim = hemisphere.around + 1;

/// The ball's sphere (`sphere_mesh_create`'s grid).
const ball_grid: shield.Grid = .{ .around = 18, .down = 8 };
const ball_vertices = ball_grid.vertices();

/// How far through a blast, as shares of its duration: the halves flare up until `flared`, open
/// out until `opened`, when the ball starts to spread, and fade out by `faded`, when the bits
/// start to fly; and the view flashes from `flash_from` (`0x004DC474`, `0x004DC4C0`, `0x004DC408`,
/// `0x004DC414`).
const flared: f32 = 0.05;
const opened: f32 = 0.3;
const faded: f32 = 0.5;
const flash_from: f32 = 0.95;

/// How far a blast reaches, by its size: the ships it lists stand within `reach`, as far as the ball
/// spreads to from `least_scale` (`0x004DC56C`); and the halves are drawn at `half_scale`
/// (`0x004DC854`).
const reach: f32 = 5;
const least_scale: f32 = 0.001;
const half_scale: f32 = 1.3;

/// How many ships a blast lists (`0x00562B88`).
pub const max_caught = 80;

/// The rings a blast sets off: so far across by its size, over a share of its duration
/// (`0x004DC848`, `0x004DC3D4`, `0x004DC400`, `0x004DC408`).
const Wave = struct { size: f32, life: f32 };
const waves = [_]Wave{ .{ .size = 16, .life = 0.25 }, .{ .size = 6, .life = 0.5 } };

/// The halves' alpha at full brightness, as they start (`0x004DC4C0`).
const half_alpha: f32 = 0.3;

/// How a half takes its texture from where each vertex lies across, halved and moved in by a half
/// (`0x004DC408`).
const half_mapping: f32 = 0.5;

/// The one point of the shield's texture the ball shows, from `opened` (a texel of the 128 square
/// `shield128`); and its green, a share of its red (`0x004DC4C0`).
const ball_texel: [2]f32 = .{ 45.0 / 128.0, 18.0 / 128.0 };
const ball_green: f32 = 0.3;

/// The ball's glow: red, twice as wide as the ball, sorted as if at its edge.
const glow_colour: [3]f32 = .{ 0.75, 0, 0 };
const glow_scale: f32 = 2;

/// How hard the ball knocks a ship, by its mass (`0x004DC438`); how far from its middle, by its
/// radius (`0x004DC4B4`); and how fast it sets it spinning, a tick about each axis, half of it
/// either way (`0x004DC4C0`).
const knock_strength: f32 = 2000;
const lever_share: f32 = 0.6;
const tumble: f32 = 0.3;

/// The fireballs the ball sets off about a ship: within half its radius, half its radius across,
/// `fireball_gap` ticks apart.
const fireballs = 5;
const fireball_share: f32 = 0.5;
const fireball_gap = 30;

/// How hard the view shakes as the ball spreads out, at its widest.
const most_shake: f32 = 2;

/// How many ticks the view flashes for, a share past `flash_from` (`0x004DC438`), which comes to a
/// full flash (`flash.flash_ticks`) at the end.
const flash_rate: f32 = 2000;

/// The burning bits flying at the camera a frame from `faded`: while the count thrown stays under
/// `bits_least` and a share of `bits_range` more, drawn afresh each time (`0x004DC850`); from
/// `bits_ahead` beyond the camera toward the blast, up to half of `bits_spread` off to each side
/// (`0x004DC84C`).
const bits_least = 12;
const bits_range: f32 = 13;
const bits_ahead: f32 = 10000;
const bits_spread: f32 = 4000;
const bits_throw: explode.Bit.Throw = .{ .size = 0.1, .speed = 1 };

/// The textures a blast shows.
pub const Images = struct {
    ring: *srtexture.Image,
    ball: *srtexture.Image,
    glow: *srtexture.Image,

    pub fn load(textures: *srtexture.Table) (Allocator.Error || matmanager.Error)!Images {
        return .{
            .ring = try matmanager.textureRequire(textures, "ring3"),
            .ball = try matmanager.textureRequire(textures, "shield128"),
            .glow = try matmanager.textureRequire(textures, "gunflare\\partic6"),
        };
    }
};

/// A ship a blast listed, and whether the ball has reached it (the game adds 1000 to its slot).
pub const Caught = struct {
    index: u16,
    reached: bool = false,
};

/// A blast going off.
pub const Blast = struct {
    /// Whose it is (`0x00558718`), where it went off, how far it reaches (`0x00558714`), and from
    /// when for how long (`0x0055870C`, `0x00558710`).
    owner: u16,
    place: math.Place,
    size: f32,
    started: i32,
    duration: i32,
    /// How far through it is at the frame's tick.
    done: f32 = 0,
    caught: [max_caught]Caught = undefined,
    caught_count: usize = 0,
    /// The halves (`UberHemi1`, `UberHemi2`), which share their own colours and texture
    /// coordinates.
    halves: [2]srapiext.MeshObject,
    half_colours: [hemisphere_vertices][4]f32,
    half_uv: [hemisphere_vertices][2]f32,
    /// The ball, which the game names as it names the second half, and its glow (`Uber BMO`).
    ball: srapiext.MeshObject,
    ball_colours: [ball_vertices][4]f32 = undefined,
    ball_uv: [ball_vertices][2]f32 = @splat(ball_texel),
    glow: srapiext.SpriteSet,
    glow_sprite: [1]srapiext.Sprite = .{.{ .colour = glow_colour }},

    fn listed(blast: *Blast) []Caught {
        return blast.caught[0..blast.caught_count];
    }

    /// The ball's part of the frame, `out` of the way to its widest: it takes the one point of its
    /// texture, grows, flickers red and orange vertex by vertex, and shakes the view, and it
    /// reaches each ship it listed that stands within it.
    fn spread(blast: *Blast, world: gameobj.World, out: f32) void {
        const random = world.random;
        // Two numbers the game draws and drops.
        _ = random.rand();
        _ = random.rand();
        blast.ball_uv = @splat(ball_texel);
        blast.ball.scale = math.lerp(least_scale, blast.size * reach, out);
        for (&blast.ball_colours) |*colour| {
            const f = random.fraction();
            const red = f * f * f * f * f;
            colour.* = .{ red, red * ball_green, 0, 1 };
        }
        world.shake.* = most_shake * out;
        blast.glow_sprite[0].half_size = @splat(blast.ball.scale * glow_scale);
        blast.glow_sprite[0].bias = -blast.ball.scale;
        for (blast.listed()) |*caught| if (!caught.reached) blast.strike(world, caught);
    }

    /// The ball reaching a ship it listed, unless the ship is exploding already or gone: a knock
    /// away from the blast, off its middle; a spin about each axis; five fireballs about it, one
    /// after another; and its orders dropped for Do Nothing.
    fn strike(blast: *const Blast, world: gameobj.World, caught: *Caught) void {
        const slot = &world.objects.slots[caught.index];
        const object = &slot.object;
        if (object.type == .stand_in) return;
        if (aigeneric.current(world.objects, caught.index)) |entry| if (entry.order == .explode) return;
        if (math.distance(slot.drawn.position, blast.place.position) > blast.ball.scale) return;
        const random = world.random;
        const centre = gameobj.vector(object.root.position);
        const push = math.normalize(centre - blast.place.position) * @as(Vector, @splat(object.mass * knock_strength));
        const lever = math.transform(math.fromAngleVector(random.fractionVector(@splat(std.math.tau))), .{ 0, 0, object.radius * lever_share });
        object.rotation = math.fromAngleVector(random.centredVector(@splat(tumble)));
        gameobj.knock(object, push, lever + centre);
        for (0..fireballs) |n| {
            const at = random.centredVector(@splat(object.radius)) + slot.drawn.position;
            explode.fireballAt(world, at, .{ .size = object.radius * fireball_share, .light = true, .delay = @intCast(n * fireball_gap) });
        }
        const ctx: aigeneric.Context = .{ .world = world, .clock = world.clock };
        aigeneric.popAll(ctx, caught.index);
        _ = aigeneric.push(ctx, caught.index, .do_nothing, .none) catch {};
        caught.reached = true;
    }

    /// The burning bits a frame from `faded`: each from a point `bits_ahead` beyond the camera
    /// toward the blast, flying at the camera.
    fn throwBits(blast: *const Blast, world: gameobj.World) void {
        const seen = world.camera orelse return;
        const eye = seen.place.position;
        const toward = math.lookAt(blast.place.position - eye);
        const random = world.random;
        var thrown: i32 = 0;
        while (thrown < bits_least + @as(i32, @intFromFloat(random.fraction() * bits_range))) : (thrown += 1) {
            const y = random.centred() * bits_spread;
            const x = random.centred() * bits_spread;
            const from = math.transform(toward, .{ x, y, bits_ahead }) + eye;
            explode.throwBit(world, from, math.normalize(eye - blast.place.position), bits_throw);
        }
    }
};

/// What the Uber Explode keeps: the hemisphere the halves share (`0x00562CD0`), which a blast opens
/// out, the ball's sphere, and the blast going off, where one is.
pub const Uber = struct {
    hemisphere: srapiext.Mesh,
    ball: srapiext.Mesh,
    levels: [2][1]srapiext.Level = undefined,
    glow: *srtexture.Image,
    blast: ?Blast = null,

    /// As the explosions are set up (`explosions_init`, `0x0046B240`): the hemisphere, fully open,
    /// and the ball's sphere.
    pub fn create(gpa: Allocator, images: Images) Allocator.Error!*Uber {
        const uber = try gpa.create(Uber);
        errdefer gpa.destroy(uber);
        var half = try hemisphereMesh(gpa, images.ring);
        errdefer half.deinit(gpa);
        uber.* = .{ .hemisphere = half, .ball = try shield.sphereMesh(gpa, ball_grid, images.ball), .glow = images.glow };
        uber.levels = .{ .{.{ .mesh = &uber.hemisphere, .until = std.math.inf(f32) }}, .{.{ .mesh = &uber.ball, .until = std.math.inf(f32) }} };
        return uber;
    }

    pub fn destroy(uber: *Uber, gpa: Allocator) void {
        uber.hemisphere.deinit(gpa);
        uber.ball.deinit(gpa);
        gpa.destroy(uber);
    }

    /// `uber_explode_start` (`0x00472AB0`): sets a blast of `size` off at `place` for `owner`, over
    /// `duration` ticks, in place of any going off. It lists the ships it may reach: each object
    /// but the player's ship that is created and not disabled, of a side but the neutral one, with
    /// combat stats and an order, but for the gates, the Boridin and its breakaway, and within
    /// `reach` of its size. Its halves start at the point, dark and faint, but for their rims, which
    /// never show, each taking its texture from where its vertices lie; the second is turned half
    /// round. The view flashes, the two rings of `waves` spread, and the owner's ship sounds
    /// `uberexp`.
    ///
    /// The game asks for an order stack, which it makes with an object's first order; the port asks
    /// for an order.
    ///
    /// **Fix:** the game lists every ship in reach, running past the end of its list with more than
    /// `max_caught`; the port lists the first `max_caught`.
    pub fn start(uber: *Uber, world: gameobj.World, owner: u16, place: math.Place, size: f32, duration: i32) void {
        const half: srapiext.MeshObject = .{
            .flags = .{ .not_culled = true, .always_drawn = true, .unbounded = true, .baked_object = true, .own_first = true },
            .position = place.position,
            .orientation = place.orientation,
            .radius = uber.hemisphere.radius,
            .levels = &uber.levels[0],
        };
        uber.blast = .{
            .owner = owner,
            .place = place,
            .size = size,
            .started = world.clock.frame_start,
            .duration = duration,
            .halves = .{ half, half },
            .half_colours = @splat(.{ 0, 0, 0, half_alpha }),
            .half_uv = undefined,
            .ball = .{ .flags = half.flags, .position = place.position, .orientation = place.orientation, .radius = 1, .levels = &uber.levels[1] },
            .glow = .{ .position = place.position, .sprites = &.{} },
        };
        const blast = &uber.blast.?;
        blast.halves[1].orientation = math.product(math.fromAngles(0, std.math.pi, 0), place.orientation);
        blast.half_colours[hemisphere_vertices - rim ..].* = @splat(@splat(0));
        for (&blast.half_uv, uber.hemisphere.positions) |*uv, at| uv.* = .{ at[0] * half_mapping + half_mapping, at[1] * half_mapping + half_mapping };
        for (&blast.halves) |*shown| {
            shown.baked = &blast.half_colours;
            shown.own_uv = .{ &blast.half_uv, null };
        }
        blast.ball.baked = &blast.ball_colours;
        blast.ball.own_uv = .{ &blast.ball_uv, null };
        blast.glow.surface = .{
            .material = .onePass(.{ .coordinates = .mesh, .lit = true, .blend = .add }),
            .textures = .{ .{ .image = uber.glow }, .none },
        };
        blast.glow.sprites = &blast.glow_sprite;

        const all = world.objects;
        for (all.slots[0..all.count], 0..) |*slot, index| {
            if (blast.caught_count == max_caught) break;
            if (index == all.player or !catches(slot, place.position, size)) continue;
            blast.caught[blast.caught_count] = .{ .index = @intCast(index) };
            blast.caught_count += 1;
        }

        if (world.flash) |flash| flash.start();
        for (waves) |wave| shockwave.setOff(world, place, .{
            .kind = .uber,
            .size = size * wave.size,
            .life = @intFromFloat(@as(f32, @floatFromInt(duration)) * wave.life),
            .owner = owner,
        });
        sound3d.playIn(world, null, null, owner, .uberexp, 1, .guaranteed);
    }

    /// Whether a blast of `size` at `at` lists the object in `slot`.
    fn catches(slot: *const Slot, at: Vector, size: f32) bool {
        const object = &slot.object;
        if (object.flags.disabled or !object.created or object.order_count == 0) return false;
        const combat = slot.combat orelse return false;
        if (combat.side == .neutral) return false;
        switch (object.type) {
            .proto_gate, .advanced_gate, .boridin, .boridin_breakaway => return false,
            else => {},
        }
        return math.distance(slot.drawn.position, at) <= size * reach;
    }

    /// `uber_explode_update` (`0x00473210`), first in `explosions_update`: once its duration is
    /// past the blast ends (`end`). Until `faded` the halves grow to `half_scale` of its size,
    /// open out until `opened`, and brighten and fade by `brightness`; from `opened` the ball
    /// spreads (`Blast.spread`); from `flash_from` the view flashes longer and longer; and from
    /// `faded` burning bits fly at the camera (`Blast.throwBits`).
    ///
    /// **Fix:** the game colours one vertex of the halves' rims with the rest, which shows a sliver
    /// of the rim; the port keeps the whole rim clear, as the blast starts it.
    pub fn frame(uber: *Uber, world: gameobj.World) void {
        const blast = &(uber.blast orelse return);
        const now = world.clock.frame_start;
        if (blast.started + blast.duration < now) return uber.end(world);
        const done = @as(f32, @floatFromInt(now - blast.started)) / @as(f32, @floatFromInt(blast.duration));
        blast.done = done;
        if (done < faded) {
            for (&blast.halves) |*half| half.scale = blast.size * half_scale;
            if (done < opened) open(uber.hemisphere.positions, done / opened);
            const bright = brightness(done);
            for (blast.half_colours[0 .. hemisphere_vertices - rim]) |*colour| colour.* = .{ bright, bright, bright, bright * half_alpha };
        }
        if (done > opened) blast.spread(world, (done - opened) / (1 - opened));
        if (done > flash_from) if (world.flash) |flash| {
            flash.left = @intFromFloat((done - flash_from) * flash_rate);
        };
        if (done > faded) blast.throwBits(world);
    }

    /// The blast's end: it goes (`uber_explode_free`, `0x004731A0`), its owner's ship sounds
    /// `capexp`, and each ship the ball reached stops turning and, unless it is exploding already,
    /// is destroyed, neither spinning nor ejecting.
    fn end(uber: *Uber, world: gameobj.World) void {
        const blast = &uber.blast.?;
        defer uber.blast = null;
        sound3d.playIn(world, null, null, blast.owner, .capexp, 1, .player_fx);
        const ctx: aigeneric.Context = .{ .world = world, .clock = world.clock };
        for (blast.listed()) |caught| {
            if (!caught.reached) continue;
            const object = &world.objects.slots[caught.index].object;
            object.rotation = math.identity;
            object.roll_rate = 0;
            object.pitch_rate = 0;
            object.yaw_rate = 0;
            const entry = aigeneric.current(world.objects, caught.index) orelse continue;
            if (entry.order != .explode) ai.objectDestroyed(ctx, caught.index, false, true);
        }
    }

    /// The blast's objects, in the world's layer: the halves until `faded`, and the ball and its
    /// glow from `opened`.
    pub fn draw(uber: *Uber, gpa: Allocator, scene: *srcore.Scene) Allocator.Error!void {
        const blast = &(uber.blast orelse return);
        if (blast.done < faded) for (&blast.halves) |*half| try xtrabits.sceneAdd(gpa, scene, .{ .mesh = half }, .world);
        if (blast.done > opened) {
            try xtrabits.sceneAdd(gpa, scene, .{ .mesh = &blast.ball }, .world);
            try xtrabits.sceneAdd(gpa, scene, .{ .sprites = &blast.glow }, .world);
        }
    }
};

/// How bright the halves are `done` of the way through a blast: up from nothing until `flared`,
/// full until `opened`, then down to nothing at `faded`.
fn brightness(done: f32) f32 {
    if (done <= flared) return done / flared;
    if (done <= opened) return 1;
    return 1 - (done - opened) / (faded - opened);
}

/// `uber_hemisphere_open` (`0x00473EA0`): lays the hemisphere out `share` of the way open, of a
/// unit radius, its pole at the origin and its bowl toward -Z: each ring `share` of a band of
/// `hemisphere` further round from the pole than the last. Shut, it is a point.
fn open(positions: []Vector, share: f32) void {
    const step = share * std.math.pi / @as(f32, hemisphere.down);
    for (0..rings + 2) |ring| {
        const angle = @as(f32, @floatFromInt(ring)) * step;
        const across = @sin(angle);
        const depth = @cos(angle) - 1;
        if (ring == 0 or ring == rings + 1) {
            positions[if (ring == 0) 0 else hemisphere_vertices - 1] = .{ 0, 0, depth };
            continue;
        }
        for (0..hemisphere.around) |slice| {
            const round = @as(f32, @floatFromInt(slice)) * std.math.tau / @as(f32, hemisphere.around);
            positions[hemisphere.ring(ring, slice)] = .{ @sin(round) * across, @cos(round) * across, depth };
        }
    }
}

/// `uber_hemisphere_create` (`0x00473BF0`): the hemisphere, fully open, over `image`: lit, blended
/// over what is behind it, and coloured and mapped by its objects' own colours and coordinates.
///
/// Not ported: its vertices' normals, which nothing lights.
fn hemisphereMesh(gpa: Allocator, image: *srtexture.Image) Allocator.Error!srapiext.Mesh {
    const triangles = hemisphere.triangles(rings);
    var mesh: srapiext.Mesh = try .create(gpa, .{ .polygons = triangles, .vertices = hemisphere_vertices, .indices = triangles * 3 });
    errdefer mesh.deinit(gpa);
    open(mesh.positions, 1);
    hemisphere.corners(rings, mesh.indices);
    mesh.numberPolygons(3);
    mesh.surfaces[0] = .{
        .polygons = @intCast(triangles),
        .material = .onePass(.{ .coordinates = .generated, .lit = true, .blend = .premultiplied }),
        .textures = .{ .{ .image = image }, .none },
    };
    srapi.calcPolyNormals(&mesh);
    srapi.findBoundingBox(&mesh);
    return mesh;
}

pub const testing = struct {
    var ring: srtexture.Image = .{ .levels = &.{} };
    var ball: srtexture.Image = .{ .levels = &.{} };
    var glow: srtexture.Image = .{ .levels = &.{} };

    pub fn images() Images {
        return .{ .ring = &ring, .ball = &ball, .glow = &glow };
    }
};

test hemisphereMesh {
    const gpa = std.testing.allocator;
    var mesh = try hemisphereMesh(gpa, testing.images().ring);
    defer mesh.deinit(gpa);
    // A fan round the pole and six bands, 234 triangles over 128 vertices, every corner one of them.
    try std.testing.expectEqual(234, mesh.polygons.len);
    try std.testing.expectEqual(128, mesh.positions.len);
    for (mesh.indices) |corner| try std.testing.expect(corner < hemisphere_vertices - 1);
    // Fully open, the pole at the origin and the last ring near the rim, a unit round, a unit down.
    try std.testing.expectEqual(@as(Vector, @splat(0)), mesh.positions[0]);
    const last = mesh.positions[hemisphere.ring(rings, 0)];
    try std.testing.expectApproxEqAbs(@sin(7 * std.math.pi / 16.0), last[1], 1e-5);
    try std.testing.expectApproxEqAbs(@cos(7 * std.math.pi / 16.0) - 1, last[2], 1e-5);

    // Shut, it is a point; half open, its last ring is half as far round.
    open(mesh.positions, 0);
    for (mesh.positions) |at| try std.testing.expectEqual(@as(Vector, @splat(0)), at);
    open(mesh.positions, 0.5);
    try std.testing.expectApproxEqAbs(@cos(3.5 * std.math.pi / 16.0) - 1, mesh.positions[hemisphere.ring(rings, 3)][2], 1e-5);
}

test brightness {
    try std.testing.expectEqual(0, brightness(0));
    try std.testing.expectApproxEqAbs(0.5, brightness(flared / 2), 1e-6);
    try std.testing.expectEqual(1, brightness(0.2));
    try std.testing.expectApproxEqAbs(0.5, brightness(0.4), 1e-5);
    try std.testing.expectApproxEqAbs(0, brightness(faded), 1e-6);
}

test Uber {
    const gpa = std.testing.allocator;
    var stage: explode.testing.Stage = undefined;
    try stage.init();
    defer stage.deinit();
    const srmesh = @import("../../surrender/surrenderlib/srmesh.zig");
    const mesh = try srmesh.testing.square(gpa);
    defer mesh.deinit(gpa);
    stage.explosions.debris = explode.testing.debris(&mesh);
    var built: shockwave.testing.Built = try .init(gpa);
    defer built.deinit(gpa);
    var watching: @import("../camera.zig").Camera = .{};
    watching.place.position = .{ 0, 0, -50000 };
    var world = stage.world();
    world.shockwaves = &built.waves;
    world.camera = &watching;
    const all = world.objects;
    const ctx: aigeneric.Context = .{ .world = world, .clock = world.clock };
    const uber = stage.explosions.uber;

    // The player's ship, which it spares; a ship near; one out of reach; and a gate.
    const player = try stage.mission.add(.predator, @splat(0));
    const near = try stage.mission.add(.sabre, .{ 0, 0, 30000 });
    const far = try stage.mission.add(.sabre, .{ 0, 0, 6000 });
    const gate = try stage.mission.add(.proto_gate, .{ 0, 0, 1000 });
    _ = player;
    for ([_]u16{ near, far, gate }) |index| _ = try aigeneric.push(ctx, index, .do_nothing, .none);
    const size: f32 = 1000;
    all.slots[far].drawn.position = .{ 0, 0, size * reach + 1 };
    all.slots[near].drawn.position = .{ 0, 0, 3000 };
    all.slots[near].object.root.position = gameobj.vec3(.{ 0, 0, 3000 });
    stage.mission.clock.frame_start = 1000;
    uber.start(world, 0, .{ .position = @splat(0) }, size, 1000);
    const blast = &uber.blast.?;
    try std.testing.expectEqual(1, blast.caught_count);
    try std.testing.expectEqual(near, blast.caught[0].index);
    // Its halves start dark and faint, their rims clear; the rings spread.
    try std.testing.expectEqual([4]f32{ 0, 0, 0, half_alpha }, blast.half_colours[0]);
    try std.testing.expectEqual([4]f32{ 0, 0, 0, 0 }, blast.half_colours[hemisphere_vertices - rim]);
    try std.testing.expectEqual(.uber, built.waves.waves[0].?.kind);
    try std.testing.expectEqual(size * waves[1].size, built.waves.waves[1].?.size);

    // A fifth of the way through, the halves are grown and bright, the rims still clear, and the
    // ball is yet to show.
    stage.mission.clock.frame_start = 1200;
    uber.frame(world);
    try std.testing.expectEqual(size * half_scale, blast.halves[1].scale);
    try std.testing.expectEqual([4]f32{ 1, 1, 1, half_alpha }, blast.half_colours[hemisphere_vertices - rim - 1]);
    try std.testing.expectEqual([4]f32{ 0, 0, 0, 0 }, blast.half_colours[hemisphere_vertices - rim]);
    var scene: srcore.Scene = .{};
    defer scene.deinit(gpa);
    try uber.draw(gpa, &scene);
    try std.testing.expectEqual(2, scene.layers.get(.world).items.len);

    // Near the end, the ball has spread past the near ship: knocked, spinning, alight and doing
    // nothing; and burning bits fly at the camera.
    stage.mission.clock.frame_start = 1900;
    uber.frame(world);
    try std.testing.expect(explode.testing.flying(&stage.explosions) >= bits_least);
    try std.testing.expect(blast.caught[0].reached);
    const struck = &all.slots[near].object;
    try std.testing.expectEqual(.do_nothing, aigeneric.current(all, near).?.order);
    try std.testing.expect(struck.knocks > 0);
    try std.testing.expect(stage.explosions.fireballs[0] != null);
    try std.testing.expect(world.shake.* > 0);

    // At its end the ship it reached is destroyed, and the blast is gone.
    stage.mission.clock.frame_start = 2001;
    uber.frame(world);
    try std.testing.expectEqual(null, uber.blast);
    try std.testing.expectEqual(.explode, aigeneric.current(all, near).?.order);
    try std.testing.expectEqual(.do_nothing, aigeneric.current(all, far).?.order);
}
