//! `C:\lancer\game\srofiles.cpp`: Surrender meshes from `.SHP` models. `mesh_build` (`0x004A3040`)
//! makes a part's mesh for one level of detail and gives each run of faces with the same shading
//! and material a material of its own; `look` is its rule.

const std = @import("std");

const Pointer = @import("../../lancer.zig").Pointer;
const shp = @import("../../formats/shp.zig");
const tcache = @import("../../formats/tcache.zig");
const Material = @import("../surrender/surrenderlib/srapiext.zig").Material;

/// What decides a face's look besides its shading.
pub const Conditions = struct {
    /// Whether `Lmaps` in the settings' `Device` section, `light_maps` (`0x005D5618`), is 1, as it
    /// is unless set.
    light_maps: bool = true,
    /// The part's `lightmap` flag.
    part_lightmap: bool = false,
    /// A hardware renderer rather than the software one.
    hardware: bool = true,
};

pub const Texture = union(enum) {
    none,
    /// The face's material, by the mesh's texture coordinates.
    material,
    /// `l` and the material's name, by the mesh's texture coordinates.
    light_map,
    /// One of the Direct3D driver's highlight textures, by coordinates from the normals.
    highlight: u3,
};

pub const Pass = struct {
    texture: Texture,
    /// Coloured by the vertex lighting, else by white.
    lit: bool,
    blend: Material.Blend,
};

pub const Look = struct {
    first: Pass,
    /// Drawn over the first.
    second: ?Pass = null,
    /// Lines along the edges the face's edge mask leaves unset, instead of the triangle.
    lines: bool = false,
};

/// The look `mesh_build` gives a face. A sub-mode above 7 on `lit_highlight` does not occur; the
/// driver would take it for an address, and this takes its low three bits.
pub fn look(shading: shp.Face.Shading, conditions: Conditions) Look {
    const untextured: Pass = .{ .texture = .none, .lit = true, .blend = .off };
    const textured: Pass = .{ .texture = .material, .lit = true, .blend = .off };
    return switch (shading.mode) {
        .untextured => .{ .first = untextured },
        .wire => .{ .first = untextured, .lines = true },
        .untextured_additive => .{ .first = .{ .texture = .none, .lit = true, .blend = .add } },
        .unlit => .{ .first = .{ .texture = .material, .lit = false, .blend = .off } },
        .unlit_additive => .{ .first = .{ .texture = .material, .lit = false, .blend = .add } },
        .unlit_blended => .{ .first = .{ .texture = .material, .lit = false, .blend = .alpha } },
        .lit => .{
            .first = textured,
            .second = if (conditions.light_maps and conditions.part_lightmap and conditions.hardware)
                .{ .texture = .light_map, .lit = false, .blend = .add }
            else
                null,
        },
        .lit_highlight => .{
            .first = textured,
            .second = if (conditions.light_maps)
                .{ .texture = .{ .highlight = @truncate(shading.sub_mode) }, .lit = true, .blend = .add }
            else
                null,
        },
        .lit_additive => .{ .first = .{ .texture = .material, .lit = true, .blend = .add } },
        // Mode 10 is `lit_additive` again; the rest leave the material zero.
        _ => if (@intFromEnum(shading.mode) == 10)
            .{ .first = .{ .texture = .material, .lit = true, .blend = .add } }
        else
            .{ .first = .{ .texture = .none, .lit = false, .blend = .off } },
    };
}

/// The textures `mesh_build` puts in a material.
pub const Images = struct {
    material: Pointer(tcache.Image) = .null,
    light_map: Pointer(tcache.Image) = .null,
};

/// A look as the mesh's material record holds it. The first image is the face's material whatever
/// the look.
pub fn material(face_look: Look, images: Images) Material {
    var record: Material = .{
        .two_pass = face_look.second != null,
        ._unknown_01 = 0,
        .coordinates = .{ coordinates(face_look.first.texture), .none },
        .lit = .{ face_look.first.lit, false },
        .blend = .{ face_look.first.blend, .off },
        .image = .{ images.material, .null },
    };
    if (face_look.second) |second| {
        record.coordinates[1] = coordinates(second.texture);
        record.lit[1] = second.lit;
        record.blend[1] = second.blend;
        record.image[1] = switch (second.texture) {
            .none => .null,
            .material => images.material,
            .light_map => images.light_map,
            .highlight => |index| @enumFromInt(index),
        };
    }
    return record;
}

fn coordinates(texture: Texture) Material.Coordinates {
    return switch (texture) {
        .none => .none,
        .material, .light_map => .mesh,
        .highlight => .normals,
    };
}

fn testShading(mode: u4, sub_mode: u4) shp.Face.Shading {
    return .{ .mode = @enumFromInt(mode), .sub_mode = sub_mode, ._unused = 0 };
}

test look {
    const lit = look(testShading(6, 1), .{});
    try std.testing.expectEqual(Texture.material, lit.first.texture);
    try std.testing.expect(lit.first.lit);
    try std.testing.expectEqual(null, lit.second);

    const mapped = look(testShading(6, 1), .{ .part_lightmap = true });
    try std.testing.expectEqual(Texture.light_map, mapped.second.?.texture);
    try std.testing.expectEqual(Material.Blend.add, mapped.second.?.blend);
    try std.testing.expect(!mapped.second.?.lit);
    // The software renderer and the light maps setting each leave the light map out.
    try std.testing.expectEqual(null, look(testShading(6, 1), .{ .part_lightmap = true, .hardware = false }).second);
    try std.testing.expectEqual(null, look(testShading(6, 1), .{ .part_lightmap = true, .light_maps = false }).second);

    const shiny = look(testShading(7, 3), .{});
    try std.testing.expectEqual(Texture{ .highlight = 3 }, shiny.second.?.texture);
    try std.testing.expect(shiny.second.?.lit);
    try std.testing.expectEqual(null, look(testShading(7, 3), .{ .light_maps = false }).second);

    try std.testing.expect(look(testShading(1, 1), .{}).lines);
    try std.testing.expectEqual(Material.Blend.alpha, look(testShading(5, 0), .{}).first.blend);
    try std.testing.expect(!look(testShading(4, 2), .{}).first.lit);
    try std.testing.expectEqual(look(testShading(8, 1), .{}), look(testShading(10, 1), .{}));
}

test material {
    const texture: Pointer(tcache.Image) = @enumFromInt(0x0060_0000);
    const light_map: Pointer(tcache.Image) = @enumFromInt(0x0060_1000);

    // The bytes `mesh_build` writes for a light-mapped `lit` face: two passes, the mesh's
    // coordinates for both, the first lit, the second added.
    const mapped = material(look(testShading(6, 0), .{ .part_lightmap = true }), .{ .material = texture, .light_map = light_map });
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 1, 1, 1, 0, 0, 1 }, std.mem.asBytes(&mapped)[0..8]);
    try std.testing.expectEqual(light_map, mapped.image[1]);

    // A highlight: coordinates from the normals, the second pass lit, its image the index.
    const shiny = material(look(testShading(7, 5), .{}), .{ .material = texture });
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 1, 2, 1, 1, 0, 1 }, std.mem.asBytes(&shiny)[0..8]);
    try std.testing.expectEqual(5, @intFromEnum(shiny.image[1]));

    const blended = material(look(testShading(5, 0), .{}), .{ .material = texture });
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 1, 0, 0, 0, 3, 0 }, std.mem.asBytes(&blended)[0..8]);
    try std.testing.expectEqual(texture, blended.image[0]);
}
