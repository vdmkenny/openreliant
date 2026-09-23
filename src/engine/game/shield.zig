//! `C:\lancer\game\shield.cpp`: a ship's shields as they are seen, a bubble round the ship that
//! ripples out from where a shot or a knock struck them. **Unverified:** the bubble's meshes and
//! colours (`0x0049E370` to `0x0049EF60`) lie before this file's path, after the 3D sounds' code.
//!
//! Not ported: the shields of a ship that lists components, which flare on the part struck, and
//! its force fields (`0x0049F4A0` to `0x0049FCD0`)
//! ([#179](https://github.com/vdmkenny/openreliant/issues/179)).

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const math = @import("../surrender/math.zig");
const Vector = math.Vector;
const srapi = @import("../surrender/surrenderlib/srapi.zig");
const srapiext = @import("../surrender/surrenderlib/srapiext.zig");
const srcore = @import("../surrender/surrenderlib/srcore.zig");
const srtexture = @import("../surrender/surrenderlib/srtexture.zig");
const libcmt = @import("../libcmt.zig");
const Objects = @import("create.zig").Objects;
const Detail = @import("explode.zig").Detail;
const gameobj = @import("gameobj.zig");
const matmanager = @import("matmanager.zig");
const sparks = @import("sparks.zig");
const xtrabits = @import("xtrabits.zig");

/// A sphere's grid: its slices round the axis through its poles, and its bands from pole to pole.
const Grid = struct {
    around: u16,
    down: u16,

    fn vertices(grid: Grid) usize {
        return (@as(usize, grid.down) - 1) * grid.around + 2;
    }

    fn triangles(grid: Grid) usize {
        return (@as(usize, grid.down) - 1) * grid.around * 2;
    }

    /// Vertex `index` of a sphere of a unit radius on the grid: the pole on +Z first, then each
    /// band's ring in turn, then the pole on -Z (`0x0049E3D0`).
    fn vertex(grid: Grid, index: usize) Vector {
        if (index == 0) return .{ 0, 0, 1 };
        if (index == grid.vertices() - 1) return .{ 0, 0, -1 };
        const band: f32 = @floatFromInt(1 + (index - 1) / grid.around);
        const slice: f32 = @floatFromInt((index - 1) % grid.around);
        const down = band * std.math.pi / @as(f32, @floatFromInt(grid.down));
        const round = slice * 2 * std.math.pi / @as(f32, @floatFromInt(grid.around));
        return .{ @sin(round) * @sin(down), @cos(round) * @sin(down), @cos(down) };
    }

    /// Vertex `slice` of the ring round band `band`, from 1.
    fn ring(grid: Grid, band: usize, slice: usize) u16 {
        return @intCast(1 + (band - 1) * grid.around + slice % grid.around);
    }

    /// The sphere's triangles, three corners each, band by band as `0x0049E3D0` lays them: a fan
    /// round each pole, and two triangles to each slice of each band between.
    fn corners(grid: Grid, out: []u16) void {
        const last: u16 = @intCast(grid.vertices() - 1);
        var at: usize = 0;
        for (0..grid.down) |band| {
            for (0..grid.around) |slice| {
                const triangle: [3]u16 = if (band == 0)
                    .{ 0, grid.ring(1, slice + 1), grid.ring(1, slice) }
                else if (band == grid.down - 1)
                    .{ grid.ring(band, grid.around - 1 - slice), grid.ring(band, 2 * grid.around - 2 - slice), last }
                else
                    .{ grid.ring(band, slice), grid.ring(band, slice + 1), grid.ring(band + 1, slice) };
                @memcpy(out[at..][0..3], &triangle);
                at += 3;
            }
            if (band == 0 or band == grid.down - 1) continue;
            for (0..grid.around) |slice| {
                const triangle: [3]u16 = .{ grid.ring(band, slice + 1), grid.ring(band + 1, slice + 1), grid.ring(band + 1, slice) };
                @memcpy(out[at..][0..3], &triangle);
                at += 3;
            }
        }
        assert(at == out.len);
    }
};

/// The bubble's levels of detail, finest first (`0x00593730`), and each one's grid (`0x0050884C`).
pub const level_count = 6;
const grids = [level_count]Grid{
    .{ .around = 16, .down = 14 },
    .{ .around = 12, .down = 10 },
    .{ .around = 10, .down = 8 },
    .{ .around = 8, .down = 6 },
    .{ .around = 6, .down = 4 },
    .{ .around = 4, .down = 4 },
};

/// The vertices of the finest level, which a bubble keeps its strengths, colours and texture
/// coordinates for.
const max_vertices = grids[0].vertices();

comptime {
    for (grids[1..]) |grid| assert(grid.vertices() <= max_vertices);
}

/// How far from the camera each level of detail is drawn out to, by the options' detail
/// (`0x0050887C`, into `0x00593734`). A struck bubble further off than the last isn't drawn.
const reaches: std.EnumArray(Detail, [level_count]f32) = .init(.{
    .low = .{ 1250, 2500, 5000, 10000, 20000, 40000 },
    .medium = .{ 2500, 5000, 10000, 20000, 40000, 80000 },
    .high = .{ 10000, 20000, 40000, 80000, 160000, 320000 },
});

/// The bubble's look: coloured by its vertices, over the shield's texture with its own texture
/// coordinates, adding to what is behind it.
const bubble_material: srapiext.Material = .onePass(.{ .coordinates = .generated, .lit = true, .blend = .add });

/// Which colours a bubble glows in: the ship type's side, friendly or not (`+0x40`).
pub const Tint = enum { friendly, other };

/// The steps of each tint's ramp (`0x0058CB6C` for a friendly ship's, `0x00590728` for the
/// others'), a colour for each strength from nothing up to one.
const ramp_steps = 1024;
const Colour = @Vector(3, f32);
const Ramp = [ramp_steps]Colour;

/// How bright a step of the ramp is at most (`0x0049EB00`), and what share of that the others'
/// green and blue get (`0x0049EC30`).
const ramp_brightness: f32 = 0.07;
const other_share: f32 = 0.8;

/// `0x004268C0`: from `a` to `b` as `share` goes from 0 to 1, slow at each end. It lies among the
/// interface's code, between `wgate.cpp`'s and `interf.cpp`'s, and serves much of it; the port
/// keeps it here, with the one routine that uses it so far.
///
/// **Improvement:** the cosine comes from `std.math` rather than the engine's table (`sr_cos`).
fn ease(a: f32, b: f32, share: f32) f32 {
    return a + (b - a) * (1 - @cos(share * std.math.pi)) / 2;
}

/// `0x0049EB00` and `0x0049EC30`: a ramp's colour at `strength`, as red, green and blue. A friendly
/// ship's runs from nothing at 1 up to a cyan of 0.7 green and full blue at 0.6, down through a dim
/// blue at 0.4 to nothing below 0.35; without a hardware renderer it is grey. The others' swaps the
/// green and blue, at 0.8 of the strength.
fn rampColour(tint: Tint, strength: f32, hardware: bool) Colour {
    var colour: Colour = @splat(0);
    if (strength > 0.6) {
        const share = (1 - strength) / 0.4;
        colour = .{ 0, ease(0, 0.7, share), ease(0, 1, share) };
    } else if (strength > 0.4) {
        const share = (0.6 - strength) / 0.2;
        colour = .{ 0, ease(0.7, 0, share), ease(1, 0.3, share) };
    } else if (strength > 0.35) {
        colour = .{ 0, 0, ease(0.3, 0, (0.6 - strength) / 0.6) };
    }
    const tinted: Colour = switch (tint) {
        .friendly => if (hardware) colour else @splat(colour[2]),
        .other => .{ 0, colour[2] * other_share, colour[1] * other_share },
    };
    return tinted * @as(Colour, @splat(ramp_brightness));
}

/// `0x0049EE40`: a tint's ramp, a step for each 1024th of the strength.
fn buildRamp(tint: Tint, hardware: bool) Ramp {
    var ramp: Ramp = undefined;
    for (&ramp, 0..) |*step, index| step.* = rampColour(tint, @as(f32, @floatFromInt(index)) / ramp_steps, hardware);
    return ramp;
}

/// `0x0049ED60` and `0x0049EDD0`: the ramp's colour at a strength strictly between nothing and
/// one; nothing outside.
fn rampAt(ramp: *const Ramp, strength: f32) Colour {
    if (!(strength > 0 and strength < 1)) return @splat(0);
    const step: usize = @intFromFloat(@floor(strength * (ramp_steps - 1)));
    return ramp[step];
}

/// A bubble's size over its ship's radius (`0x004DC7C4`).
const bubble_scale: f32 = 1.1;

/// How many hits a bubble keeps, the next taking the place of the oldest.
const hit_slots = 8;

/// What a hit leaves at a vertex: half at the point struck, one more for each 1.2 radians off it,
/// out to `hit_reach` (`0x004DC9E0`) and no more than `max_strength` (`0x004DC480`). A vertex
/// shows only while its strength is below one, so the colour ripples out from the point struck as
/// the strengths fade by `fade_per_tick` (`0x004DC53C`).
const struck_strength: f32 = 0.5;
const strength_spread: f32 = 1.2;
const hit_reach: f32 = 1.4;
const max_strength: f32 = 2;
const fade_per_tick: f32 = 0.025;

/// How long after its last hit a bubble is drawn (`0x004DC440`).
const shown_for = 100;

/// Where a bubble's texture starts swirling about, how fast it swirls, over the square of how far
/// a vertex's coordinates are from there (`0x004DC9CC`), and how fast that point turns about the
/// texture's corner (`0x004DC688`), each a tick.
const start_centre: [2]f32 = .{ 0.3, 0.3 };
const swirl_per_tick: f32 = 1e-5;
const centre_turn_per_tick: f32 = 1e-4;

/// How long a bubble flickers as a force field (`shockwaves_update`), and how often a frame of it
/// is lit: one in this many.
const flicker_for = 100;
const flicker_odds = 4;

/// The bubbles' meshes, colours and textures (`0x0049EF10`), which every bubble shares.
pub const Shields = struct {
    meshes: [level_count]srapiext.Mesh,
    /// Each mesh as a single level of detail, which the bubbles drawn point at.
    levels: [level_count][1]srapiext.Level = undefined,
    ramps: std.EnumArray(Tint, Ramp),
    /// How far from the camera each level is drawn out to.
    reaches: [level_count]f32,
    /// `shield128`, which a bubble is drawn over (`0x0058CB68`), and `ffield`, which one flickering
    /// as a force field is (`0x0059372C`).
    texture: *srtexture.Image,
    field: *srtexture.Image,

    /// `0x0049EF10`: the textures, each tint's ramp, and the levels' spheres (`0x0049EE90`), at the
    /// options' detail. The ramps are grey without a hardware renderer.
    pub fn create(gpa: Allocator, textures: *srtexture.Table, detail: Detail, hardware: bool) (Allocator.Error || matmanager.Error)!Shields {
        const texture = try matmanager.textureRequire(textures, "shield128");
        const field = try matmanager.textureRequire(textures, "ffield");
        var meshes: [level_count]srapiext.Mesh = undefined;
        var built: usize = 0;
        errdefer for (meshes[0..built]) |mesh| mesh.deinit(gpa);
        for (&meshes, grids) |*mesh, grid| {
            mesh.* = try sphereMesh(gpa, grid, texture);
            built += 1;
        }
        return .{
            .meshes = meshes,
            .ramps = .init(.{ .friendly = buildRamp(.friendly, hardware), .other = buildRamp(.other, hardware) }),
            .reaches = reaches.get(detail),
            .texture = texture,
            .field = field,
        };
    }

    /// `0x0049EF60`: the meshes let go.
    pub fn deinit(shields: *Shields, gpa: Allocator) void {
        for (shields.meshes) |mesh| mesh.deinit(gpa);
    }

    /// The level of detail for a bubble `distance` from the camera, or null past the last.
    fn levelAt(shields: *const Shields, distance: f32) ?usize {
        for (shields.reaches, 0..) |reach, level| {
            if (distance < reach) return level;
        }
        return null;
    }

    /// What the bubbles' pass needs of the frame.
    pub const Look = struct {
        /// Where the camera is.
        camera: Vector,
        /// Whether the camera is in the player's cockpit (`camera.inCockpit`).
        inside: bool,
        frame_start: i32,
        /// While the game is paused (`0x0057E04C`), the bubbles' colours stand still.
        paused: bool = false,
        /// The runtime's numbers (`libcmt.Rand`), which a force field flickers by; without them it
        /// stays dark.
        random: ?*libcmt.Rand,
    };

    /// `0x0049F0A0`, once a frame (`mission_frame`): the bubble of each ship struck in the last
    /// `shown_for` ticks, into the world's layer, at the level of detail its distance from the
    /// camera gives, save the player's while the camera is in its cockpit. Each bubble's colours and
    /// texture move on by the ticks since they last did (`0x0049F450`, `shield_bubble_update`).
    ///
    /// **Improvement:** a bubble past the last level's reach is left out; the game stops the pass
    /// there, leaving out every bubble in the slots after it.
    ///
    /// The game moves a bubble's colours on as the renderer draws it; the port as it goes into the
    /// scene, so one out of view still fades.
    pub fn draw(shields: *Shields, gpa: Allocator, scene: *srcore.Scene, all: *Objects, look: Look) Allocator.Error!void {
        for (&shields.levels, &shields.meshes) |*level, *mesh| level.* = .{.{ .mesh = mesh, .until = std.math.inf(f32) }};
        for (&all.slots, 0..) |*slot, index| {
            if (slot.object.type == .stand_in) continue;
            const bubble = slot.shield orelse continue;
            const struck = bubble.struck orelse continue;
            const since = look.frame_start -% struck;
            if (since < 0 or since > shown_for) continue;
            bubble.level = shields.levelAt(math.distance(gameobj.vector(slot.object.root.position), look.camera)) orelse continue;
            if (index == all.player and look.inside) continue;
            if (!look.paused) {
                const ticks = if (bubble.updated) |updated| look.frame_start -% updated else 0;
                bubble.update(shields, ticks, look.frame_start, look.random);
                bubble.updated = look.frame_start;
            }
            bubble.object.levels = &shields.levels[bubble.level];
            bubble.object.position = slot.drawn.position;
            bubble.object.orientation = slot.drawn.orientation;
            try xtrabits.sceneAdd(gpa, scene, .{ .mesh = &bubble.object }, .world);
        }
    }
};

/// `0x0049E3D0`: a sphere of a unit radius on `grid`, over `image`.
///
/// Not ported: its vertices' normals, which nothing lights.
fn sphereMesh(gpa: Allocator, grid: Grid, image: *srtexture.Image) Allocator.Error!srapiext.Mesh {
    const triangles = grid.triangles();
    var mesh: srapiext.Mesh = try .create(gpa, .{ .polygons = triangles, .vertices = grid.vertices(), .indices = triangles * 3 });
    errdefer mesh.deinit(gpa);
    for (mesh.positions, 0..) |*position, index| position.* = grid.vertex(index);
    grid.corners(mesh.indices);
    mesh.numberPolygons(3);
    mesh.surfaces[0] = .{ .polygons = @intCast(triangles), .material = bubble_material, .textures = .{ .{ .image = image }, .none } };
    srapi.calcPolyNormals(&mesh);
    srapi.findBoundingBox(&mesh);
    return mesh;
}

/// A ship's shield bubble (`0x0049EF90`, 0x48 bytes), which `create_object` makes for a ship that
/// lists no components and is not debris, and which hangs from the ship's frame.
pub const Bubble = struct {
    /// Its scene object (`+0x04`, `0x0049E370`), scaled to `bubble_scale` of the ship's radius,
    /// coloured by `colours` and textured by `uv`.
    object: srapiext.MeshObject,
    /// When its colours last moved on (`+0x08`), or null before its first drawing, which moves
    /// them by nothing. The game stamps it with the tick the bubble is made.
    updated: ?i32 = null,
    /// When a shot or a knock last struck it (`+0x0C`), or null for never.
    struck: ?i32 = null,
    /// Where its texture swirls about (`+0x10`).
    centre: [2]f32 = start_centre,
    /// What each of its last hits leaves at each vertex (`+0x18`), and which the next takes
    /// (`+0x38`).
    hits: [hit_slots][max_vertices]f32 = @splat(@splat(0)),
    next: std.math.IntFittingRange(0, hit_slots - 1) = 0,
    /// The level of detail it is drawn at (`+0x3C`).
    level: usize = 0,
    tint: Tint,
    /// Until when it flickers as a force field (`+0x44`), or null.
    flicker_until: ?i32 = null,
    /// Each vertex's texture coordinates (`+0x114` of the scene object), from where the finest
    /// level's vertex stands across the sphere, and colour (`+0x110`).
    uv: [max_vertices][2]f32,
    colours: [max_vertices][4]f32 = @splat(@splat(0)),

    /// `0x0049EF90`: a bubble for a ship of `radius`, of the ship type's side.
    pub fn create(gpa: Allocator, radius: f32, side: gameobj.Side(i16)) Allocator.Error!*Bubble {
        const bubble = try gpa.create(Bubble);
        bubble.* = .{
            .object = .{
                .flags = .{ .not_culled = true, .baked_object = true, .own_first = true },
                .position = @splat(0),
                .scale = radius * bubble_scale,
                .radius = 1,
                .levels = &.{},
            },
            .tint = if (side == .friendly) .friendly else .other,
            .uv = undefined,
        };
        for (&bubble.uv, 0..) |*uv, index| {
            const at = grids[0].vertex(index);
            uv.* = .{ at[0], at[1] };
        }
        bubble.object.own_uv = .{ &bubble.uv, null };
        bubble.object.baked = &bubble.colours;
        return bubble;
    }

    /// `0x0049F070`.
    pub fn destroy(bubble: *Bubble, gpa: Allocator) void {
        gpa.destroy(bubble);
    }

    /// The vertex part of `0x0049F1E0`: a hit at `at` on a bubble standing at `place` round a ship
    /// at `centre`, into the next of its hits, by how far round from the point struck each vertex
    /// of `mesh` lies.
    fn strike(bubble: *Bubble, mesh: *const srapiext.Mesh, place: math.Place, centre: Vector, at: Vector, now: i32) void {
        bubble.struck = now;
        const toward = at - centre;
        const strengths = bubble.hits[bubble.next][0..mesh.positions.len];
        for (mesh.positions, strengths) |position, *strength| {
            const out = math.transform(place.orientation, position * @as(Vector, @splat(bubble.object.scale))) + place.position - centre;
            // The game's angle is not a number where rounding puts the cosine past one; the
            // port holds it to one.
            const cosine = std.math.clamp(math.dot(toward, out) / (math.length(toward) * math.length(out)), -1, 1);
            const angle = @abs(std.math.acos(cosine));
            if (!(angle <= hit_reach)) continue;
            strength.* = @min(struck_strength + angle / strength_spread, max_strength);
        }
        bubble.next +%= 1;
    }

    /// Flickers the bubble as a force field for `flicker_for` ticks, as a shockwave of kind 6 does
    /// to what it passes (`shockwaves_update`).
    pub fn flicker(bubble: *Bubble, now: i32) void {
        bubble.flicker_until = now + flicker_for;
        bubble.struck = now;
    }

    /// `0x0049E7D0`: the bubble's colours and texture moved on by `ticks`, on its level of
    /// detail. Each vertex's colour is the sum of what each of its hits' strengths, faded, shows in
    /// its tint's ramp. While it flickers as a force field it is drawn over `ffield` instead, grey
    /// at random on one frame in `flicker_odds` and dark on the rest, and its hits wait. Either way
    /// the texture swirls: each vertex's coordinates turn about `centre`, the faster the nearer
    /// they are, and `centre` turns about the texture's corner.
    ///
    /// The game leaves `centre` off the coordinates it turns, so the texture wanders further each
    /// time; the port does the same. A flicker's texture is set on the level's mesh, which every
    /// bubble at that level shares, as the game sets it.
    fn update(bubble: *Bubble, shields: *Shields, ticks: i32, now: i32, random: ?*libcmt.Rand) void {
        const mesh = &shields.meshes[bubble.level];
        const vertices = mesh.positions.len;
        const elapsed: f32 = @floatFromInt(ticks);
        if (bubble.flicker_until) |until| {
            const over = until < now;
            mesh.surfaces[0].textures[0] = .{ .image = if (over) shields.texture else shields.field };
            if (over) bubble.flicker_until = null;
            const numbers = random orelse {
                @memset(bubble.colours[0..vertices], @splat(0));
                return;
            };
            const lit = numbers.rand() % flicker_odds == 0;
            for (bubble.colours[0..vertices]) |*colour| {
                const grey = @as(f32, @floatFromInt(numbers.rand())) / std.math.maxInt(u15);
                colour.* = if (lit) .{ grey, grey, grey, 0 } else @splat(0);
            }
        } else {
            const ramp = shields.ramps.getPtrConst(bubble.tint);
            for (bubble.colours[0..vertices], 0..) |*colour, vertex| {
                var sum: Colour = @splat(0);
                for (&bubble.hits) |*hits| {
                    hits[vertex] = @max(hits[vertex] - elapsed * fade_per_tick, 0);
                    sum += rampAt(ramp, hits[vertex]);
                }
                colour.* = .{ @min(sum[0], 1), @min(sum[1], 1), @min(sum[2], 1), colour[3] };
            }
        }
        const swirl = elapsed * swirl_per_tick;
        for (bubble.uv[0..vertices]) |*uv| {
            const off = [2]f32{ uv[0] - bubble.centre[0], uv[1] - bubble.centre[1] };
            const reach = off[0] * off[0] + off[1] * off[1];
            // A vertex dead on the centre would turn by an infinite angle; the port leaves it.
            const angle = if (reach > 0) swirl / reach else 0;
            uv.* = turned(off, angle);
        }
        bubble.centre = turned(bubble.centre, elapsed * centre_turn_per_tick);
    }
};

/// `point` turned by `angle` about the origin.
fn turned(point: [2]f32, angle: f32) [2]f32 {
    const sin = @sin(angle);
    const cos = @cos(angle);
    return .{ cos * point[0] - sin * point[1], sin * point[0] + cos * point[1] };
}

/// How a shield's sparks fly: out from the ship through the point struck, at 7.5 to 12.5 a tick,
/// within half a radian either way, carrying on with a quarter of the ship's velocity, ten of them
/// (`0x0049F1E0`).
const shield_sparks: sparks.Spray = .{ .speed = 10, .speed_range = 5, .spread = 1, .count = 10 };
const sparks_carry: f32 = 0.25;

/// `0x0049F1E0`: the shields of the ship in slot `index` struck at `at`, by a shot or a knock,
/// while any of its shields holds anything. Sparks fly off the point struck, unless the camera is
/// in the ship's cockpit, and its bubble ripples out from there.
///
/// **Improvement:** the game sends the sparks toward the world's origin, from the point struck
/// taken as a direction; the port sends them out from the ship, as the game works out first and
/// then writes over.
///
/// Not ported: a cloaked ship's shimmer where it is struck (`0x00463AF0`)
/// ([#89](https://github.com/vdmkenny/openreliant/issues/89)); a cloaked ship shows nothing.
pub fn flare(world: gameobj.World, index: u16, at: Vector) void {
    const slot = &world.objects.slots[index];
    const object = &slot.object;
    const shields = object.shields.values();
    if (std.mem.allEqual(f32, &shields, 0)) return;
    if (object.flags.cloaked) return;
    const bubble = slot.shield orelse return;
    const inside = if (world.camera) |watching| watching.inside(index) else false;
    if (!inside) {
        const carried = gameobj.vector(object.velocity) * @as(Vector, @splat(sparks_carry));
        sparks.spray(world, .shield, at, at - slot.drawn.position, carried, shield_sparks);
    }
    const shared = world.shields orelse return;
    bubble.strike(&shared.meshes[bubble.level], slot.drawn, gameobj.vector(object.root.position), at, world.clock.frame_start);
}

test {
    std.testing.refAllDecls(@This());
}

pub const testing = struct {
    /// The bubbles' meshes built over a table holding nothing but their textures.
    pub const Built = struct {
        textures: *@import("backdrop.zig").testing.Textures,
        shields: Shields,

        pub fn init(gpa: Allocator) !Built {
            const textures = try @import("backdrop.zig").testing.Textures.initNames(gpa, &.{ "shield128", "ffield" });
            errdefer textures.deinit(gpa);
            return .{ .textures = textures, .shields = try .create(gpa, &textures.table, .high, true) };
        }

        pub fn deinit(built: *Built, gpa: Allocator) void {
            built.shields.deinit(gpa);
            built.textures.deinit(gpa);
        }
    };
};

test Grid {
    const gpa = std.testing.allocator;
    var built: testing.Built = try .init(gpa);
    defer built.deinit(gpa);

    // Each level is a closed sphere of a unit radius: every corner a vertex of it, no triangle
    // folded flat, and every edge shared by two triangles.
    for (built.shields.meshes, grids) |mesh, grid| {
        try std.testing.expectEqual(grid.vertices(), mesh.positions.len);
        for (mesh.positions) |position| try std.testing.expectApproxEqAbs(1, math.length(position), 1e-5);
        try std.testing.expectApproxEqAbs(1, mesh.radius, 1e-5);
        var edges: std.AutoHashMapUnmanaged([2]u16, u8) = .empty;
        defer edges.deinit(gpa);
        var corners = std.mem.window(u16, mesh.indices, 3, 3);
        while (corners.next()) |triangle| {
            try std.testing.expect(triangle[0] != triangle[1] and triangle[1] != triangle[2] and triangle[0] != triangle[2]);
            for (0..3) |side| {
                const a = triangle[side];
                const b = triangle[(side + 1) % 3];
                try std.testing.expect(a < mesh.positions.len);
                const entry = try edges.getOrPutValue(gpa, .{ @min(a, b), @max(a, b) }, 0);
                entry.value_ptr.* += 1;
            }
        }
        var each = edges.valueIterator();
        while (each.next()) |uses| try std.testing.expectEqual(2, uses.*);
    }
}

test rampColour {
    // At 0.6 a friendly ship's is at its brightest, a cyan; it is dark at full strength and below
    // 0.35.
    const top = rampColour(.friendly, 0.6, true);
    try std.testing.expectApproxEqAbs(0.7 * ramp_brightness, top[1], 1e-6);
    try std.testing.expectApproxEqAbs(ramp_brightness, top[2], 1e-6);
    try std.testing.expectEqual(0, top[0]);
    try std.testing.expectEqual(Colour{ 0, 0, 0 }, rampColour(.friendly, 1, true));
    try std.testing.expectEqual(Colour{ 0, 0, 0 }, rampColour(.friendly, 0.3, true));
    // The others' swaps the green and the blue, dimmer; a friendly ship's is grey without a
    // hardware renderer.
    const other = rampColour(.other, 0.6, true);
    try std.testing.expectApproxEqAbs(ramp_brightness * other_share, other[1], 1e-6);
    try std.testing.expectApproxEqAbs(0.7 * ramp_brightness * other_share, other[2], 1e-6);
    try std.testing.expectEqual(@as(Colour, @splat(top[2])), rampColour(.friendly, 0.6, false));
    // Only a strength strictly between nothing and one shows.
    var ramp = buildRamp(.friendly, true);
    try std.testing.expectEqual(Colour{ 0, 0, 0 }, rampAt(&ramp, 0));
    try std.testing.expectEqual(Colour{ 0, 0, 0 }, rampAt(&ramp, 1));
    try std.testing.expect(rampAt(&ramp, 0.6)[2] > 0);
}

test "a hit ripples out from where it struck" {
    const gpa = std.testing.allocator;
    var built: testing.Built = try .init(gpa);
    defer built.deinit(gpa);
    const bubble = try Bubble.create(gpa, 100, .friendly);
    defer bubble.destroy(gpa);
    const mesh = &built.shields.meshes[0];
    const grid = grids[0];
    const pole = 0;
    const near = grid.ring(4, 0);
    const equator = grid.ring(7, 0);

    // Struck on its pole: half a strength there, more further round, and nothing past 1.4 radians.
    bubble.strike(mesh, .{}, @splat(0), .{ 0, 0, 500 }, 10);
    try std.testing.expectEqual(10, bubble.struck);
    try std.testing.expectEqual(1, bubble.next);
    try std.testing.expectApproxEqAbs(0.5, bubble.hits[0][pole], 1e-5);
    try std.testing.expectApproxEqAbs(0.5 + 4 * std.math.pi / 14.0 / 1.2, bubble.hits[0][near], 1e-5);
    try std.testing.expectEqual(0, bubble.hits[0][equator]);

    // At first the pole glows and the ring four bands round, past one, is dark.
    bubble.update(&built.shields, 0, 10, null);
    try std.testing.expect(bubble.colours[pole][2] > 0);
    try std.testing.expectEqual(0, bubble.colours[near][2]);
    // Twenty ticks on, the glow has moved out to it, and the pole is dark.
    const before = bubble.uv[near];
    bubble.update(&built.shields, 20, 30, null);
    try std.testing.expectEqual(0, bubble.colours[pole][2]);
    try std.testing.expect(bubble.colours[near][2] > 0);
    // Meanwhile the texture has swirled.
    try std.testing.expect(!std.meta.eql(before, bubble.uv[near]));

    // A flicker as a force field swaps the texture while it lasts, and back after.
    bubble.flicker(30);
    bubble.update(&built.shields, 10, 40, null);
    try std.testing.expectEqual(built.shields.field, mesh.surfaces[0].textures[0].image);
    bubble.update(&built.shields, 100, 140, null);
    try std.testing.expectEqual(built.shields.texture, mesh.surfaces[0].textures[0].image);
    try std.testing.expectEqual(null, bubble.flicker_until);
}

test flare {
    const gpa = std.testing.allocator;
    var built: testing.Built = try .init(gpa);
    defer built.deinit(gpa);
    var thrown: sparks.testing.Built = try .init(gpa);
    defer thrown.deinit(gpa);
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    var world = mission.world();
    var watching: @import("camera.zig").Camera = .{};
    world.shields = &built.shields;
    world.sparks = &thrown.sparks;
    world.camera = &watching;
    mission.clock.frame_start = 50;
    _ = try mission.add(.predator, @splat(0));
    const index = try mission.add(.sabre, .{ 0, 0, 1000 });
    const slot = mission.slot(index);
    const bubble = slot.shield.?;
    try std.testing.expectEqual(Tint.other, bubble.tint);

    // Struck with its shields up: it flares, and sparks fly.
    flare(world, index, .{ 0, 0, 900 });
    try std.testing.expectEqual(50, bubble.struck);
    try std.testing.expect(thrown.sparks.sparks.slots[0] != null);
    // Not while every shield is empty, nor while it is cloaked.
    bubble.struck = null;
    slot.object.shields = .all(0);
    flare(world, index, .{ 0, 0, 900 });
    try std.testing.expectEqual(null, bubble.struck);
    slot.object.shields = .all(10);
    slot.object.flags.cloaked = true;
    flare(world, index, .{ 0, 0, 900 });
    try std.testing.expectEqual(null, bubble.struck);
}

test "Shields.draw" {
    const gpa = std.testing.allocator;
    var built: testing.Built = try .init(gpa);
    defer built.deinit(gpa);
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    const player = try mission.add(.predator, @splat(0));
    const other = try mission.add(.sabre, .{ 0, 0, 1000 });
    for ([_]u16{ player, other }) |index| mission.slot(index).shield.?.struck = 100;
    var scene: srcore.Scene = .{};
    defer scene.deinit(gpa);
    var look: Shields.Look = .{ .camera = @splat(0), .inside = true, .frame_start = 150, .random = null };

    // Both were struck within the last hundred ticks, but the camera is in the player's cockpit.
    try built.shields.draw(gpa, &scene, mission.objects, look);
    try std.testing.expectEqual(1, scene.layers.get(.world).items.len);
    try std.testing.expectEqual(&mission.slot(other).shield.?.object, scene.layers.get(.world).items[0].mesh);
    // A thousand away is the finest level's reach.
    try std.testing.expectEqual(0, mission.slot(other).shield.?.level);

    // From outside, both; past a hundred ticks, neither.
    scene.clear();
    look.inside = false;
    try built.shields.draw(gpa, &scene, mission.objects, look);
    try std.testing.expectEqual(2, scene.layers.get(.world).items.len);
    scene.clear();
    look.frame_start = 201;
    try built.shields.draw(gpa, &scene, mission.objects, look);
    try std.testing.expectEqual(0, scene.layers.get(.world).items.len);
}

