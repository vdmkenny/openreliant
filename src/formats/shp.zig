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
    unknown_08: Vec3,
    flags: Flags,
    _reserved: [64]u8,

    pub const Flags = packed struct(u32) {
        _unknown0: u1,
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
    /// Subsystem class. The engine special-cases 1, 6, and the turret set {3, 9, 10, 18}.
    part_type: u32,
    /// Origin, relative to the parent part.
    position: Vec3,
    bounds_min: Vec3,
    bounds_max: Vec3,
    /// Scales like sums of squared coordinates. Not read by the loader.
    unknown_68: [6]f32,
    unknown_80: [3]f32,
    unknown_8c: f32,
    unknown_90: f32,
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
        /// On multitexture hardware, bind a second texture named `l<material>`.
        lightmap: bool,
        _unknown8: u4,
        /// Propagated to the spawned sub-object.
        propagate: bool,
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

    comptime {
        assert(@offsetOf(Part, "part_type") == 0x40);
        assert(@offsetOf(Part, "parent") == 0x94);
        assert(@offsetOf(Part, "link_id") == 0xD4);
        assert(@offsetOf(Part, "flags") == 0xF0);
        assert(@sizeOf(Part) == 312);
    }
};

/// Tag `0x02`. One per level of detail of a part, up to nine. Records hold only the distance at
/// which the level takes over; its geometry follows in later chunks.
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
    /// The low two bits reach the renderer's per-face flags.
    flags: u32,
    /// Indices into this level's vertex list.
    vertices: [3]u32,
    /// Texture coordinates, per corner.
    u: [3]f32,
    v: [3]f32,
    /// Unit length in almost every record. Not read by the loader.
    normal: Vec3,
    unknown_15: u32,
    unknown_16: f32,
    /// For wire shading: edge *k* is drawn unless bit *k* is set.
    edge_mask: u32,
    polygon: Polygon,
    /// Records still to come in the same polygon or strip, counting down to zero.
    remaining: u32,

    pub const Shading = packed struct(u32) {
        mode: Mode,
        /// Forwarded to the renderer for `multitexture` shading.
        sub_mode: u4,
        _unused: u24,

        pub const Mode = enum(u4) {
            flat = 0,
            /// Line primitives for the edges `edge_mask` leaves unset, not a filled triangle.
            wire = 1,
            wire_shaded = 2,
            textured = 3,
            textured_alpha = 4,
            textured_blend = 5,
            /// The common case: textured and lit.
            lit = 6,
            multitexture = 7,
            lit_alpha = 8,
            _,
        };
    };

    /// How a record joins to its neighbours to form a larger polygon.
    pub const Polygon = enum(u32) {
        triangle = 0,
        /// Part of a triangle fan, which the loader merges into one N-gon when the corners are
        /// coplanar to within about 2.6 degrees.
        fan = 1,
        strip_even = 2,
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
    /// Chunks that are read but not yet interpreted, kept as counts.
    node_count: usize,
    attachment_count: usize,
    clip_count: usize,
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
            const attachments = try reader.take(.attachment);
            const clips = try reader.take(.animation_clip);
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
            const clip_count = if (clips) |chunk| chunk.count else 0;
            const group_count = if (groups) |chunk| chunk.count else 0;

            // Per-node, per-clip and per-group lists follow the level geometry.
            for (0..node_count) |_| _ = try reader.take(.node_face_list);
            for (0..clip_count) |_| {
                _ = try reader.take(.keyframe);
                _ = try reader.take(.clip_event);
            }
            for (0..group_count) |_| _ = try reader.take(.group_entry);

            entry.* = .{
                .part = part,
                .meshes = meshes,
                .node_count = node_count,
                .attachment_count = if (attachments) |chunk| chunk.count else 0,
                .clip_count = clip_count,
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
    part.part_type = 3;
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
