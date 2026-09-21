//! `C:\lancer\surrender\surrenderlib\srAPIext.cpp`: Surrender's frames, the transforms of its scene
//! graph, its meshes' materials, and the scene objects: meshes, sprite sets. The extern structs lay
//! out the game's memory; the rest are the port's.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const lancer = @import("../../../lancer.zig");
const Pointer = lancer.Pointer;
const shp = @import("../../../formats/shp.zig");
const tcache = @import("../../../formats/tcache.zig");
const math = @import("../math.zig");
const srtexture = @import("srtexture.zig");
const Vector = math.Vector;

/// Surrender's transform (`surrenderlib`), `0xB4` bytes, which `frame_create` (`0x004C51C0`)
/// allocates: a node's place relative to its parent frame.
pub const Frame = extern struct {
    _unknown_00: u32,
    /// Such as `GOroot object` for an object's root.
    name: Pointer(u8),
    _unknown_08: [8]u8,
    parent: Pointer(Frame),
    /// **Unknown**, mostly.
    flags: u32,
    /// Row-major 3x3.
    orientation: [9]f32,
    position: shp.Vec3,
    /// **Unknown.** 1.0 when created.
    _unknown_48: f32,
    _unknown_4c: [0x68]u8,

    comptime {
        assert(@offsetOf(Frame, "orientation") == 0x18);
        assert(@offsetOf(Frame, "position") == 0x3C);
        assert(@sizeOf(Frame) == 0xB4);
    }
};

/// How a group of a mesh's polygons is drawn: a first pass and, with `two_pass`, a second over it.
/// Each field but `two_pass` holds one value per pass. A mesh (`mesh_create`, `0x004C4440`) holds a
/// `Group` for each run of polygons, from `+0x64`; the Direct3D driver reads the material as is.
pub const Material = extern struct {
    two_pass: bool,
    _unknown_01: u8,
    /// Where the texture coordinates come from; `none` draws untextured.
    coordinates: [2]Coordinates,
    /// Colour by the vertex lighting, else by white.
    lit: [2]bool,
    blend: [2]Blend,
    /// The texture. Below 8, one of the Direct3D driver's highlight textures.
    image: [2]Pointer(tcache.Image),

    pub const Coordinates = enum(u8) {
        none = 0,
        /// The mesh's own.
        mesh = 1,
        /// Made each frame from the vertex normals, turned into the camera's frame: `u` is
        /// `0.5 + 0.5 * x`, `v` is `0.5 + 0.5 * y`.
        normals = 2,
        _,
    };

    /// How a pass combines with what is already drawn. Blended polygons are drawn after the rest
    /// of their layer, back to front.
    pub const Blend = enum(u8) {
        /// Replaces it.
        off = 0,
        /// Adds to it.
        add = 1,
        /// Adds to it, scaled by one minus the source alpha.
        premultiplied = 2,
        /// Mixes by the source alpha.
        alpha = 3,
        /// Adds, scaled by the source alpha.
        add_alpha = 4,
        _,
    };

    comptime {
        assert(@offsetOf(Material, "blend") == 6);
        assert(@sizeOf(Material) == 0x10);
    }
};

/// A run of a mesh's polygons with one material.
pub const Group = extern struct {
    polygons: u32,
    material: Material,

    comptime {
        assert(@sizeOf(Group) == 0x14);
    }
};

// --- The port's scene objects --------------------------------------------------------------------

/// A scene object's kind (`+0x00`), which picks its pipeline in `sr_draw_layers`.
pub const Kind = enum(u32) {
    mesh = 1,
    light = 2,
    sprites = 4,
    stars = 7,
    _,
};

/// A scene object's flags (`+0x14`).
pub const ObjectFlags = packed struct(u32) {
    /// Left out of the scene by `scene_add`, and of the lights by `mesh_light`.
    hidden: bool = false,
    /// Its polygons are clipped against a sixth plane as well (`0x004C5FB0`). **Unknown:** which.
    _unknown_1: bool = false,
    /// The driver sorts all its polygons, farthest first, and draws them at once, as it does
    /// every mesh on the overlay layer (`0x10002D10`).
    sorted: bool = false,
    /// Always its finest level of detail.
    finest: bool = false,
    _unknown_4: bool = false,
    /// A star field takes this frame as its last, so it draws no streaks (`backdrop_reset_streaks`);
    /// `stars_project` clears it.
    fresh: bool = false,
    _unknown_6: u2 = 0,
    /// Lit: its colour, the ambient lights and the rest (`mesh_light`).
    lit: bool = false,
    /// Texture coordinates from the normals for the first pass, and for the second
    /// (`mesh_generated_coordinates`).
    normals_first: bool = false,
    normals_second: bool = false,
    /// Never culled (`mesh_cull`).
    not_culled: bool = false,
    /// Neither tested against the view nor given a level of detail by distance, and always
    /// clipped (`SR_meshpipe_init`).
    _unknown_12: bool = false,
    /// Not tested against the view, and always clipped (`0x004C5E20`).
    unbounded: bool = false,
    _unknown_14: bool = false,
    /// Its triangles hide the sun, lessening its visibility (`0x10001FD0`).
    sun_occluder: bool = false,
    geomorph_positions: bool = false,
    geomorph_normals: bool = false,
    /// Coloured by the mesh's baked colours, or by the object's own.
    baked_mesh: bool = false,
    baked_object: bool = false,
    _unknown_20: u12 = 0,

    comptime {
        assert(@bitOffsetOf(ObjectFlags, "lit") == 8);
        assert(@bitOffsetOf(ObjectFlags, "not_culled") == 11);
        assert(@bitOffsetOf(ObjectFlags, "sun_occluder") == 15);
        assert(@bitOffsetOf(ObjectFlags, "baked_object") == 19);
    }
};

/// A texture a material names: one of the driver's highlight textures, or an image of the table.
pub const Texture = union(enum) {
    none,
    highlight: u3,
    image: *srtexture.Image,
};

/// What a run of a mesh's polygons, a set of sprites or a star field is drawn with, as the port
/// holds it: the material as the game lays it out, less its images, which `textures` holds.
pub const Surface = struct {
    /// For a mesh's run, how many polygons.
    polygons: u32 = 0,
    material: Material,
    textures: [2]Texture = .{ .none, .none },
};

/// A polygon of a mesh (`mesh+0x38`): a run of the mesh's indices.
pub const Polygon = struct {
    kind: PolygonKind,
    /// Records of the same strip or fan still to come, from the `.SHP` face: the driver draws a
    /// polygon with those after it in one go.
    continues: u16,
    first: u16,
    count: u16,
};

pub const PolygonKind = enum(u16) {
    /// A triangle, or a fan's records merged into one polygon.
    triangle = 0,
    fan = 1,
    strip_even = 2,
    /// Lists its last two corners the other way round.
    strip_odd = 3,
    /// Lines, one for each pair of indices.
    lines = 5,
    _,
};

/// A polygon's plane: its unit normal and the normal's dot product with its first corner.
pub const Plane = struct {
    normal: Vector,
    distance: f32,
};

/// A mesh (`mesh_create`, `0x004C4440`), as `mesh_build` makes it.
pub const Mesh = struct {
    positions: []Vector,
    normals: []Vector,
    /// Each vertex's counterpart in the next level, where the part geomorphs.
    morph_positions: ?[]Vector = null,
    morph_normals: ?[]Vector = null,
    /// Colours baked from static lights, red, green, blue and alpha.
    baked: ?[][4]f32 = null,
    /// `mesh_build` counts a wire face as one polygon more than it makes; those left over stay
    /// empty at the end, in no surface, and count only toward the frame's budget.
    polygons: []Polygon,
    indices: []u16,
    /// Texture coordinates for each index, for the first pass and the second. A light-mapped
    /// part's second are its first: the same slice.
    uv: [2]?[][2]f32,
    planes: []Plane,
    /// The faces' cap and two-sided flags, where the mesh has any.
    face_flags: ?[]shp.Face.Flags = null,
    /// A third of each face's sort bias.
    biases: []f32,
    surfaces: []Surface,
    bounds: [2]Vector,
    /// The farthest vertex from the origin.
    radius: f32,

    /// Frees what `gpa` allocated for it.
    pub fn deinit(mesh: Mesh, gpa: Allocator) void {
        gpa.free(mesh.positions);
        gpa.free(mesh.normals);
        if (mesh.morph_positions) |m| gpa.free(m);
        if (mesh.morph_normals) |m| gpa.free(m);
        if (mesh.baked) |b| gpa.free(b);
        gpa.free(mesh.polygons);
        gpa.free(mesh.indices);
        if (mesh.uv[0]) |u| gpa.free(u);
        if (mesh.uv[1]) |u| if (mesh.uv[0] == null or u.ptr != mesh.uv[0].?.ptr) gpa.free(u);
        gpa.free(mesh.planes);
        if (mesh.face_flags) |f| gpa.free(f);
        gpa.free(mesh.biases);
        gpa.free(mesh.surfaces);
    }
};

/// A mesh object's levels of detail (`+0xB4`): each mesh with the distance it is drawn to.
pub const Level = struct {
    mesh: *const Mesh,
    /// Drawn while the object's depth, over the detail divisor, is below this.
    until: f32,
};

/// A scene object showing a mesh (`mesh_object_create`, `0x004C4BD0`).
pub const MeshObject = struct {
    flags: ObjectFlags,
    /// In the world (`+0x70`, `+0x4C`).
    position: Vector,
    orientation: math.Matrix = math.identity,
    /// `+0x48`: 1 when created. An object at 0 is not drawn.
    scale: f32 = 1,
    /// `+0xD0`: the finest level's radius.
    radius: f32,
    /// `+0xD4`: all ones when created.
    face_mask: u8 = 0xFF,
    /// `+0xDC`: which lights reach it; all ones for none.
    light_mask: u32 = 0,
    /// `+0xC0`: red, green, blue and alpha; zero when created.
    colour: [4]f32 = @splat(0),
    levels: []const Level,
    /// The level drawn (`+0xB8`): the pipeline picks it each frame.
    level: usize = 0,
    /// The object's own baked colours (`+0x110`), for `baked_object`.
    baked: ?[]const [4]f32 = null,
};

/// A sprite of a set (`sprite_set_create`, `0x004C4DB0`): a rectangle facing the camera.
pub const Sprite = struct {
    /// From the set's position, in the world.
    offset: Vector = @splat(0),
    /// How far it reaches either side of its centre, in the camera's units.
    half_size: [2]f32 = .{ 0, 0 },
    /// Added to its depth for sorting (`+0x48`).
    bias: f32 = 0,
    /// Red, green and blue (`+0x54`).
    colour: [3]f32 = .{ 1, 1, 1 },
    /// Its texture's span: left, right, top and bottom (`+0x38`).
    uv: [4]f32 = .{ 0, 1, 0, 1 },
    /// Left out (the set's flags at `+0xC8`).
    hidden: bool = false,
};

/// A set of sprites sharing a material (`sprite_set_create`): at first unlit and added, textured
/// by coordinates of its own.
pub const SpriteSet = struct {
    flags: ObjectFlags = .{},
    /// In the world; the sprites are offset from it.
    position: Vector = @splat(0),
    scale: f32 = 1,
    surface: Surface = .{ .material = .{
        .two_pass = false,
        ._unknown_01 = 0,
        .coordinates = .{ .mesh, .none },
        .lit = .{ false, false },
        .blend = .{ .add, .off },
        .image = .{ .null, .null },
    } },
    sprites: []Sprite,
};

test {
    std.testing.refAllDecls(@This());
}
