//! `.SHP` models: the game's 3D geometry, one file per ship, station, weapon or piece of debris.
//!
//! A model is a flat stream of chunks. Each chunk is a 6-byte header followed by `count` fixed
//! size records, and the stream ends with a chunk whose tag is `0xFFFF`. Chunks carry no nesting;
//! the hierarchy comes from the order they appear in, which matches the order the engine's loader
//! asks for them (see `Model.parse`).
//!
//! The header's `record_size` is the format's versioning mechanism. Older exporters wrote shorter
//! records, and the loader copies `min(record_size, @sizeOf(struct))` bytes and leaves the rest of
//! the destination alone. `records` reproduces that, zero-filling instead, so a field added by a
//! later exporter reads as zero in a file written by an older one.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const models = @import("../engine/game/create/models.zig");

pub const Vec3 = extern struct {
    x: f32,
    y: f32,
    z: f32,

    pub const zero: Vec3 = .{ .x = 0, .y = 0, .z = 0 };

    /// Maps a model coordinate into the Y-up frame Wavefront OBJ and most viewers assume.
    ///
    /// The model frame has **Y pointing down and Z pointing forward** (see `docs/formats/shp.md`),
    /// so righting it is a half turn about the forward axis: X and Y flip, Z is left alone. That
    /// keeps the nose on `+Z`, where a viewer's default camera is looking, and it does not mirror
    /// the model, since negating two axes leaves the determinant positive and a ship's port and
    /// starboard where they were.
    pub fn toYUp(v: Vec3) Vec3 {
        return .{ .x = -v.x, .y = -v.y, .z = v.z };
    }

    pub fn min(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = @min(a.x, b.x), .y = @min(a.y, b.y), .z = @min(a.z, b.z) };
    }

    pub fn max(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = @max(a.x, b.x), .y = @max(a.y, b.y), .z = @max(a.z, b.z) };
    }
};

/// Chunk tags, in the order the loader requests them.
pub const Tag = enum(u16) {
    header = 0x00,
    part = 0x01,
    lod = 0x02,
    face = 0x03,
    vertex = 0x04,
    material = 0x06,
    tree_node = 0x07,
    node_face_list = 0x08,
    attachment = 0x09,
    animation_clip = 0x0A,
    keyframe = 0x0B,
    clip_event = 0x0C,
    face_group = 0x0D,
    group_entry = 0x0E,
    trigger_polygon = 0x0F,
    tail = 0x10,
    /// Ends the stream.
    end = 0xFFFF,
    _,
};

pub const ChunkHeader = extern struct {
    tag: Tag,
    /// Bytes per record in this file, which varies by exporter version.
    record_size: u16,
    count: u16,

    comptime {
        assert(@sizeOf(ChunkHeader) == 6);
    }
};

pub const Chunk = struct {
    tag: Tag,
    record_size: u16,
    count: u16,
    /// `count * record_size` bytes.
    data: []const u8,
};

// --- records ----------------------------------------------------------------------------------

/// Tag `0x00`. One per model. Files carry 20, 24 or 88 bytes of it.
pub const Header = extern struct {
    /// `107` in all but three shipped models, which carry `200`. The loader does not read it.
    version: u32,
    unknown_04: f32,
    /// The cockpit views' eye point, in the model's frame: `object_add_part` (`0x004760C0`) copies
    /// it to the object.
    eye: Vec3,
    flags: Flags,
    _reserved: [64]u8,

    pub const Flags = packed struct(u32) {
        /// Objects of the model list their components, and get no renderer object of their own.
        components: bool,
        /// The loader builds a second mesh set, used for the cloak effect.
        cloak: bool,
        _unknown2: u30,
    };

    comptime {
        assert(@sizeOf(Header) == 88);
    }
};

/// Tag `0x01`. One per part: a hull section, cockpit, turret, engine, door and so on. Parts form a
/// tree through `parent`, and each carries its own mesh levels.
pub const Part = extern struct {
    name_bytes: [64]u8,
    /// What the part is.
    class: Class,
    /// Origin, in the model's frame whatever the parent: the engine hangs every part from the
    /// object's root at it (`object_add_part`).
    position: Vec3,
    bounds_min: Vec3,
    bounds_max: Vec3,
    /// The part's mass properties, in its own frame, which `object_recentre` (`0x004769F0`) and
    /// `object_bounds` (`0x00476680`) take over into the object's: the integrals over its volume of
    /// x², y² and z²,
    second_moments: [3]f32,
    /// of xy, yz and xz,
    products: [3]f32,
    /// and of x, y and z;
    first_moments: [3]f32,
    /// the volume itself;
    volume: f32,
    /// and the mass of a unit of volume. **Unverified:** that the sums are over the part's volume;
    /// the engine uses them as such.
    density: f32,
    /// Index of the parent part, or `-1` for a root.
    parent: i32,
    /// A point on the part, at the far end of guns and the base of mounts.
    mount_point: Vec3,
    /// Row-major 3x3; identity or a quarter turn in the shipped models.
    orientation: [9]f32,
    unknown_c8: Vec3,
    /// Parts sharing a non-zero id belong to one assembly, such as a turret and its barrels.
    link_id: u32,
    yaw_min: f32,
    pitch_min: f32,
    roll_min: f32,
    yaw_max: f32,
    pitch_max: f32,
    roll_max: f32,
    flags: Flags,
    /// Read as a 16-bit value by the turret code.
    turret_kind: u16,
    _pad: u16,
    turret_slot: u32,
    _reserved: [60]u8,

    pub const Flags = packed struct(u32) {
        _unknown0: u1,
        /// A component of the object: the game object lists the part among its components, by
        /// whose index trigger qualifiers and squad members name it.
        component: bool,
        /// A part of a component's damaged model: hidden while the component is intact, shown
        /// when it is disabled, or destroyed with its damaged model kept. Static lights are baked
        /// separately for the two classes.
        damaged: bool,
        _unknown3: u1,
        /// Geomorph normals: the mesh builder also copies each vertex's next-level normal.
        geomorph_normals: bool,
        /// Geomorph positions, likewise.
        geomorph_positions: bool,
        /// Set by the loader when a static light exists in this part's class.
        has_static_light: bool,
        /// With `Lmaps` set, the loader also binds a texture named `l<material>`, which a
        /// hardware renderer adds over the part's `lit` faces.
        lightmap: bool,
        _unknown8: u4,
        /// A component the player can target: `object_collect_components` marks its node
        /// `targetable`, which cycling subtargets requires and `SetTargetable` changes.
        targetable: bool,
        _unknown13: u19,
    };

    pub fn name(part: *const Part) []const u8 {
        return sliceName(&part.name_bytes);
    }

    /// Applies the part's orientation, which is stored row-major.
    pub fn orient(part: *const Part, v: Vec3) Vec3 {
        const m = part.orientation;
        return .{
            .x = m[0] * v.x + m[1] * v.y + m[2] * v.z,
            .y = m[3] * v.x + m[4] * v.y + m[5] * v.z,
            .z = m[6] * v.x + m[7] * v.y + m[8] * v.z,
        };
    }

    /// What a part is, going by what the engine does with each class and by the parts' names.
    /// Classes 3, 9, 10 and 18 are turrets.
    pub const Class = enum(u32) {
        /// Hull sections, going by their names.
        hull = 1,
        /// A turret, with its own yaw and pitch limits.
        turret = 3,
        /// An engine. `create_object` counts them (`GameObject.engines`), and each one destroyed
        /// takes its share of the thrust (`GameObject.engines_intact`).
        engine = 5,
        /// A shield generator: an object with one has `shield_generator` until the part is
        /// destroyed.
        shield_generator = 6,
        _,
    };

    comptime {
        assert(@offsetOf(Part, "class") == 0x40);
        assert(@offsetOf(Part, "parent") == 0x94);
        assert(@offsetOf(Part, "link_id") == 0xD4);
        assert(@offsetOf(Part, "flags") == 0xF0);
        assert(@sizeOf(Part) == 312);
    }
};

/// Tag `0x09`. A point on a part where the engine mounts something: a gun or turret, a missile
/// pod, a light, a cargo pod. The engine keeps 124 bytes of each record, and exporters that write
/// longer ones add nothing it reads.
pub const Attachment = extern struct {
    kind: Kind,
    /// Relative to the part.
    position: Vec3,
    /// Row-major 3x3.
    orientation: [9]f32,
    /// Which model of its kind the engine mounts: `models.attachment(kind, id)`. A `light` takes
    /// its colour from it instead: 0 blue, 1 green, 2 yellow, 3 red, and nothing beyond
    /// (`static_lights_bake`).
    id: u32,
    _unknown_38: [0x10]u8,
    /// How large what the attachment holds is drawn. An `engine_glow` is scaled by all three, its
    /// length along Z then stretched by the throttle; a `light`'s sprite takes the second, seven
    /// times over, as how far it reaches either side of its centre (`node_draw`).
    size: [3]f32,
    /// How a `light` blinks, in ticks: the first is how long it stays on, the second how long it
    /// stays off. A light is baked into the meshes only while both are zero, so only a light that
    /// never blinks is baked (`static_lights_mark`).
    blink: [2]i32,
    /// Where in its own blink a `light` starts, so that lights side by side need not blink
    /// together (`node_draw`).
    blink_phase: i32,
    _unknown_60: [0x14]u8,
    /// How far a `light` reaches, times its brightness: the radius within which it lights a vertex.
    light_range: f32,
    /// A `light`'s brightness, which scales both its reach and the colour it adds. An attachment
    /// counts as a static light only while this is above zero.
    light_brightness: f32,

    /// Named after the models the engine loads for each kind, or what `node_mount` (`0x00499A10`)
    /// makes of them. **Unknown:** kinds 3 and 6 to 9; kind 3 becomes a node of kind 4, whose
    /// drawing is not yet understood.
    pub const Kind = enum(u32) {
        missile = 0,
        /// Mounted as an object of its own, whose components follow the model's.
        gun = 1,
        /// An engine's glow, which `node_draw` scales along its length by the throttle.
        engine_glow = 2,
        light = 4,
        /// Mounted as an object of its own, like a gun.
        pod = 5,
        _,
    };

    comptime {
        assert(@offsetOf(Attachment, "id") == 0x34);
        assert(@offsetOf(Attachment, "size") == 0x48);
        assert(@offsetOf(Attachment, "blink") == 0x54);
        assert(@offsetOf(Attachment, "blink_phase") == 0x5C);
        assert(@offsetOf(Attachment, "light_range") == 0x74);
        assert(@offsetOf(Attachment, "light_brightness") == 0x78);
        assert(@sizeOf(Attachment) == 0x7C);
    }
};

/// Tag `0x02`. One per level of detail of a part, up to nine. Records hold only the distance at
/// which the level takes over; its geometry follows in later chunks.
/// Tag `0x0A`. One of a part's animation tracks: how long it runs, how it plays unless its starter
/// says otherwise, and its name. The loader files the tracks named `startup`, `fire` and `deploy`
/// for the game to start by those names; `create_object` plays a part's `startup` track from the
/// start. Its keyframes and its events follow in chunks of their own. Older exporters wrote 8-byte
/// records, which stop two bytes into the name.
pub const Clip = extern struct {
    /// In the track's own time, which the part's node advances by its speed each simulation step.
    length: i32,
    /// How the track plays unless its starter says otherwise: 0 not at all, 1 once, 2 looping and
    /// 3 back and forth (`node_tree_update`).
    mode: i16,
    name_bytes: [18]u8,

    /// The name, up to its first NUL.
    pub fn name(clip: *const Clip) []const u8 {
        return std.mem.sliceTo(&clip.name_bytes, 0);
    }

    comptime {
        assert(@sizeOf(Clip) == 24);
    }
};

/// Tag `0x0B`. Where a track has its part at a time: angles in radians, which turn it about its
/// mount point in its own frame, and an offset added to its origin (`node_animate`,
/// `0x00499F40`). Between two keyframes the part moves in a straight line.
pub const Keyframe = extern struct {
    time: i32,
    angles: Vec3,
    offset: Vec3,

    comptime {
        assert(@sizeOf(Keyframe) == 28);
    }
};

/// Tag `0x0C`. Something a track sets off as it passes a time (`node_tree_update`): kind 0 fires
/// the muzzle flashes of the part's guns, the part's nodes of kind 4, and kind 2 puffs particles
/// from the part's attachments of kind 7. The update knows no other kinds. **Unknown:** the third
/// field.
pub const ClipEvent = extern struct {
    time: i32,
    kind: i32,
    _unknown_08: i32,

    comptime {
        assert(@sizeOf(ClipEvent) == 12);
    }
};

/// A clip with its keyframes and events, as the loader keeps them, `0x28` bytes a track.
pub const Track = struct {
    clip: Clip,
    keyframes: []Keyframe,
    events: []ClipEvent,
};

pub const Lod = extern struct {
    /// `0` for single-level parts, otherwise a rising sequence such as 5000, 10000, 15000.
    switch_distance: f32,

    comptime {
        assert(@sizeOf(Lod) == 4);
    }
};

/// Tag `0x04`. Files carry 28 or 32 bytes; the older form has no `next_lod_vertex`.
pub const Vertex = extern struct {
    position: Vec3,
    normal: Vec3,
    unknown_18: u32,
    /// This vertex's counterpart in the next, coarser level, for geomorphing. `-1` when it has
    /// none, and absent from 28-byte records, where it reads as zero.
    next_lod_vertex: i32,

    comptime {
        assert(@sizeOf(Vertex) == 32);
    }
};

/// Tag `0x03`. Always one triangle. Files carry 72 or 80 bytes; the older form stops after
/// `edge_mask` and so carries no polygon grouping.
pub const Face = extern struct {
    /// Index into this level's material list.
    material: u32,
    shading: Shading,
    flags: Flags,
    /// Indices into this level's vertex list.
    vertices: [3]u32,
    /// Texture coordinates, per corner.
    u: [3]f32,
    v: [3]f32,
    /// Unit length in almost every record. The loader compares a fan's records' normals to merge
    /// them.
    normal: Vec3,
    unknown_15: u32,
    /// A third of it is added to the depth by which blended faces are sorted.
    sort_bias: f32,
    /// For wire shading: edge *k* is drawn unless bit *k* is set.
    edge_mask: u32,
    polygon: Polygon,
    /// Records still to come in the same polygon or strip, counting down to zero.
    remaining: u32,

    /// Each mode's material is in `engine/game/srofiles.zig`, and what the renderer does with it
    /// in `docs/engine/rendering.md`.
    pub const Shading = packed struct(u32) {
        mode: Mode,
        /// For `lit_highlight`, which of the Direct3D driver's highlight textures the second pass
        /// adds. Other modes ignore it.
        sub_mode: u4,
        _unused: u24,

        pub const Mode = enum(u4) {
            /// Untextured, lit, opaque.
            untextured = 0,
            /// Lines along the edges `edge_mask` leaves unset, drawn as `untextured`.
            wire = 1,
            /// Untextured, lit, added.
            untextured_additive = 2,
            /// Textured, unlit, opaque.
            unlit = 3,
            /// Textured, unlit, added.
            unlit_additive = 4,
            /// Textured, unlit, blended by the texture's alpha.
            unlit_blended = 5,
            /// Textured, lit, opaque; on parts flagged `lightmap`, a light map added over it.
            lit = 6,
            /// Textured, lit, opaque, with a highlight added over it.
            lit_highlight = 7,
            /// Textured, lit, added. The loader treats `10` the same.
            lit_additive = 8,
            _,
        };
    };

    pub const Flags = packed struct(u32) {
        /// Hidden while bit 0 of the object's face mask is set, as it is from creation. The
        /// fighters close the body and the cockpit where the two parts meet with such faces.
        cap: bool = false,
        /// Never culled for facing away while bit 1 of the object's face mask is set, as it is
        /// from creation.
        two_sided: bool = false,
        _unread: u30 = 0,
    };

    /// How a record joins to its neighbours to form a larger polygon.
    pub const Polygon = enum(u32) {
        triangle = 0,
        /// Part of a triangle fan, which the loader merges into one polygon when each later
        /// record's normal lies within about 2.6 degrees of the first's.
        fan = 1,
        strip_even = 2,
        /// Lists its last two corners the other way round: its front is the side
        /// `(v2 - v0) x (v1 - v0)` points to, where every other face's is `(v1 - v0) x (v2 - v0)`.
        strip_odd = 3,
        _,
    };

    comptime {
        assert(@sizeOf(Face) == 80);
    }
};

/// Tag `0x06`. A texture name without its extension, resolved through the image registry with a
/// context-dependent `g` or `r` prefix.
pub const Material = extern struct {
    name_bytes: [64]u8,

    pub fn name(material: *const Material) []const u8 {
        return sliceName(&material.name_bytes);
    }

    comptime {
        assert(@sizeOf(Material) == 64);
    }
};

fn sliceName(bytes: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, bytes, 0) orelse bytes.len;
    return bytes[0..end];
}

// --- reading ----------------------------------------------------------------------------------

pub const Error = error{
    /// A chunk header or its records run past the end of the file.
    Truncated,
    /// The stream ended without a terminator chunk.
    NoTerminator,
    /// The stream does not begin with a header chunk.
    NotAModel,
};

/// Walks the chunk stream the way the loader does: `take` scans forward for a tag and, on a miss,
/// leaves the cursor where it was so the next request can still find an earlier chunk.
pub const Reader = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn init(data: []const u8) Reader {
        return .{ .data = data };
    }

    /// Reads the chunk at `offset` without moving the cursor.
    fn at(reader: Reader, offset: usize) Error!Chunk {
        if (offset + @sizeOf(ChunkHeader) > reader.data.len) return error.Truncated;
        const header: *align(1) const ChunkHeader = @ptrCast(reader.data[offset..][0..@sizeOf(ChunkHeader)]);
        const body = offset + @sizeOf(ChunkHeader);
        const len = @as(usize, header.record_size) * header.count;
        if (body + len > reader.data.len) return error.Truncated;
        return .{
            .tag = header.tag,
            .record_size = header.record_size,
            .count = header.count,
            .data = reader.data[body..][0..len],
        };
    }

    /// Advances to the next chunk, or null at the terminator.
    pub fn next(reader: *Reader) Error!?Chunk {
        const chunk = try reader.at(reader.pos);
        if (chunk.tag == .end) return null;
        reader.pos += @sizeOf(ChunkHeader) + chunk.data.len;
        return chunk;
    }

    /// Scans forward for `tag`. On a match the cursor moves past that chunk; on reaching the
    /// terminator the cursor is left untouched and null is returned.
    pub fn take(reader: *Reader, tag: Tag) Error!?Chunk {
        var scan = reader.pos;
        while (true) {
            const chunk = try reader.at(scan);
            if (chunk.tag == .end) return null;
            scan += @sizeOf(ChunkHeader) + chunk.data.len;
            if (chunk.tag == tag) {
                reader.pos = scan;
                return chunk;
            }
        }
    }

    /// `take`, decoded into records of `T`.
    pub fn takeRecords(reader: *Reader, comptime T: type, gpa: Allocator, tag: Tag) ![]T {
        const chunk = try reader.take(tag) orelse return gpa.alloc(T, 0);
        return records(T, gpa, chunk);
    }
};

/// Copies a chunk's records into `T`, exactly as the loader does: `min(record_size, @sizeOf(T))`
/// bytes each, with anything the file does not carry left zeroed.
pub fn records(comptime T: type, gpa: Allocator, chunk: Chunk) Allocator.Error![]T {
    const out = try gpa.alloc(T, chunk.count);
    @memset(std.mem.sliceAsBytes(out), 0);

    const copy = @min(@as(usize, chunk.record_size), @sizeOf(T));
    for (out, 0..) |*record, i| {
        @memcpy(std.mem.asBytes(record)[0..copy], chunk.data[i * chunk.record_size ..][0..copy]);
    }
    return out;
}

// --- model ------------------------------------------------------------------------------------

/// One level of detail of a part.
pub const Mesh = struct {
    lod: Lod,
    vertices: []Vertex,
    faces: []Face,
    materials: []Material,

    pub fn bounds(mesh: Mesh) struct { Vec3, Vec3 } {
        return mesh.boundsIn(null);
    }

    /// Extent of the mesh, optionally after applying `part`'s orientation.
    pub fn boundsIn(mesh: Mesh, part: ?*const Part) struct { Vec3, Vec3 } {
        if (mesh.vertices.len == 0) return .{ .zero, .zero };
        const place = struct {
            fn at(p: ?*const Part, v: Vec3) Vec3 {
                return if (p) |owner| owner.orient(v) else v;
            }
        };
        var lo = place.at(part, mesh.vertices[0].position);
        var hi = lo;
        for (mesh.vertices[1..]) |vertex| {
            const v = place.at(part, vertex.position);
            lo = Vec3.min(lo, v);
            hi = Vec3.max(hi, v);
        }
        return .{ lo, hi };
    }
};

pub const PartData = struct {
    part: Part,
    meshes: []Mesh,
    attachments: []Attachment,
    /// Its animation tracks, in the order the file lists them.
    tracks: []Track,
    /// Chunks that are read but not yet interpreted, kept as counts.
    node_count: usize,
    group_count: usize,
    trigger_count: usize,
};

/// A parsed model. Everything is allocated from the allocator passed to `parse`, which is expected
/// to be an arena.
pub const Model = struct {
    header: Header,
    parts: []PartData,
    tail_count: usize,
    /// Bytes after the terminator, which should be zero.
    trailing_bytes: usize,

    /// Reads a model, following the loader's request order:
    ///
    ///     header, parts, then per part: levels, nodes, attachments, clips, groups, triggers,
    ///     then per level: vertices, faces, materials, then per node, clip and group their own
    ///     lists, and finally the tail.
    pub fn parse(gpa: Allocator, data: []const u8) !Model {
        var reader: Reader = .init(data);

        const headers = try reader.takeRecords(Header, gpa, .header);
        if (headers.len == 0) return error.NotAModel;

        const parts = try reader.takeRecords(Part, gpa, .part);
        const out = try gpa.alloc(PartData, parts.len);

        for (parts, out) |part, *entry| {
            const lods = try reader.takeRecords(Lod, gpa, .lod);
            const nodes = try reader.take(.tree_node);
            const attachments = try reader.takeRecords(Attachment, gpa, .attachment);
            const clips = try reader.takeRecords(Clip, gpa, .animation_clip);
            const groups = try reader.take(.face_group);
            const triggers = try reader.take(.trigger_polygon);

            const meshes = try gpa.alloc(Mesh, lods.len);
            for (lods, meshes) |lod, *mesh| {
                mesh.* = .{
                    .lod = lod,
                    .vertices = try reader.takeRecords(Vertex, gpa, .vertex),
                    .faces = try reader.takeRecords(Face, gpa, .face),
                    .materials = try reader.takeRecords(Material, gpa, .material),
                };
            }

            const node_count = if (nodes) |chunk| chunk.count else 0;
            const group_count = if (groups) |chunk| chunk.count else 0;

            // Per-node, per-clip and per-group lists follow the level geometry.
            for (0..node_count) |_| _ = try reader.take(.node_face_list);
            const tracks = try gpa.alloc(Track, clips.len);
            for (clips, tracks) |clip, *track| {
                track.* = .{
                    .clip = clip,
                    .keyframes = try reader.takeRecords(Keyframe, gpa, .keyframe),
                    .events = try reader.takeRecords(ClipEvent, gpa, .clip_event),
                };
            }
            for (0..group_count) |_| _ = try reader.take(.group_entry);

            entry.* = .{
                .part = part,
                .meshes = meshes,
                .node_count = node_count,
                .attachments = attachments,
                .tracks = tracks,
                .group_count = group_count,
                .trigger_count = if (triggers) |chunk| chunk.count else 0,
            };
        }

        const tail = try reader.take(.tail);

        // The terminator should be the last thing in the file.
        var scan: Reader = .init(data);
        while (try scan.next()) |_| {}
        const end = scan.pos + @sizeOf(ChunkHeader);

        return .{
            .header = headers[0],
            .parts = out,
            .tail_count = if (tail) |chunk| chunk.count else 0,
            .trailing_bytes = data.len - @min(end, data.len),
        };
    }

    pub fn vertexCount(model: Model) usize {
        var total: usize = 0;
        for (model.parts) |part| {
            for (part.meshes) |mesh| total += mesh.vertices.len;
        }
        return total;
    }

    pub fn faceCount(model: Model) usize {
        var total: usize = 0;
        for (model.parts) |part| {
            for (part.meshes) |mesh| total += mesh.faces.len;
        }
        return total;
    }
};

// --- tests ------------------------------------------------------------------------------------

/// Builds models in memory, for the tests of code that reads them.
pub const testing = struct {
    /// A one-part model written into `buffer`, as `Model.parse` reads it; returns the bytes used.
    pub const buildModel = buildTestModel;
};

/// Builds a one-part, one-level model in memory: the smallest stream the parser accepts.
fn buildTestModel(buffer: []u8) []u8 {
    var pos: usize = 0;

    const put = struct {
        fn chunk(buf: []u8, at: usize, tag: Tag, record_size: u16, count: u16) usize {
            const header: *align(1) ChunkHeader = @ptrCast(buf[at..][0..@sizeOf(ChunkHeader)]);
            header.* = .{ .tag = tag, .record_size = record_size, .count = count };
            return at + @sizeOf(ChunkHeader);
        }
    };

    pos = put.chunk(buffer, pos, .header, @sizeOf(Header), 1);
    const header: *align(1) Header = @ptrCast(buffer[pos..][0..@sizeOf(Header)]);
    header.* = std.mem.zeroes(Header);
    header.version = 107;
    header.flags.cloak = true;
    pos += @sizeOf(Header);

    pos = put.chunk(buffer, pos, .part, @sizeOf(Part), 1);
    const part: *align(1) Part = @ptrCast(buffer[pos..][0..@sizeOf(Part)]);
    part.* = std.mem.zeroes(Part);
    @memcpy(part.name_bytes[0..4], "Hull");
    part.parent = -1;
    part.class = .turret;
    pos += @sizeOf(Part);

    pos = put.chunk(buffer, pos, .lod, @sizeOf(Lod), 1);
    @as(*align(1) Lod, @ptrCast(buffer[pos..][0..@sizeOf(Lod)])).* = .{ .switch_distance = 0 };
    pos += @sizeOf(Lod);

    // A 28-byte vertex record: the older form, without the geomorph index.
    const old_vertex_size = 28;
    pos = put.chunk(buffer, pos, .vertex, old_vertex_size, 3);
    for (0..3) |i| {
        @memset(buffer[pos..][0..old_vertex_size], 0);
        const vertex: *align(1) Vertex = @ptrCast(buffer[pos..][0..old_vertex_size]);
        vertex.position = .{ .x = @floatFromInt(i), .y = 1, .z = 2 };
        pos += old_vertex_size;
    }

    pos = put.chunk(buffer, pos, .face, @sizeOf(Face), 1);
    const face: *align(1) Face = @ptrCast(buffer[pos..][0..@sizeOf(Face)]);
    face.* = std.mem.zeroes(Face);
    face.vertices = .{ 0, 1, 2 };
    face.shading.mode = .lit;
    pos += @sizeOf(Face);

    pos = put.chunk(buffer, pos, .material, @sizeOf(Material), 1);
    const material: *align(1) Material = @ptrCast(buffer[pos..][0..@sizeOf(Material)]);
    material.* = std.mem.zeroes(Material);
    @memcpy(material.name_bytes[0..6], "Yank_1");
    pos += @sizeOf(Material);

    pos = put.chunk(buffer, pos, .end, 0, 0);
    return buffer[0..pos];
}

test "parses a model" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var buffer: [1024]u8 = undefined;
    const data = buildTestModel(&buffer);

    const model = try Model.parse(arena, data);
    try std.testing.expectEqual(@as(u32, 107), model.header.version);
    try std.testing.expect(model.header.flags.cloak);
    try std.testing.expectEqual(@as(usize, 1), model.parts.len);
    try std.testing.expectEqual(@as(usize, 0), model.trailing_bytes);

    const part = model.parts[0];
    try std.testing.expectEqualStrings("Hull", part.part.name());
    try std.testing.expectEqual(@as(i32, -1), part.part.parent);
    try std.testing.expectEqual(@as(usize, 1), part.meshes.len);

    const mesh = part.meshes[0];
    try std.testing.expectEqual(@as(usize, 3), mesh.vertices.len);
    try std.testing.expectEqual(@as(usize, 1), mesh.faces.len);
    try std.testing.expectEqualStrings("Yank_1", mesh.materials[0].name());
    try std.testing.expectEqual(Face.Shading.Mode.lit, mesh.faces[0].shading.mode);
    try std.testing.expectEqual(@as(f32, 2), mesh.vertices[2].position.x);

    // The short vertex records carry no geomorph index, which must read as zero rather than as
    // whatever followed it in the file.
    try std.testing.expectEqual(@as(i32, 0), mesh.vertices[0].next_lod_vertex);

    const lo, const hi = mesh.bounds();
    try std.testing.expectEqual(@as(f32, 0), lo.x);
    try std.testing.expectEqual(@as(f32, 2), hi.x);
}

test "a missing chunk does not move the cursor" {
    var buffer: [1024]u8 = undefined;
    const data = buildTestModel(&buffer);

    var reader: Reader = .init(data);
    // Nothing in this stream carries trigger polygons, so the search must fail without consuming
    // the header chunk that follows the cursor.
    try std.testing.expectEqual(@as(?Chunk, null), try reader.take(.trigger_polygon));
    try std.testing.expectEqual(@as(usize, 0), reader.pos);

    const header = (try reader.take(.header)).?;
    try std.testing.expectEqual(@as(u16, 1), header.count);
    try std.testing.expect(reader.pos > 0);
}

test "truncated streams are rejected" {
    var buffer: [1024]u8 = undefined;
    const data = buildTestModel(&buffer);

    var short: Reader = .init(data[0 .. data.len - 8]);
    try std.testing.expectError(error.Truncated, short.take(.end));

    var empty: Reader = .init(&.{});
    try std.testing.expectError(error.Truncated, empty.next());
}

test "righting a model is a half turn, not a mirror" {
    const v: Vec3 = .{ .x = 1, .y = 2, .z = 3 };
    const up = v.toYUp();
    try std.testing.expectEqual(Vec3{ .x = -1, .y = -2, .z = 3 }, up);
    // Applying it twice returns the original, and the nose stays on +Z.
    try std.testing.expectEqual(v, up.toYUp());

    // A half turn preserves chirality: the cross product of two axes keeps its handedness, so a
    // model is reoriented rather than mirrored.
    const x = (Vec3{ .x = 1, .y = 0, .z = 0 }).toYUp();
    const y = (Vec3{ .x = 0, .y = 1, .z = 0 }).toYUp();
    const cross_z = x.x * y.y - x.y * y.x;
    try std.testing.expectEqual(@as(f32, 1), cross_z);
}

test "record sizes and field offsets match the format" {
    try std.testing.expectEqual(@as(usize, 88), @sizeOf(Header));
    try std.testing.expectEqual(@as(usize, 312), @sizeOf(Part));
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(Lod));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(Vertex));
    try std.testing.expectEqual(@as(usize, 80), @sizeOf(Face));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(Material));
    try std.testing.expectEqual(@as(usize, 0x44), @offsetOf(Part, "position"));
    try std.testing.expectEqual(@as(usize, 0xD8), @offsetOf(Part, "yaw_min"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(Face, "u"));
}

// --- components -------------------------------------------------------------------------------

/// A part that the engine lists among an object's components, which triggers, squads and scripts
/// name by index.
pub const Component = struct {
    /// The model the part is in: the object's own, or one mounted on it.
    model: []const u8,
    part: *const Part,
    /// Index of the part in its model.
    part_index: usize,
    /// Mounts between the object's model and the part's: zero for its own parts.
    depth: usize,
};

/// Components an object can list; the engine stops with a fatal error past the last.
pub const max_components = 60;

/// How deep `components` follows mounts before giving up, which also stops a model that mounts
/// itself.
pub const max_mount_depth = 8;

/// The components of an object of the model `name`, in the engine's order
/// (`object_collect_components`): first the model's own parts whose flags mark them, then for each
/// part, in order, the components of the models mounted on its gun and pod attachment points,
/// found the same way. `mounts.load(file_name)` returns a mounted model, or null when it is
/// missing, which leaves that model's components out of the list.
///
/// Empty unless the model's header flags ask for components.
pub fn components(gpa: Allocator, model: Model, name: []const u8, mounts: anytype) ![]Component {
    var list: std.ArrayList(Component) = .empty;
    errdefer list.deinit(gpa);
    if (model.header.flags.components) try collect(gpa, &list, model, name, 0, mounts);
    return list.toOwnedSlice(gpa);
}

fn collect(
    gpa: Allocator,
    list: *std.ArrayList(Component),
    model: Model,
    name: []const u8,
    depth: usize,
    mounts: anytype,
) !void {
    if (depth > max_mount_depth) return error.MountsTooDeep;
    for (model.parts, 0..) |*entry, index| {
        if (!entry.part.flags.component) continue;
        try list.append(gpa, .{ .model = name, .part = &entry.part, .part_index = index, .depth = depth });
    }
    for (model.parts) |entry| {
        for (entry.attachments) |attachment| {
            switch (attachment.kind) {
                .gun, .pod => {},
                else => continue,
            }
            const mounted = models.attachment(attachment.kind, attachment.id) orelse continue;
            const file = mounted.model orelse continue;
            const sub = try mounts.load(file) orelse continue;
            try collect(gpa, list, sub, file, depth + 1, mounts);
        }
    }
}

/// A part for the component tests, named `name` and marked as a component or not.
fn testPart(name: []const u8, component: bool, attachments: []Attachment) PartData {
    var part = std.mem.zeroes(Part);
    @memcpy(part.name_bytes[0..name.len], name);
    part.parent = -1;
    part.flags.component = component;
    return .{
        .part = part,
        .meshes = &.{},
        .attachments = attachments,
        .tracks = &.{},
        .node_count = 0,
        .group_count = 0,
        .trigger_count = 0,
    };
}

fn testModel(parts: []PartData, list_components: bool) Model {
    var header = std.mem.zeroes(Header);
    header.flags.components = list_components;
    return .{ .header = header, .parts = parts, .tail_count = 0, .trailing_bytes = 0 };
}

fn testAttachment(kind: Attachment.Kind, id: u32) Attachment {
    var attachment = std.mem.zeroes(Attachment);
    attachment.kind = kind;
    attachment.id = id;
    return attachment;
}

/// Mounts one model under the file name the engine loads for guns of id 0, and nothing else.
const TestMounts = struct {
    gun: ?Model,

    const gun_file = models.attachment(.gun, 0).?.model.?;

    pub fn load(mounts: TestMounts, file: []const u8) !?Model {
        return if (std.mem.eql(u8, file, gun_file)) mounts.gun else null;
    }
};

test "components are the marked parts, then those of the mounted models" {
    const gpa = std.testing.allocator;
    var barrel = [_]PartData{ testPart("Base", false, &.{}), testPart("Barrel", true, &.{}) };
    var mounts_on_hull = [_]Attachment{
        testAttachment(.gun, 0),
        // Lights mount nothing that lists components.
        testAttachment(.light, 0),
    };
    var hull = [_]PartData{
        testPart("Hull", false, &mounts_on_hull),
        testPart("Engine", true, &.{}),
        testPart("Shield", true, &.{}),
    };
    const mounts: TestMounts = .{ .gun = testModel(&barrel, false) };

    const listed = try components(gpa, testModel(&hull, true), "SHIP.SHP", mounts);
    defer gpa.free(listed);
    try std.testing.expectEqual(3, listed.len);
    try std.testing.expectEqualStrings("Engine", listed[0].part.name());
    try std.testing.expectEqual(1, listed[0].part_index);
    try std.testing.expectEqualStrings("SHIP.SHP", listed[0].model);
    try std.testing.expectEqualStrings("Shield", listed[1].part.name());
    try std.testing.expectEqual(0, listed[1].depth);
    // A mounted model's parts follow, whatever its own header says.
    try std.testing.expectEqualStrings("Barrel", listed[2].part.name());
    try std.testing.expectEqualStrings(TestMounts.gun_file, listed[2].model);
    try std.testing.expectEqual(1, listed[2].depth);
}

test "a model whose header does not ask lists no components" {
    const gpa = std.testing.allocator;
    var hull = [_]PartData{testPart("Engine", true, &.{})};
    const listed = try components(gpa, testModel(&hull, false), "SHIP.SHP", TestMounts{ .gun = null });
    defer gpa.free(listed);
    try std.testing.expectEqual(0, listed.len);
}

test "a missing mounted model leaves its components out" {
    const gpa = std.testing.allocator;
    var mounts_on_hull = [_]Attachment{testAttachment(.gun, 0)};
    var hull = [_]PartData{ testPart("Hull", false, &mounts_on_hull), testPart("Engine", true, &.{}) };
    const listed = try components(gpa, testModel(&hull, true), "SHIP.SHP", TestMounts{ .gun = null });
    defer gpa.free(listed);
    try std.testing.expectEqual(1, listed.len);
}

test "a model that mounts itself stops at the depth limit" {
    const gpa = std.testing.allocator;
    var mounts_on_gun = [_]Attachment{testAttachment(.gun, 0)};
    var gun = [_]PartData{testPart("Barrel", true, &mounts_on_gun)};
    const model = testModel(&gun, true);
    try std.testing.expectError(error.MountsTooDeep, components(gpa, model, TestMounts.gun_file, TestMounts{ .gun = model }));
}
