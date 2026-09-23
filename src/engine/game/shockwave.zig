//! `C:\lancer\game\shockwave.cpp`: the rings that spread out from an explosion, fading as they go,
//! and what they do to what they pass.
//!
//! Ported: the rings, a blast's (`explode.blast`) and a halting torpedo's
//! ([`aiexplode.zig`](aiexplode.zig)), and what those do to the player. **Not ported:** the
//! callers of the rest, and what those do: `0x00472AB0`'s pair of kind 3 in `explode.cpp`
//! ([#41](https://github.com/vdmkenny/openreliant/issues/41)), and a missile's end
//! (`0x00495870`), which sets off kind 5 or 6 by the missile's type
//! ([#39](https://github.com/vdmkenny/openreliant/issues/39)).

const std = @import("std");
const Allocator = std.mem.Allocator;

const math = @import("../surrender/math.zig");
const Vector = math.Vector;
const srapi = @import("../surrender/surrenderlib/srapi.zig");
const srapiext = @import("../surrender/surrenderlib/srapiext.zig");
const srcore = @import("../surrender/surrenderlib/srcore.zig");
const srtexture = @import("../surrender/surrenderlib/srtexture.zig");
const camera = @import("camera.zig");
const collision = @import("collision.zig");
const gameobj = @import("gameobj.zig");
const matmanager = @import("matmanager.zig");
const table = @import("table.zig");
const xtrabits = @import("xtrabits.zig");
const Clock = @import("main.zig").Clock;

/// The rings' looks, one texture each, in the order `shockwave_init` (`0x004A0D90`) builds their
/// meshes (`shockwave_textures`, `0x0059379C`; `shockwave_meshes`, `0x005937B4`).
pub const Ring = enum {
    rng_02,
    rng_03,
    rng_04,
    rng_01,
    rng_06,
};

/// What a shockwave is, which picks its ring and what it does to what it passes.
pub const Kind = enum(u4) {
    /// A blast's, in one of three looks: it shakes the player's view as it passes.
    blast_02 = 0,
    blast_03 = 1,
    blast_04 = 2,
    /// **Unknown.** `0x00472AB0`'s pair, which do nothing but show.
    _unknown_3 = 3,
    /// **Unknown.** No caller makes one: it does nothing but show.
    _unknown_4 = 4,
    /// **Unknown.** `0x00495870`'s: it pushes the ships of other sides it passes away (order
    /// `0x72`).
    _unknown_5 = 5,
    /// **Unknown.** `0x00495870`'s: it damages each quadrant of the ships of other sides it passes
    /// by 50 more than the quadrant's shield holds.
    _unknown_6 = 6,
    /// **Unknown.** No caller makes one: unseen, it damages the player as it passes, by its
    /// owner's type.
    _unknown_7 = 7,
    /// A halting torpedo's: it shakes the player's view and damages the player as it passes.
    torpedo = 8,

    /// The ring it shows (`shockwave_create`).
    pub fn ring(kind: Kind) Ring {
        return switch (kind) {
            .blast_02 => .rng_02,
            .blast_03 => .rng_03,
            .blast_04 => .rng_04,
            ._unknown_3, ._unknown_6, ._unknown_7, .torpedo => .rng_01,
            ._unknown_4, ._unknown_5 => .rng_06,
        };
    }

    /// The blast's three, which it picks one of at random.
    pub const blasts = [_]Kind{ .blast_02, .blast_03, .blast_04 };
};

/// How a shockwave is set off: how far it spreads, over how long, drifting how far a tick, and whose
/// it is.
pub const Spec = struct {
    kind: Kind,
    size: f32,
    life: i32,
    velocity: Vector = @splat(0),
    owner: u16,
};

/// A shockwave spreading (0x2C bytes): a ring that grows from nothing to its size over its life,
/// fading as it goes.
pub const Shockwave = struct {
    kind: Kind,
    /// The ring, which its own colours colour, never culled (`+0x04`). Its scale is how far the
    /// ring has spread, and so how far it had the frame before.
    object: srapiext.MeshObject,
    colours: [ring_vertices][4]f32,
    /// How far it drifts a tick (`+0x08`), how far it spreads (`+0x14`), when it was set off and
    /// for how long (`+0x18`, `+0x1C`), and whose it is (`+0x20`). The game also keeps the side
    /// of `0x00495870`'s (`+0x24`), which only kinds 5 and 6 read.
    velocity: Vector,
    size: f32,
    born: i32,
    life: i32,
    owner: u16,

    /// Whether the ring passed the player's ship this frame: from how far it had spread to how
    /// far it has now.
    fn passesPlayer(wave: *const Shockwave, world: gameobj.World, reach: f32) bool {
        const player = &world.objects.slots[world.objects.player];
        const distance = math.distance(wave.object.position, player.drawn.position);
        return wave.object.scale <= distance and distance < reach;
    }

    /// A torpedo's shockwave passing the player's ship shakes the view and damages each quadrant by
    /// `torpedo_harm` of its size times what is left of its life, unless the ship lists
    /// components, is a stand-in, exploding or disabled, or another shockwave harmed it less than
    /// `harm_pause` ticks ago. A shield's reserve takes it first: while the reserve holds, the
    /// shield is spared, and once the reserve runs out the shield takes what the reserve held.
    ///
    /// **Improvement:** the game damages the player as if the attacker were object 16, whatever a
    /// loop left in a register; the port names the shockwave's owner.
    fn harmPlayer(wave: *const Shockwave, world: gameobj.World, done: f32, reach: f32) void {
        const all = world.objects;
        const object = &all.slots[all.player].object;
        if (object.flags.components or object.flags.stand_in or object.flags.exploding or object.flags.disabled) return;
        if (object.shockwave_until > world.clock.frame_start) return;
        if (!wave.passesPlayer(world, reach)) return;
        shake(world, done);
        object.shockwave_until = world.clock.frame_start + harm_pause;
        const value = (1 - done) * wave.size * torpedo_harm;
        for (std.enums.values(collision.Quadrant)) |quadrant| {
            const through = if (world.player.shield_reserves.of(quadrant)) |reserve| through: {
                if (reserve.* <= 0) break :through value;
                reserve.* -= value;
                if (reserve.* >= 0) continue;
                const held = reserve.* + value;
                reserve.* = 0;
                break :through held;
            } else value;
            collision.damage(world, all.player, quadrant, through, 1, wave.owner, .collision);
        }
    }
};

/// The shockwaves the game keeps room for; one more is not set off, where the game fails an
/// assertion ("shockwave count exceeded") and writes past its table.
pub const max_shockwaves = 30;

/// A ring's mesh (`0x004A0B30`): `spokes` points a unit out and as many `hole` out, evenly about
/// the Z axis, the band between them two triangles a spoke. Each corner's texture coordinates are
/// how far it lies across and up, either way, no nearer the middle than `uv_least`, so the
/// texture, a quarter of a ring, shows mirrored in each quarter.
const spokes = 8;
const ring_vertices = spokes * 2;
const ring_triangles = spokes * 2;
const hole: f32 = 0.1;
const uv_least: f32 = 1.0 / 64.0;

/// A ring's material: its own texture coordinates, coloured by its colours, and added to what is
/// behind it.
const ring_material: srapiext.Material = .onePass(.{ .coordinates = .mesh, .lit = true, .blend = .add });

/// How hard a shockwave shakes the player's view as it passes, times how far through its life it
/// is (`0x004DC520`), no more than the camera takes; how long the player is left alone after a
/// shockwave harms it (`GameObject.shockwave_until`); and how much a torpedo's harms each
/// quadrant, times its size and what is left of its life (`0x004DC474`).
const shake_scale: f32 = 10;
const harm_pause = 50;
const torpedo_harm: f32 = 0.05;

/// The shockwaves spreading, and the rings they show.
pub const Shockwaves = struct {
    meshes: std.EnumArray(Ring, srapiext.Mesh),
    /// Each ring as a single level of detail, which the rings drawn point at.
    levels: std.EnumArray(Ring, [1]srapiext.Level) = .initUndefined(),
    waves: [max_shockwaves]?Shockwave = @splat(null),

    /// `shockwave_init` (`0x004A0D90`): the rings' meshes, over their textures. The game also
    /// builds a sphere (`0x004A16F0`, `0x005937B0`), which nothing draws.
    pub fn create(gpa: Allocator, textures: *srtexture.Table) (Allocator.Error || matmanager.Error)!Shockwaves {
        var meshes: std.EnumArray(Ring, srapiext.Mesh) = undefined;
        var built: usize = 0;
        errdefer for (meshes.values[0..built]) |mesh| mesh.deinit(gpa);
        for (std.enums.values(Ring)) |ring| {
            const image = try matmanager.textureRequire(textures, @tagName(ring));
            meshes.set(ring, try ringMesh(gpa, image));
            built += 1;
        }
        return .{ .meshes = meshes };
    }

    /// `0x004A0E60`: the meshes let go.
    pub fn deinit(waves: *Shockwaves, gpa: Allocator) void {
        for (waves.meshes.values) |mesh| mesh.deinit(gpa);
    }

    /// As a mission starts again: none spreading.
    pub fn reset(waves: *Shockwaves) void {
        waves.waves = @splat(null);
    }

    /// `shockwave_create` (`0x004A15D0`): sets a shockwave off at `at`, facing as it faces, into
    /// the first free slot, and not at all where there is none. It starts at nothing.
    pub fn add(waves: *Shockwaves, at: math.Place, spec: Spec, clock: *const Clock) void {
        const slot = table.firstFree(Shockwave, &waves.waves) orelse return;
        const mesh = waves.meshes.getPtrConst(spec.kind.ring());
        slot.* = .{
            .kind = spec.kind,
            .object = .{
                .flags = .{ .not_culled = true, .baked_object = true },
                .position = at.position,
                .orientation = at.orientation,
                .scale = 0,
                .radius = mesh.radius,
                .levels = &.{},
            },
            .colours = @splat(@splat(1)),
            .velocity = spec.velocity,
            .size = spec.size,
            .born = clock.frame_start,
            .life = spec.life,
            .owner = spec.owner,
        };
    }

    /// `shockwaves_update` (`0x004A0F00`), once a frame after the explosions: each shockwave drifts
    /// on by its velocity times the frame's ticks, fades from white to nothing, and spreads to
    /// its size times how far through its life it is, doing what it does to what it passes on
    /// the way. It is let go once its life is over.
    pub fn frame(waves: *Shockwaves, world: gameobj.World) void {
        const clock = world.clock;
        for (&waves.waves) |*slot| {
            const wave = &(slot.* orelse continue);
            const done = @as(f32, @floatFromInt(clock.frame_start - wave.born)) / @as(f32, @floatFromInt(wave.life));
            if (!(done < 1)) {
                slot.* = null;
                continue;
            }
            wave.object.position += wave.velocity * @as(Vector, @splat(@floatFromInt(clock.frame_duration)));
            wave.colours = @splat(@splat(1 - done));
            const reach = done * wave.size;
            switch (wave.kind) {
                .blast_02, .blast_03, .blast_04 => if (wave.passesPlayer(world, reach)) shake(world, done),
                .torpedo => wave.harmPlayer(world, done, reach),
                ._unknown_3, ._unknown_4, ._unknown_5, ._unknown_6, ._unknown_7 => {},
            }
            wave.object.scale = reach;
        }
    }

    /// Each shockwave's ring, into the world's layer, save kind 7's, which is unseen.
    pub fn draw(waves: *Shockwaves, gpa: Allocator, scene: *srcore.Scene) Allocator.Error!void {
        for (std.enums.values(Ring)) |ring| waves.levels.set(ring, .{.{ .mesh = waves.meshes.getPtrConst(ring), .until = std.math.inf(f32) }});
        for (&waves.waves) |*slot| {
            const wave = &(slot.* orelse continue);
            if (wave.kind == ._unknown_7) continue;
            wave.object.levels = waves.levels.getPtrConst(wave.kind.ring());
            wave.object.baked = &wave.colours;
            try xtrabits.sceneAdd(gpa, scene, .{ .mesh = &wave.object }, .world);
        }
    }
};

/// Sets a shockwave off at `at`, where the world has shockwaves.
pub fn setOff(world: gameobj.World, at: math.Place, spec: Spec) void {
    const waves = world.shockwaves orelse return;
    waves.add(at, spec, world.clock);
}

/// Shakes the player's view by how far through its life the shockwave passing is, where it shakes
/// no harder already.
fn shake(world: gameobj.World, done: f32) void {
    world.shake.* = @max(world.shake.*, @min(done * shake_scale, camera.Cockpit.shake_most));
}

/// `0x004A0B30`: a ring's mesh, over `image`.
fn ringMesh(gpa: Allocator, image: *srtexture.Image) Allocator.Error!srapiext.Mesh {
    var mesh: srapiext.Mesh = try .create(gpa, .{ .polygons = ring_triangles, .vertices = ring_vertices, .indices = ring_triangles * 3 });
    errdefer mesh.deinit(gpa);
    const uv = try mesh.addCoordinates(gpa);
    mesh.surfaces[0] = .{ .polygons = ring_triangles, .material = ring_material, .textures = .{ .{ .image = image }, .none } };
    for (0..spokes) |spoke| {
        const turn = math.fromAngles(0, 0, @as(f32, @floatFromInt(spoke)) * std.math.tau / spokes);
        mesh.positions[spoke * 2] = math.transform(turn, .{ 0, 1, 0 });
        mesh.positions[spoke * 2 + 1] = math.transform(turn, .{ 0, hole, 0 });
    }
    mesh.numberPolygons(3);
    for (0..spokes) |spoke| {
        const outer = spoke * 2;
        const corners = [6]usize{ outer, outer + 1, outer + 2, outer + 2, outer + 3, outer + 1 };
        for (mesh.indices[spoke * 6 ..][0..6], corners) |*index, corner| index.* = @intCast(corner % ring_vertices);
    }
    for (mesh.indices, uv) |index, *corner| {
        const at = mesh.positions[index];
        corner.* = .{ @max(@abs(at[0]), uv_least), @max(@abs(at[1]), uv_least) };
    }
    srapi.calcPolyNormals(&mesh);
    srapi.findBoundingBox(&mesh);
    return mesh;
}

pub const testing = struct {
    /// The shockwaves built over a table holding nothing but the rings' textures.
    pub const Built = struct {
        textures: *@import("backdrop.zig").testing.Textures,
        waves: Shockwaves,

        pub fn init(gpa: Allocator) !Built {
            var names: [std.enums.values(Ring).len][]const u8 = undefined;
            for (&names, std.enums.values(Ring)) |*name, ring| name.* = @tagName(ring);
            const textures = try @import("backdrop.zig").testing.Textures.initNames(gpa, &names);
            errdefer textures.deinit(gpa);
            return .{ .textures = textures, .waves = try .create(gpa, &textures.table) };
        }

        pub fn deinit(built: *Built, gpa: Allocator) void {
            built.waves.deinit(gpa);
            built.textures.deinit(gpa);
        }
    };
};

test Ring {
    var built: testing.Built = try .init(std.testing.allocator);
    defer built.deinit(std.testing.allocator);

    // Each ring is a band a unit out, a tenth deep, over its own texture.
    const mesh = built.waves.meshes.getPtrConst(.rng_03);
    try std.testing.expectEqual(ring_vertices, mesh.positions.len);
    try std.testing.expectApproxEqAbs(1, mesh.radius, 1e-6);
    try std.testing.expectApproxEqAbs(hole, math.length(mesh.positions[1]), 1e-6);
    try std.testing.expectEqual((try built.textures.table.find("rng_03")).?, mesh.surfaces[0].textures[0].image);

    // Its texture shows mirrored in each quarter, and never quite from the middle.
    const uv = mesh.uv[0].?;
    for (mesh.indices, uv) |index, corner| {
        const at = mesh.positions[index];
        try std.testing.expectApproxEqAbs(@max(@abs(at[0]), uv_least), corner[0], 1e-6);
        try std.testing.expect(corner[1] >= uv_least and corner[1] <= 1 + 1e-6);
    }
    try std.testing.expectEqual(Ring.rng_01, Kind.torpedo.ring());
    try std.testing.expectEqual(Ring.rng_06, Kind._unknown_5.ring());
}

test Shockwaves {
    const gpa = std.testing.allocator;
    var built: testing.Built = try .init(gpa);
    defer built.deinit(gpa);
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    var world = mission.world();
    world.shockwaves = &built.waves;
    const player = try mission.add(.predator, @splat(0));
    mission.objects.slots[player].drawn.position = .{ 0, 0, 500 };
    mission.clock.frame_duration = 10;

    // A tenth through its life it has spread a tenth of its size, faded a tenth and drifted on;
    // passing the player, it shakes the view by that tenth.
    setOff(world, .{}, .{ .kind = .blast_02, .size = 10000, .life = 100, .velocity = .{ 1, 0, 0 }, .owner = player });
    const wave = &built.waves.waves[0].?;
    mission.clock.frame_start = 10;
    built.waves.frame(world);
    try std.testing.expectEqual(1000, wave.object.scale);
    try std.testing.expectEqual(0.9, wave.colours[5][3]);
    try std.testing.expectEqual(Vector{ 10, 0, 0 }, wave.object.position);
    try std.testing.expectEqual(1, mission.shake);

    // Once its life is over it is gone.
    mission.clock.frame_start = 100;
    built.waves.frame(world);
    try std.testing.expectEqual(null, built.waves.waves[0]);

    // With every slot spreading, one more is not set off.
    for (0..max_shockwaves + 1) |_| setOff(world, .{}, .{ .kind = .blast_03, .size = 1, .life = 1000, .owner = player });
    for (built.waves.waves) |slot| try std.testing.expect(slot != null);
}

test "a torpedo's shockwave" {
    const gpa = std.testing.allocator;
    var built: testing.Built = try .init(gpa);
    defer built.deinit(gpa);
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    var world = mission.world();
    world.shockwaves = &built.waves;
    const player = try mission.add(.predator, @splat(0));
    const torpedo = try mission.add(.sabre, @splat(0));
    const slot = &mission.objects.slots[player];
    slot.drawn.position = .{ 0, 0, 1000 };
    slot.object.shields = .all(1000);
    mission.player.shield_reserves = .{ .fore = 100, .aft = 1000 };

    // A fifth through its life it passes the player: each quadrant takes 240, the fore's reserve
    // runs out and the shield takes what it held, and the aft's reserve holds.
    setOff(world, .{}, .{ .kind = .torpedo, .size = 6000, .life = 100, .owner = torpedo });
    mission.clock.frame_start = 20;
    built.waves.frame(world);
    const shields = &slot.object.shields;
    try std.testing.expectApproxEqAbs(760, shields.at(.left).*, 1e-3);
    try std.testing.expectApproxEqAbs(760, shields.at(.right).*, 1e-3);
    try std.testing.expectApproxEqAbs(900, shields.at(.fore).*, 1e-3);
    try std.testing.expectEqual(1000, shields.at(.aft).*);
    try std.testing.expectEqual(0, mission.player.shield_reserves.fore);
    try std.testing.expectApproxEqAbs(760, mission.player.shield_reserves.aft, 1e-3);
    try std.testing.expectEqual(torpedo, slot.object.last_attacker);
    try std.testing.expectEqual(2, mission.shake);
    try std.testing.expectEqual(20 + harm_pause, slot.object.shockwave_until);

    // Another passing within the pause leaves it alone.
    setOff(world, .{}, .{ .kind = .torpedo, .size = 6000, .life = 100, .owner = torpedo });
    mission.clock.frame_start = 40;
    built.waves.frame(world);
    try std.testing.expectApproxEqAbs(760, shields.at(.left).*, 1e-3);
}
