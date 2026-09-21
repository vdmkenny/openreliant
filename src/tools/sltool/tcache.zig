//! `sltool tcache ...`: read the texture caches and save their textures as PNG.

const std = @import("std");
const Io = std.Io;

const starlancer = @import("starlancer");
const png = starlancer.png;
const tcache = starlancer.tcache;
const tga = starlancer.tga;

const Context = @import("main.zig").Context;

pub const Command = union(enum) {
    info: struct { cache: []const u8 },
    ls: struct { cache: []const u8 },
    /// Writes the full-size level of each texture, or of the named ones, as RGBA.
    extract: struct {
        cache: []const u8,
        palette: []const u8,
        out_dir: []const u8,
        names: []const [:0]const u8,
    },

    pub const usage =
        \\  tcache info <cache>             summarise a texture cache (tcachehw.dat, tcachesw.dat)
        \\  tcache ls <cache>               list its textures
        \\  tcache extract <cache> <palette.tga> <out-dir> [name...]
        \\                                  save textures as PNG, indices looked up in the palette
        \\
    ;

    pub fn parse(args: []const [:0]const u8) error{Usage}!Command {
        if (args.len == 0) return error.Usage;
        const verb = std.meta.stringToEnum(std.meta.Tag(Command), args[0]) orelse return error.Usage;
        const operands = args[1..];
        switch (verb) {
            .info => return if (operands.len == 1) .{ .info = .{ .cache = operands[0] } } else error.Usage,
            .ls => return if (operands.len == 1) .{ .ls = .{ .cache = operands[0] } } else error.Usage,
            .extract => return if (operands.len >= 3) .{ .extract = .{
                .cache = operands[0],
                .palette = operands[1],
                .out_dir = operands[2],
                .names = operands[3..],
            } } else error.Usage,
        }
    }

    pub fn run(command: Command, ctx: Context) !void {
        const path = switch (command) {
            inline else => |operands| operands.cache,
        };
        const data = try Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.arena, .limited(256 << 20));
        const cache: tcache.Cache = try .parse(ctx.arena, data);

        switch (command) {
            .info => try info(ctx, cache),
            .ls => try list(ctx, cache),
            .extract => |operands| try extract(ctx, cache, operands.palette, operands.out_dir, operands.names),
        }
    }
};

fn info(ctx: Context, cache: tcache.Cache) !void {
    var by_encoding: std.EnumArray(tcache.Encoding, usize) = .initFill(0);
    var mipmapped: usize = 0;
    for (cache.textures) |texture| {
        by_encoding.getPtr(texture.encoding).* += 1;
        if (texture.levels > 1) mipmapped += 1;
    }
    try ctx.stdout.print(
        \\version:        {d}
        \\entries:        {d} of {d}
        \\  loadable:     {d}
        \\  mipmapped:    {d}
        \\pixels end at:  {d}
        \\
    , .{
        cache.header.version,
        cache.entries.len,
        tcache.capacity,
        cache.textures.len,
        mipmapped,
        cache.header.end,
    });
    for (by_encoding.values, 0..) |count, i| {
        const encoding: tcache.Encoding = @enumFromInt(i);
        try ctx.stdout.print("  {s:<14}{d}\n", .{ @tagName(encoding), count });
    }
}

fn list(ctx: Context, cache: tcache.Cache) !void {
    try ctx.stdout.writeAll("index  name                              size      levels  encoding       offset\n");
    for (cache.textures) |texture| {
        const size = try std.fmt.allocPrint(ctx.arena, "{d}x{d}", .{ texture.width, texture.height });
        try ctx.stdout.print("{d:>5}  {s:<32}  {s:<9}  {d:>5}  {s:<13}  {x:0>8}\n", .{
            texture.entry.image.index,
            texture.name(),
            size,
            texture.levels,
            @tagName(texture.encoding),
            texture.entry.image.source,
        });
    }
}

fn extract(
    ctx: Context,
    cache: tcache.Cache,
    palette_path: []const u8,
    out_path: []const u8,
    names: []const [:0]const u8,
) !void {
    const io = ctx.io;
    const palette_file = try Io.Dir.cwd().readFileAlloc(io, palette_path, ctx.arena, .limited(16 << 20));
    const palette = try tga.palette(palette_file);

    var chosen: std.ArrayList(tcache.Texture) = .empty;
    if (names.len == 0) {
        try chosen.appendSlice(ctx.arena, cache.textures);
    } else for (names) |name| {
        const texture = cache.find(name) orelse {
            std.debug.print("no texture named {s}\n", .{name});
            return error.TextureNotFound;
        };
        try chosen.append(ctx.arena, texture);
    }

    try Io.Dir.cwd().createDirPath(io, out_path);
    var out_dir = try Io.Dir.cwd().openDir(io, out_path, .{});
    defer out_dir.close(io);

    for (chosen.items) |texture| {
        // Every loadable texture has a level 0.
        const level = texture.level(0) orelse continue;
        const pixels = try level.rgba(ctx.arena, &palette);
        defer ctx.arena.free(pixels);

        const file_name = try std.fmt.allocPrint(ctx.arena, "{s}.png", .{texture.name()});
        const file = try out_dir.createFile(io, file_name, .{});
        defer file.close(io);
        var buffer: [32 * 1024]u8 = undefined;
        var writer = file.writer(io, &buffer);
        try png.writeRgba(ctx.arena, &writer.interface, level.width, level.height, pixels);
        try writer.interface.flush();
    }
    try ctx.stdout.print("wrote {d} textures to {s}\n", .{ chosen.items.len, out_path });
}

test Command {
    const extract_all = try Command.parse(&.{ "extract", "tcachehw.dat", "palette.tga", "out" });
    try std.testing.expectEqualStrings("palette.tga", extract_all.extract.palette);
    try std.testing.expectEqual(0, extract_all.extract.names.len);
    const extract_some = try Command.parse(&.{ "extract", "tcachehw.dat", "palette3.tga", "out", "gyank_1", "plate-nw" });
    try std.testing.expectEqual(2, extract_some.extract.names.len);
    try std.testing.expectEqualStrings("tcachehw.dat", (try Command.parse(&.{ "ls", "tcachehw.dat" })).ls.cache);
    try std.testing.expectError(error.Usage, Command.parse(&.{ "extract", "tcachehw.dat", "palette.tga" }));
    try std.testing.expectError(error.Usage, Command.parse(&.{ "show", "tcachehw.dat" }));
}

test "extracts a texture" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cache_bytes = try tcache.testing.build(arena, &.{.{ .name = "Kiev_1", .encoding = .index8, .width = 2, .height = 2 }});
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "tcachehw.dat", .data = cache_bytes });

    // A colour-mapped TGA with a 256-entry map and no image to speak of.
    var palette_file: [tga.header_size + 256 * 3 + 1]u8 = @splat(0);
    palette_file[1] = 1;
    palette_file[2] = 1;
    palette_file[6] = 1; // 256 entries
    palette_file[7] = 24;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "palette.tga", .data = &palette_file });

    const base = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var out: Io.Writer.Allocating = .init(arena);
    const ctx: Context = .{ .io = std.testing.io, .arena = arena, .stdout = &out.writer };
    const command: Command = .{ .extract = .{
        .cache = try std.fmt.allocPrint(arena, "{s}/tcachehw.dat", .{base}),
        .palette = try std.fmt.allocPrint(arena, "{s}/palette.tga", .{base}),
        .out_dir = try std.fmt.allocPrint(arena, "{s}/out", .{base}),
        .names = &.{"KIEV_1"},
    } };
    try command.run(ctx);

    const written = try tmp.dir.readFileAlloc(std.testing.io, "out/Kiev_1.png", arena, .limited(1 << 20));
    try std.testing.expectEqualSlices(u8, png.signature, written[0..8]);
}
