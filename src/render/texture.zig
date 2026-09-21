//! Textures as the renderer samples them: RGBA mip chains, decoded from the texture cache or made by
//! the Direct3D driver's rules.

const std = @import("std");
const Allocator = std.mem.Allocator;

const tcache = @import("../formats/tcache.zig");
const tga = @import("../formats/tga.zig");
const srd3d = @import("../lancer/surrender/srd3d/srd3d.zig");

pub const Level = struct {
    width: u32,
    height: u32,
    /// Red, green, blue and alpha, row by row from the top.
    rgba: []const u8,
};

pub const Texture = struct {
    /// The full-size image first.
    levels: []const Level,

    /// The texel at `u`, `v` of `level`, filtered bilinearly and wrapping, as the driver samples.
    pub fn sample(texture: Texture, level: usize, u: f32, v: f32) [4]f32 {
        const l = texture.levels[@min(level, texture.levels.len - 1)];
        const x = u * @as(f32, @floatFromInt(l.width)) - 0.5;
        const y = v * @as(f32, @floatFromInt(l.height)) - 0.5;
        const x0 = @floor(x);
        const y0 = @floor(y);
        const fx = x - x0;
        const fy = y - y0;
        const ix = std.math.lossyCast(i64, x0);
        const iy = std.math.lossyCast(i64, y0);
        var out: [4]f32 = @splat(0);
        const weights = [4]f32{ (1 - fx) * (1 - fy), fx * (1 - fy), (1 - fx) * fy, fx * fy };
        for (weights, 0..) |weight, corner| {
            const cx = wrap(ix + @as(i64, @intCast(corner & 1)), l.width);
            const cy = wrap(iy + @as(i64, @intCast(corner >> 1)), l.height);
            const texel = l.rgba[(cy * l.width + cx) * 4 ..][0..4];
            for (&out, texel) |*c, t| c.* += @as(f32, @floatFromInt(t)) / 255 * weight;
        }
        return out;
    }
};

fn wrap(i: i64, size: u32) usize {
    return @intCast(@mod(i, @as(i64, size)));
}

/// Textures by name from a texture cache, decoded once with one palette.
pub const Library = struct {
    gpa: Allocator,
    cache: tcache.Cache,
    palette: tga.Palette,
    decoded: std.StringHashMapUnmanaged(?*Texture) = .empty,
    highlights: [8]Texture,

    pub fn init(gpa: Allocator, cache: tcache.Cache, palette: tga.Palette) Allocator.Error!Library {
        var library: Library = .{ .gpa = gpa, .cache = cache, .palette = palette, .highlights = undefined };
        var made: usize = 0;
        errdefer for (library.highlights[0..made]) |h| freeTexture(gpa, h);
        for (&library.highlights, 0..) |*h, index| {
            h.* = try makeHighlight(gpa, @intCast(index));
            made += 1;
        }
        return library;
    }

    pub fn deinit(library: *Library) void {
        var it = library.decoded.iterator();
        while (it.next()) |entry| {
            library.gpa.free(entry.key_ptr.*);
            if (entry.value_ptr.*) |texture| {
                freeTexture(library.gpa, texture.*);
                library.gpa.destroy(texture);
            }
        }
        library.decoded.deinit(library.gpa);
        for (library.highlights) |h| freeTexture(library.gpa, h);
    }

    /// The texture the engine finds for `name`, or null when the cache has none.
    pub fn find(library: *Library, name: []const u8) Allocator.Error!?*const Texture {
        return library.lookUp("", name);
    }

    /// The light map a part flagged `lightmap` binds for the material `name`: the texture named `l`
    /// and the material's name.
    pub fn findLightMap(library: *Library, name: []const u8) Allocator.Error!?*const Texture {
        return library.lookUp("l", name);
    }

    fn lookUp(library: *Library, prefix: []const u8, name: []const u8) Allocator.Error!?*const Texture {
        const key = try std.mem.concat(library.gpa, u8, &.{ prefix, tcache.fileName(name) });
        for (key) |*c| c.* = std.ascii.toLower(c.*);
        const entry = library.decoded.getOrPut(library.gpa, key) catch |err| {
            library.gpa.free(key);
            return err;
        };
        if (entry.found_existing) {
            library.gpa.free(key);
            return entry.value_ptr.*;
        }
        entry.value_ptr.* = null;
        const found = library.cache.find(key) orelse return null;
        const texture = try library.gpa.create(Texture);
        errdefer library.gpa.destroy(texture);
        texture.* = try decode(library.gpa, found, &library.palette);
        entry.value_ptr.* = texture;
        return texture;
    }

    pub fn highlight(library: *const Library, index: u3) *const Texture {
        return &library.highlights[index];
    }
};

fn decode(gpa: Allocator, texture: tcache.Texture, palette: *const tga.Palette) Allocator.Error!Texture {
    var levels: std.ArrayList(Level) = .empty;
    errdefer {
        for (levels.items) |l| gpa.free(l.rgba);
        levels.deinit(gpa);
    }
    var n: u32 = 0;
    while (texture.level(n)) |source| : (n += 1) {
        const rgba = try source.rgba(gpa, palette);
        errdefer gpa.free(rgba);
        try levels.append(gpa, .{ .width = source.width, .height = source.height, .rgba = rgba });
    }
    return .{ .levels = try levels.toOwnedSlice(gpa) };
}

fn makeHighlight(gpa: Allocator, index: u3) Allocator.Error!Texture {
    const texels = srd3d.highlight(index);
    const rgba = try gpa.dupe(u8, std.mem.asBytes(&texels));
    errdefer gpa.free(rgba);
    const levels = try gpa.alloc(Level, 1);
    levels[0] = .{ .width = srd3d.highlight_size, .height = srd3d.highlight_size, .rgba = rgba };
    return .{ .levels = levels };
}

fn freeTexture(gpa: Allocator, texture: Texture) void {
    for (texture.levels) |l| gpa.free(l.rgba);
    gpa.free(texture.levels);
}

test "samples bilinearly and wraps" {
    const rgba = [_]u8{ 0, 0, 0, 255, 255, 255, 255, 255 };
    const levels = [_]Level{.{ .width = 2, .height = 1, .rgba = &rgba }};
    const texture: Texture = .{ .levels = &levels };
    // Texel centres give the texels; between them, the mean.
    try std.testing.expectEqual([4]f32{ 0, 0, 0, 1 }, texture.sample(0, 0.25, 0.5));
    try std.testing.expectEqual([4]f32{ 1, 1, 1, 1 }, texture.sample(0, 0.75, 0.5));
    try std.testing.expectEqual([4]f32{ 0.5, 0.5, 0.5, 1 }, texture.sample(0, 0.5, 0.5));
    // Past the edge it wraps around.
    try std.testing.expectEqual([4]f32{ 0.5, 0.5, 0.5, 1 }, texture.sample(0, 1.0, 0.5));
}

test Library {
    const gpa = std.testing.allocator;
    const bytes = try tcache.testing.build(gpa, &.{
        .{ .name = "Kiev_1", .encoding = .index8, .width = 2, .height = 2 },
        .{ .name = "lKiev_1", .encoding = .index8, .width = 2, .height = 2 },
    });
    defer gpa.free(bytes);
    const cache: tcache.Cache = try .parse(gpa, bytes);
    defer cache.deinit(gpa);
    var palette: tga.Palette = undefined;
    for (&palette, 0..) |*c, i| c.* = .{ @truncate(i), 0, 0 };

    var library: Library = try .init(gpa, cache, palette);
    defer library.deinit();
    const kiev = (try library.find("KIEV_1")).?;
    try std.testing.expectEqual(2, kiev.levels[0].width);
    // The same texture again, and none for a name the cache lacks.
    try std.testing.expectEqual(kiev, (try library.find("kiev_1")).?);
    try std.testing.expectEqual(null, try library.find("missing"));
    try std.testing.expect((try library.findLightMap("KIEV_1")).? != kiev);
    try std.testing.expectEqual(null, try library.findLightMap("lKiev_1"));
    try std.testing.expectEqual(srd3d.highlight_size, library.highlight(3).levels[0].width);
}
