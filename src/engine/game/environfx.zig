//! `C:\lancer\game\environfx.cpp`: the effects a mission's space is drawn with. The port has the
//! engine glows, the flares a ship's thrusters burn, which `engine_glows_build` (`0x00469620`)
//! makes once at start-up and every ship's attachments of kind `engine_glow` then draw. The file
//! also holds the environment effects a script turns on (`environment_effect_set`, `0x00469C60`),
//! which [`backdrop.zig`](backdrop.zig) draws. Only that one asserts, so only its code names the
//! file; the glows lie in the stretch the linker gave it, between `Create.cpp`'s code and
//! `erayfx.cpp`'s ([`sources.zig`](../sources.zig)).

const std = @import("std");
const Allocator = std.mem.Allocator;

const math = @import("../surrender/math.zig");
const srapi = @import("../surrender/surrenderlib/srapi.zig");
const srapiext = @import("../surrender/surrenderlib/srapiext.zig");
const srtexture = @import("../surrender/surrenderlib/srtexture.zig");
const matmanager = @import("matmanager.zig");
const Vector = math.Vector;

/// How many engine glows the game builds. An attachment's id picks one, clamped to these
/// (`engine_glow_create`, `0x004697D0`).
pub const glow_kinds = 7;

/// The glows' meshes (`engine_glow_meshes`, `0x0054EA18`), built once and shared by every glow
/// drawn. Whatever holds these must outlive the models pointing at them.
pub const Glows = struct {
    meshes: [glow_kinds]srapiext.Mesh,

    /// Builds all seven (`engine_glows_build`), each with its own pair of flare materials.
    pub fn create(gpa: Allocator, textures: *srtexture.Table) (Allocator.Error || matmanager.Error)!Glows {
        var glows: Glows = .{ .meshes = undefined };
        var made: usize = 0;
        errdefer for (glows.meshes[0..made]) |built| built.deinit(gpa);
        for (&glows.meshes, 0..) |*built, kind| {
            built.* = try glowMesh(gpa, textures, kind);
            made += 1;
        }
        return glows;
    }

    /// Frees what `gpa` allocated for them (`engine_glows_free`, `0x00469770`).
    pub fn deinit(glows: *const Glows, gpa: Allocator) void {
        for (glows.meshes) |built| built.deinit(gpa);
    }

    /// The mesh an attachment of `id` draws. The game clamps the id to the glows it has, so an
    /// attachment naming none of them draws the first (`engine_glow_create`).
    pub fn mesh(glows: *const Glows, id: u32) *const srapiext.Mesh {
        return &glows.meshes[std.math.clamp(id, 1, glow_kinds) - 1];
    }
};

/// The quads a plume's mesh is made of: one across its foot, then the blades down it.
const nozzle_quads = 1;
const blade_quads = 3;
const quads = nozzle_quads + blade_quads;
const corners = 4;

/// How far apart the blades stand about the axis the plume runs along (`0x004DC458`). Each blade is
/// a single quad crossing the axis, so it stands for two, and a sixth of a turn apart spreads the
/// three of them evenly around it.
///
/// **Improvement:** a sixth of a turn exactly, where the game rounds it to 1.0472.
const blade_step: f32 = std.math.pi / 3.0;

/// How far into a flare's texture a corner reaches: a little inside its edges, so that a flare
/// fades out rather than ending on the texture's border.
const uv_near: f32 = 0.04;
const uv_far: f32 = 0.99;

/// What a glow's quads are sorted by, ten in front of where they lie, so that a plume is drawn over
/// the hull it burns from rather than fighting with it. `srofiles.build` puts a third of a face's
/// own bias in the same place.
const sort_bias: f32 = -10;

/// A flare's material: added to what stands behind it, unlit, with the mesh's own coordinates.
const flare_material: srapiext.Material = .onePass(.{ .coordinates = .mesh, .lit = false, .blend = .add });

/// The material a glow's nozzle draws with, and the one its blades draw with (`engine_glows_build`).
const nozzle_materials = materialNames("matflarea");
const blade_materials = materialNames("matflareb");

/// `matflarea1` to `matflarea7`, or `matflareb1` to `matflareb7`: the game numbers them from one.
fn materialNames(comptime prefix: []const u8) [glow_kinds][]const u8 {
    var names: [glow_kinds][]const u8 = undefined;
    for (&names, 1..) |*name, kind| name.* = std.fmt.comptimePrint("{s}{d}", .{ prefix, kind });
    return names;
}

/// One glow's mesh (`engine_glow_mesh_build`, `0x00469400`): a plume a unit across and a unit
/// long, for `node_draw` to scale by the attachment's size and to stretch along the plume by the
/// throttle, over the mesh's own texture coordinates, a little inside each flare.
fn glowMesh(gpa: Allocator, textures: *srtexture.Table, kind: usize) (Allocator.Error || matmanager.Error)!srapiext.Mesh {
    const nozzle = try matmanager.textureRequire(textures, nozzle_materials[kind]);
    const blades = try matmanager.textureRequire(textures, blade_materials[kind]);
    var mesh = try plumeMesh(gpa, @splat(1), flare_material, nozzle, blades);
    errdefer mesh.deinit(gpa);
    const uv = try mesh.addCoordinates(gpa);
    // Nothing gives the quads their planes, so every one of them faces the camera: the mesh is
    // never culled by them.
    @memset(mesh.biases, sort_bias);
    for (0..quads) |quad| {
        uv[quad * corners ..][0..corners].* = .{
            .{ uv_far, uv_far }, .{ uv_far, uv_near }, .{ uv_near, uv_near }, .{ uv_near, uv_far },
        };
    }
    return mesh;
}

/// A plume's mesh, which the engine glows and the muzzle flashes (`guns.flash`) share: four quads
/// of sixteen vertices, `size` across, up and long. The first stands square across the plume's
/// foot, and the other three run down the plume from it, `blade_step` apart about it. The first
/// quad is drawn with `material` over `nozzle`, the rest with it over `blades`.
pub fn plumeMesh(gpa: Allocator, size: Vector, material: srapiext.Material, nozzle: *srtexture.Image, blades: *srtexture.Image) Allocator.Error!srapiext.Mesh {
    const vertex_count = quads * corners;
    var mesh: srapiext.Mesh = try .create(gpa, .{ .polygons = quads, .vertices = vertex_count, .indices = vertex_count, .surfaces = 2 });
    errdefer mesh.deinit(gpa);
    mesh.surfaces[0] = .{ .polygons = nozzle_quads, .material = material, .textures = .{ .{ .image = nozzle }, .none } };
    mesh.surfaces[1] = .{ .polygons = blade_quads, .material = material, .textures = .{ .{ .image = blades }, .none } };

    // The nozzle sits square across the plume's foot, where it leaves the hull.
    mesh.positions[0..corners].* = .{ .{ -1, -1, 0 }, .{ 1, -1, 0 }, .{ 1, 1, 0 }, .{ -1, 1, 0 } };
    for (0..blade_quads) |blade| {
        const angle = @as(f32, @floatFromInt(blade)) * blade_step;
        const across: Vector = .{ @sin(angle), @cos(angle), 0 };
        const along: Vector = .{ 0, 0, 1 };
        mesh.positions[(nozzle_quads + blade) * corners ..][0..corners].* = .{ -across, along - across, along + across, across };
    }
    for (mesh.positions) |*position| position.* *= size;
    mesh.numberPolygons(corners);
    for (mesh.indices, 0..) |*index, at| index.* = @intCast(at);
    srapi.findBoundingBox(&mesh);
    return mesh;
}

pub const testing = struct {
    /// The glows built over a table holding nothing but their flares, for tests that draw them.
    pub const Built = struct {
        textures: *@import("backdrop.zig").testing.Textures,
        glows: Glows,

        pub fn init(gpa: Allocator) !Built {
            var names: [glow_kinds * 2][]const u8 = undefined;
            for (nozzle_materials, blade_materials, 0..) |nozzle, blade, kind| {
                names[kind * 2] = nozzle;
                names[kind * 2 + 1] = blade;
            }
            const textures = try @import("backdrop.zig").testing.Textures.initNames(gpa, &names);
            errdefer textures.deinit(gpa);
            return .{ .textures = textures, .glows = try .create(gpa, &textures.table) };
        }

        pub fn deinit(built: Built, gpa: Allocator) void {
            built.glows.deinit(gpa);
            built.textures.deinit(gpa);
        }
    };
};

test glowMesh {
    const gpa = std.testing.allocator;
    const textures = try @import("backdrop.zig").testing.Textures.initNames(gpa, &.{ "matflarea1", "matflareb1" });
    defer textures.deinit(gpa);
    const mesh = try glowMesh(gpa, &textures.table, 0);
    defer mesh.deinit(gpa);

    // The nozzle quad, then a blade for each third of a half turn.
    try std.testing.expectEqual(16, mesh.positions.len);
    try std.testing.expectEqual(@as(Vector, .{ -1, -1, 0 }), mesh.positions[0]);
    try std.testing.expectEqual(@as(Vector, .{ 0, -1, 0 }), mesh.positions[4]);
    try std.testing.expectEqual(@as(Vector, .{ 0, 1, 1 }), mesh.positions[6]);
    try std.testing.expectApproxEqAbs(-0.866025, mesh.positions[8][0], 1e-5);
    try std.testing.expectApproxEqAbs(-0.5, mesh.positions[8][1], 1e-5);

    // Each quad is four consecutive indices, drawn as a fan over the whole flare.
    try std.testing.expectEqual(srapiext.Polygon{ .kind = .triangle, .continues = 0, .first = 12, .count = 4 }, mesh.polygons[3]);
    try std.testing.expectEqualSlices(u16, &.{ 12, 13, 14, 15 }, mesh.indices[12..16]);
    try std.testing.expectEqual([2]f32{ uv_far, uv_near }, mesh.uv[0].?[13]);
    try std.testing.expectEqual(sort_bias, mesh.biases[3]);

    // The nozzle takes the `a` flare and the blades the `b` one, both added and unlit.
    try std.testing.expectEqual(1, mesh.surfaces[0].polygons);
    try std.testing.expectEqual(3, mesh.surfaces[1].polygons);
    try std.testing.expect(mesh.surfaces[0].textures[0].image != mesh.surfaces[1].textures[0].image);
    try std.testing.expectEqual(srapiext.Material.Blend.add, mesh.surfaces[1].material.blend[0]);
    try std.testing.expect(!mesh.surfaces[1].material.lit[0]);

    // A unit across and a unit long, reaching furthest at the nozzle's corners.
    try std.testing.expectEqual(@as(Vector, .{ -1, -1, 0 }), mesh.bounds[0]);
    try std.testing.expectEqual(@as(Vector, .{ 1, 1, 1 }), mesh.bounds[1]);
    try std.testing.expectApproxEqAbs(std.math.sqrt2, mesh.radius, 1e-5);
}

test plumeMesh {
    const gpa = std.testing.allocator;
    const textures = try @import("backdrop.zig").testing.Textures.initNames(gpa, &.{ "matflarea3", "matflareb3" });
    defer textures.deinit(gpa);
    const nozzle = try matmanager.textureRequire(&textures.table, "matflarea3");
    const mesh = try plumeMesh(gpa, .{ 60, 60, 600 }, flare_material, nozzle, nozzle);
    defer mesh.deinit(gpa);

    // Stretched to its size: the nozzle's corners, and each blade's far end.
    try std.testing.expectEqual(@as(Vector, .{ 60, -60, 0 }), mesh.positions[1]);
    try std.testing.expectEqual(@as(Vector, .{ 0, 60, 600 }), mesh.positions[6]);
    try std.testing.expectApproxEqAbs(-0.866025 * 60.0, mesh.positions[8][0], 1e-3);
    try std.testing.expectEqual(@as(Vector, .{ 60, 60, 600 }), mesh.bounds[1]);
    // No coordinates of its own, and no bias.
    try std.testing.expectEqual(null, mesh.uv[0]);
    try std.testing.expectEqual(0, mesh.biases[0]);
}

test "materials are numbered from one" {
    try std.testing.expectEqualStrings("matflarea1", nozzle_materials[0]);
    try std.testing.expectEqualStrings("matflareb7", blade_materials[glow_kinds - 1]);
}

test Glows {
    const gpa = std.testing.allocator;
    const built: testing.Built = try .init(gpa);
    defer built.deinit(gpa);
    const glows = built.glows;

    // An id names a glow from one; one past either end takes the nearest.
    try std.testing.expectEqual(&glows.meshes[0], glows.mesh(1));
    try std.testing.expectEqual(&glows.meshes[glow_kinds - 1], glows.mesh(glow_kinds));
    try std.testing.expectEqual(&glows.meshes[0], glows.mesh(0));
    try std.testing.expectEqual(&glows.meshes[glow_kinds - 1], glows.mesh(99));
}

test {
    std.testing.refAllDecls(@This());
}
