//! `sltool hog ...`: read the game's `.HOG` asset archives.

const std = @import("std");
const Io = std.Io;

const openreliant = @import("openreliant");
const hog = openreliant.hog;
const refpack = openreliant.refpack;

const Context = @import("main.zig").Context;

pub const Command = union(enum) {
    info: struct { archive: []const u8 },
    ls: struct { archive: []const u8 },
    /// Extracts every member, decompressing unless `--raw`.
    extract: struct { archive: []const u8, out_dir: []const u8, raw: bool = false },

    pub const usage =
        \\  hog info <archive>              describe a .HOG archive
        \\  hog ls <archive>                list its members
        \\  hog extract <archive> <out-dir> [--raw]
        \\                                  extract every member, decompressing by default
        \\
    ;

    pub fn parse(args: []const [:0]const u8) error{Usage}!Command {
        if (args.len == 0) return error.Usage;
        const verb = std.meta.stringToEnum(std.meta.Tag(Command), args[0]) orelse return error.Usage;
        const operands = args[1..];
        switch (verb) {
            .info => return if (operands.len == 1) .{ .info = .{ .archive = operands[0] } } else error.Usage,
            .ls => return if (operands.len == 1) .{ .ls = .{ .archive = operands[0] } } else error.Usage,
            .extract => {
                if (operands.len != 2 and operands.len != 3) return error.Usage;
                var command: Command = .{ .extract = .{ .archive = operands[0], .out_dir = operands[1] } };
                if (operands.len == 3) {
                    if (!std.mem.eql(u8, operands[2], "--raw")) return error.Usage;
                    command.extract.raw = true;
                }
                return command;
            },
        }
    }

    pub fn run(command: Command, ctx: Context) !void {
        const path = switch (command) {
            inline else => |operands| operands.archive,
        };
        var archive = try hog.Archive.open(ctx.arena, ctx.io, .cwd(), path);
        defer archive.close(ctx.arena);

        switch (command) {
            .info => try info(ctx, archive),
            .ls => try list(ctx, archive),
            .extract => |operands| try extract(ctx, archive, operands.out_dir, operands.raw),
        }
    }
};

fn info(ctx: Context, archive: hog.Archive) !void {
    var compressed: usize = 0;
    var stored_total: u64 = 0;
    var real_total: u64 = 0;

    for (archive.entries) |entry| {
        stored_total += entry.size;
        var head: [8]u8 = undefined;
        const n = try archive.file.readPositionalAll(archive.io, &head, entry.offset);
        if (n >= 5 and refpack.looksCompressed(head[0..n])) {
            compressed += 1;
            real_total += (refpack.readHeader(head[0..n]) catch {
                real_total += entry.size;
                continue;
            }).decompressed_size;
        } else {
            real_total += entry.size;
        }
    }

    try ctx.stdout.print(
        \\archive size: {Bi:.1}
        \\members:      {d}
        \\directory:    {d} bytes, members start at {x:0>6}
        \\contiguous:   {}
        \\compressed:   {d} of {d} members (RefPack)
        \\stored:       {Bi:.1}
        \\uncompressed: {Bi:.1}
        \\
    , .{
        archive.header.archiveSize(),
        archive.entries.len,
        archive.header.dataOffset() - @sizeOf(hog.Header),
        archive.header.dataOffset(),
        archive.isContiguous(),
        compressed,
        archive.entries.len,
        stored_total,
        real_total,
    });

    if (archive.phantom_entries > 0) {
        try ctx.stdout.print(
            "\nthe header counts {d} more entr{s}, which the directory does not hold: trailing\n" ++
                "filler left by the packer, past the last real member\n",
            .{ archive.phantom_entries, if (archive.phantom_entries == 1) "y" else "ies" },
        );
    }
}

fn list(ctx: Context, archive: hog.Archive) !void {
    for (archive.entries) |entry| {
        var head: [8]u8 = undefined;
        const n = try archive.file.readPositionalAll(archive.io, &head, entry.offset);
        const header: ?refpack.Header = if (n >= 5 and refpack.looksCompressed(head[0..n]))
            refpack.readHeader(head[0..n]) catch null
        else
            null;

        if (header) |h| {
            try ctx.stdout.print("{x:0>8}  {d:>9} {d:>10}  {s}\n", .{ entry.offset, entry.size, h.decompressed_size, entry.name });
        } else {
            try ctx.stdout.print("{x:0>8}  {d:>9} {s:>10}  {s}\n", .{ entry.offset, entry.size, "-", entry.name });
        }
    }
}

fn extract(ctx: Context, archive: hog.Archive, out_path: []const u8, raw: bool) !void {
    const io = ctx.io;
    try Io.Dir.cwd().createDirPath(io, out_path);
    var out_dir = try Io.Dir.cwd().openDir(io, out_path, .{});
    defer out_dir.close(io);

    // Member names are not unique, and several duplicates hold different data, so a later member
    // must not overwrite an earlier one. Names are tracked case-insensitively because a
    // case-insensitive filesystem would collide `interpal.TGA` with `interpal.tga` as well.
    var taken: std.StringHashMapUnmanaged(void) = .empty;
    defer taken.deinit(ctx.arena);

    var written: u64 = 0;
    var renamed: usize = 0;
    for (archive.entries) |entry| {
        const bytes = if (raw)
            try archive.readRaw(ctx.arena, entry)
        else
            (try archive.read(ctx.arena, entry)).bytes;
        defer ctx.arena.free(bytes);

        var name = entry.name;
        var attempt: usize = 2;
        while (try taken.fetchPut(ctx.arena, try lowered(ctx.arena, name), {}) != null) : (attempt += 1) {
            name = try disambiguate(ctx.arena, entry.name, attempt);
            if (attempt == 2) renamed += 1;
        }

        try out_dir.writeFile(io, .{ .sub_path = name, .data = bytes });
        written += bytes.len;
    }

    try ctx.stdout.print("extracted {d} members ({Bi:.1}{s}) to {s}\n", .{
        archive.entries.len,
        written,
        if (raw) ", as stored" else ", decompressed",
        out_path,
    });
    if (renamed > 0) {
        try ctx.stdout.print(
            "{d} member{s} shared a name with an earlier one and got a ~N suffix\n",
            .{ renamed, if (renamed == 1) "" else "s" },
        );
    }
}

fn lowered(gpa: std.mem.Allocator, name: []const u8) ![]const u8 {
    const copy = try gpa.dupe(u8, name);
    return std.ascii.lowerString(copy, name);
}

/// `dest.SHP` becomes `dest~2.SHP`, keeping the extension so the file still opens as its type.
fn disambiguate(gpa: std.mem.Allocator, name: []const u8, index: usize) ![]const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse name.len;
    return std.fmt.allocPrint(gpa, "{s}~{d}{s}", .{ name[0..dot], index, name[dot..] });
}

test Command {
    const parsed = try Command.parse(&.{ "extract", "LANCER.HOG", "out", "--raw" });
    try std.testing.expect(parsed.extract.raw);
    try std.testing.expectEqualStrings("out", parsed.extract.out_dir);
    try std.testing.expect(!(try Command.parse(&.{ "extract", "LANCER.HOG", "out" })).extract.raw);
    try std.testing.expectEqualStrings("A.HOG", (try Command.parse(&.{ "info", "A.HOG" })).info.archive);

    try std.testing.expectError(error.Usage, Command.parse(&.{ "extract", "LANCER.HOG", "out", "--fast" }));
    try std.testing.expectError(error.Usage, Command.parse(&.{"ls"}));
    try std.testing.expectError(error.Usage, Command.parse(&.{}));
}

test disambiguate {
    const gpa = std.testing.allocator;
    const renamed = try disambiguate(gpa, "dest.SHP", 2);
    defer gpa.free(renamed);
    try std.testing.expectEqualStrings("dest~2.SHP", renamed);

    const bare = try disambiguate(gpa, "README", 3);
    defer gpa.free(bare);
    try std.testing.expectEqualStrings("README~3", bare);
}

test lowered {
    const gpa = std.testing.allocator;
    const name = try lowered(gpa, "Dest.SHP");
    defer gpa.free(name);
    try std.testing.expectEqualStrings("dest.shp", name);
}
