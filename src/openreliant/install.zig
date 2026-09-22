//! `openreliant install`: puts StarLancer's files where the engine reads them, from your own discs,
//! as the game's installer did. It unpacks `LANCER.CAB` from disc 1 and copies the files in the
//! disc's `GAME/CAB` folder next to them.
//!
//! The disc can be a disc image, raw (`.bin`) or not (`.iso`), or a folder with the disc's files,
//! which is how every system shows a disc in a drive. Without one named, the installer looks for
//! disc 1 in the CD drives: on Windows the drives it reports as CD drives, on Linux the mounted ISO
//! 9660 and UDF file systems, and on macOS the mounted volumes. Disc images are read with the
//! project's own readers, and the cabinet is unpacked with libarchive.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const openreliant = @import("openreliant");
const cdimage = openreliant.cdimage;
const iso9660 = openreliant.iso9660;
const game = openreliant.engine.game;
const c = @import("archive");

pub const usage =
    \\usage: openreliant install [--from <disc>] [--force] <directory>
    \\  <directory>      where to put the game's files; made if it doesn't exist
    \\  --from <disc>    StarLancer disc 1, as a disc image (.bin or .iso) or a folder with the
    \\                   disc's files; without it, the CD drives are searched for the disc
    \\  --force          install from a disc 1 that OpenReliant doesn't know, such as another
    \\                   country's release
    \\
;

pub const Options = struct {
    directory: []const u8,
    from: ?[]const u8 = null,
    force: bool = false,

    pub fn parse(args: []const [:0]const u8) error{Usage}!Options {
        var directory: ?[]const u8 = null;
        var from: ?[]const u8 = null;
        var force = false;
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--force")) {
                force = true;
            } else if (std.mem.eql(u8, arg, "--from")) {
                i += 1;
                if (i == args.len) return error.Usage;
                from = args[i];
            } else if (std.mem.startsWith(u8, arg, "-") or directory != null) {
                return error.Usage;
            } else {
                directory = arg;
            }
        }
        return .{ .directory = directory orelse return error.Usage, .from = from, .force = force };
    }
};

/// The game's files the engine reads before anything else. It has none of its own.
pub const game_files = [_][]const u8{ game.bigfile.resource_name, "tcachehw.dat", "shipstats.bin", game.language.file_name };

/// The first of the game's files `dir` lacks, or null when it has them all.
pub fn missingGameFile(io: Io, dir: Io.Dir) ?[]const u8 {
    for (game_files) |name| dir.access(io, name, .{}) catch return name;
    return null;
}

/// A release whose disc 1 the installer knows.
const Release = struct {
    name: []const u8,
    /// The size of the disc's cabinet, which tells the releases apart.
    cabinet_size: u64,
};

const releases = [_]Release{
    .{ .name = "the North American release", .cabinet_size = 226_746_308 },
};

/// Where to report a release the installer doesn't know.
const issues_url = "https://github.com/vdmkenny/openreliant/issues";

/// The installer's cabinet on disc 1, and the folder whose files it copies next to the cabinet's.
const cabinet_path = "LANCER.CAB";
const extras_path = "GAME/CAB";
/// Disc 2 is told apart by its label, or by the archive only it has.
const second_label = "SL_CD2";
const second_path = "GAME/CD2.HOG";

/// What a disc turned out to be.
const Identity = union(enum) {
    /// Disc 1 of a release the installer knows, and its cabinet.
    known: struct { release: *const Release, cabinet: Entry },
    /// A disc with the installer's cabinet, of no release the installer knows.
    unrecognized: Entry,
    /// Disc 2, which has nothing to install.
    second,
    /// Not a StarLancer disc.
    other,
};

/// A file on a disc.
const Entry = struct {
    name: []const u8,
    size: u64,
    place: union(enum) {
        image: struct { image: cdimage.Image, lba: u32 },
        /// Its path in the folder, spelled as the folder spells it.
        folder: struct { dir: Io.Dir, path: []const u8 },
    },
};

/// A disc, read from an image or from a folder with its files. Names on it are matched without
/// regard to case, as Windows matches them.
const Disc = union(enum) {
    image: struct { image: cdimage.Image, volume: iso9660.Volume },
    folder: Io.Dir,

    /// The folder or disc image at `path`.
    fn open(io: Io, dir: Io.Dir, path: []const u8) !Disc {
        if (dir.openDir(io, path, .{ .iterate = true })) |folder| {
            return .{ .folder = folder };
        } else |err| switch (err) {
            error.NotDir => {},
            else => |e| return e,
        }
        const image: cdimage.Image = try .open(io, dir, path);
        errdefer image.close();
        return .{ .image = .{ .image = image, .volume = try .open(image) } };
    }

    fn close(disc: Disc, io: Io) void {
        switch (disc) {
            .image => |image| image.image.close(),
            .folder => |folder| folder.close(io),
        }
    }

    /// The volume label. A folder's is not known.
    fn label(disc: Disc, arena: Allocator) !?[]const u8 {
        return switch (disc) {
            .image => |image| try image.volume.label(arena),
            .folder => null,
        };
    }

    /// The file at `path`, `/`-separated, or null if there's none.
    fn find(disc: Disc, io: Io, arena: Allocator, path: []const u8) !?Entry {
        const name = std.fs.path.basenamePosix(path);
        const files = try disc.list(io, arena, std.fs.path.dirnamePosix(path) orelse "") orelse return null;
        for (files) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.name, name)) return entry;
        }
        return null;
    }

    /// The files in the folder at `path`, `/`-separated and `""` for the top, or null if there's no
    /// such folder.
    fn list(disc: Disc, io: Io, arena: Allocator, path: []const u8) !?[]const Entry {
        var parts = std.mem.tokenizeScalar(u8, path, '/');
        var files: std.ArrayList(Entry) = .empty;
        switch (disc) {
            .image => |image| {
                var extent = image.volume.root();
                while (parts.next()) |part| {
                    extent = for (try image.volume.readDirectory(arena, extent)) |entry| {
                        if (entry.kind == .directory and std.ascii.eqlIgnoreCase(entry.name, part)) break entry.extent;
                    } else return null;
                }
                for (try image.volume.readDirectory(arena, extent)) |entry| {
                    if (entry.kind != .file) continue;
                    try files.append(arena, .{
                        .name = entry.name,
                        .size = entry.extent.len,
                        .place = .{ .image = .{ .image = image.image, .lba = entry.extent.lba } },
                    });
                }
            },
            .folder => |root| {
                var spelled: []const u8 = "";
                while (parts.next()) |part| {
                    const entries = folderEntries(io, arena, root, spelled) catch |err| switch (err) {
                        error.FileNotFound, error.NotDir => return null,
                        else => |e| return e,
                    };
                    const found = for (entries) |entry| {
                        if (entry.kind == .directory and std.ascii.eqlIgnoreCase(entry.name, part)) break entry.name;
                    } else return null;
                    spelled = try joinPath(arena, spelled, found);
                }
                for (try folderEntries(io, arena, root, spelled)) |entry| {
                    if (entry.kind != .file) continue;
                    try files.append(arena, .{
                        .name = entry.name,
                        .size = entry.size,
                        .place = .{ .folder = .{ .dir = root, .path = try joinPath(arena, spelled, entry.name) } },
                    });
                }
            },
        }
        return files.items;
    }

    fn identify(disc: Disc, io: Io, arena: Allocator, known: []const Release) !Identity {
        if (try disc.find(io, arena, cabinet_path)) |cabinet| {
            for (known) |*release| {
                if (release.cabinet_size == cabinet.size) return .{ .known = .{ .release = release, .cabinet = cabinet } };
            }
            return .{ .unrecognized = cabinet };
        }
        if (try disc.label(arena)) |name| {
            if (std.ascii.eqlIgnoreCase(name, second_label)) return .second;
        }
        if (try disc.find(io, arena, second_path) != null) return .second;
        return .other;
    }
};

const FolderEntry = struct { name: []const u8, kind: Io.File.Kind, size: u64 };

/// The entries of the folder at `path` in `root`. Their kinds come from the file system when the
/// listing doesn't give them, as Linux's disc file systems don't.
fn folderEntries(io: Io, arena: Allocator, root: Io.Dir, path: []const u8) ![]const FolderEntry {
    var dir = try root.openDir(io, if (path.len == 0) "." else path, .{ .iterate = true });
    defer dir.close(io);
    var entries: std.ArrayList(FolderEntry) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        var found: FolderEntry = .{ .name = try arena.dupe(u8, entry.name), .kind = entry.kind, .size = 0 };
        if (entry.kind != .directory) {
            const stat = dir.statFile(io, found.name, .{}) catch continue;
            found.kind = stat.kind;
            found.size = stat.size;
        }
        try entries.append(arena, found);
    }
    return entries.items;
}

fn joinPath(arena: Allocator, folder: []const u8, name: []const u8) ![]const u8 {
    if (folder.len == 0) return name;
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ folder, name });
}

/// Reads a file on a disc from the start, and skips ahead.
const Reader = struct {
    size: u64,
    position: u64 = 0,
    source: union(enum) {
        image: struct { image: cdimage.Image, lba: u32, blocks: []u8 },
        file: Io.File,
    },

    fn open(io: Io, arena: Allocator, entry: Entry) !Reader {
        return .{ .size = entry.size, .source = switch (entry.place) {
            .image => |place| .{ .image = .{
                .image = place.image,
                .lba = place.lba,
                .blocks = try arena.alloc(u8, 32 * cdimage.block_size),
            } },
            .folder => |place| .{ .file = try place.dir.openFile(io, place.path, .{}) },
        } };
    }

    fn close(reader: Reader, io: Io) void {
        switch (reader.source) {
            .image => {},
            .file => |file| file.close(io),
        }
    }

    /// Fills as much of `out` as there is file left for, and returns how much: 0 at the end.
    fn read(reader: *Reader, io: Io, out: []u8) !usize {
        var n: usize = @intCast(@min(out.len, reader.size - reader.position));
        if (n == 0) return 0;
        switch (reader.source) {
            .image => |source| {
                const block_size = cdimage.block_size;
                const within: usize = @intCast(reader.position % block_size);
                n = @min(n, source.blocks.len - within);
                const count = (within + n + block_size - 1) / block_size;
                const lba = std.math.cast(u32, source.lba + reader.position / block_size) orelse return error.EndOfImage;
                try source.image.readBlocks(lba, source.blocks[0 .. count * block_size]);
                @memcpy(out[0..n], source.blocks[within..][0..n]);
            },
            .file => |file| {
                n = try file.readPositionalAll(io, out[0..n], reader.position);
                // The file is shorter than it was.
                if (n == 0) return error.EndOfStream;
            },
        }
        reader.position += n;
        return n;
    }

    /// Moves `n` bytes on, or to the end, and returns how far it moved.
    fn skip(reader: *Reader, n: u64) u64 {
        const moved = @min(n, reader.size - reader.position);
        reader.position += moved;
        return moved;
    }
};

/// Feeds libarchive a file on a disc.
const Feed = struct {
    io: Io,
    reader: *Reader,
    buffer: [64 * 1024]u8 = undefined,
    /// Why the disc could not be read, when it couldn't.
    failure: ?anyerror = null,

    fn read(archive: ?*c.struct_archive, context: ?*anyopaque, out: [*c]?*const anyopaque) callconv(.c) c.la_ssize_t {
        const feed: *Feed = @ptrCast(@alignCast(context));
        const n = feed.reader.read(feed.io, &feed.buffer) catch |err| {
            feed.failure = err;
            // -1: an error of libarchive's own rather than the system's.
            c.archive_set_error(archive, -1, "the disc could not be read");
            return c.ARCHIVE_FATAL;
        };
        out.* = &feed.buffer;
        return @intCast(n);
    }

    fn skip(_: ?*c.struct_archive, context: ?*anyopaque, request: c.la_int64_t) callconv(.c) c.la_int64_t {
        const feed: *Feed = @ptrCast(@alignCast(context));
        return @intCast(feed.reader.skip(@intCast(@max(request, 0))));
    }
};

/// Where a file of the cabinet goes in the install: its path without the cabinet's top folder
/// `CAB`, whose contents the installer put straight into the game's folder. A name that would
/// reach outside the install, or name a drive, is refused.
fn installPath(arena: Allocator, name: []const u8) error{ UnsafeName, OutOfMemory }![]const u8 {
    if (name.len == 0 or name[0] == '/' or name[0] == '\\') return error.UnsafeName;
    var parts: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, name, "/\\");
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..") or std.mem.indexOfScalar(u8, part, ':') != null) {
            return error.UnsafeName;
        }
        try parts.append(arena, part);
    }
    const kept = if (parts.items.len > 1 and std.ascii.eqlIgnoreCase(parts.items[0], "CAB")) parts.items[1..] else parts.items;
    if (kept.len == 0) return error.UnsafeName;
    return std.mem.join(arena, "/", kept);
}

/// Where the system shows the discs in its drives, and the disc images it has mounted.
fn mountedDiscs(io: Io, arena: Allocator) ![]const []const u8 {
    switch (builtin.os.tag) {
        .windows => return cdDrives(arena),
        .linux => {
            const table = Io.Dir.cwd().readFileAlloc(io, "/proc/self/mounts", arena, .limited(1 << 20)) catch return &.{};
            return discMounts(arena, table);
        },
        .macos => {
            var dir = Io.Dir.cwd().openDir(io, "/Volumes", .{ .iterate = true }) catch return &.{};
            defer dir.close(io);
            var volumes: std.ArrayList([]const u8) = .empty;
            var it = dir.iterate();
            while (it.next(io) catch null) |entry| {
                try volumes.append(arena, try std.fs.path.join(arena, &.{ "/Volumes", entry.name }));
            }
            return volumes.items;
        },
        else => return &.{},
    }
}

/// The drives Windows reports as CD drives, disc image drives among them, that have a disc in them.
fn cdDrives(arena: Allocator) ![]const []const u8 {
    const windows = std.os.windows;
    const kernel32 = struct {
        extern "kernel32" fn GetLogicalDrives() callconv(.winapi) u32;
        extern "kernel32" fn GetDriveTypeW(root: [*:0]const u16) callconv(.winapi) u32;
        extern "kernel32" fn GetVolumeInformationW(
            root: [*:0]const u16,
            name: ?[*]u16,
            name_size: u32,
            serial: ?*u32,
            component_length: ?*u32,
            flags: ?*u32,
            file_system: ?[*]u16,
            file_system_size: u32,
        ) callconv(.winapi) windows.BOOL;
        extern "kernel32" fn SetThreadErrorMode(mode: u32, old: ?*u32) callconv(.winapi) windows.BOOL;
    };
    const drive_cdrom = 5;
    // So that an empty drive is reported as one rather than with a dialog asking for a disc.
    const fail_critical_errors = 0x0001;
    var mode: u32 = 0;
    _ = kernel32.SetThreadErrorMode(fail_critical_errors, &mode);
    defer _ = kernel32.SetThreadErrorMode(mode, null);

    var drives: std.ArrayList([]const u8) = .empty;
    const present = kernel32.GetLogicalDrives();
    for (0..26) |i| {
        if (present & (@as(u32, 1) << @intCast(i)) == 0) continue;
        const letter: u8 = @intCast('A' + i);
        const root = [_:0]u16{ letter, ':', '\\' };
        if (kernel32.GetDriveTypeW(&root) != drive_cdrom) continue;
        // Fails when the drive is empty.
        if (!kernel32.GetVolumeInformationW(&root, null, 0, null, null, null, null, 0).toBool()) continue;
        try drives.append(arena, try std.fmt.allocPrint(arena, "{c}:\\", .{letter}));
    }
    return drives.items;
}

/// The mount points of the disc file systems, ISO 9660 and UDF, in a table of mounts as Linux
/// keeps it in `/proc/self/mounts`: a line a mount, fields separated by spaces, and a space, tab,
/// newline or backslash in a field written as a backslash and three octal digits.
fn discMounts(arena: Allocator, table: []const u8) ![]const []const u8 {
    var points: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.tokenizeScalar(u8, table, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        _ = fields.next();
        const point = fields.next() orelse continue;
        const system = fields.next() orelse continue;
        if (!std.mem.eql(u8, system, "iso9660") and !std.mem.eql(u8, system, "udf")) continue;

        const unescaped = try arena.alloc(u8, point.len);
        var n: usize = 0;
        var i: usize = 0;
        while (i < point.len) : (n += 1) {
            if (point[i] == '\\' and point.len - i >= 4) {
                if (std.fmt.parseInt(u8, point[i + 1 ..][0..3], 8)) |byte| {
                    unescaped[n] = byte;
                    i += 4;
                    continue;
                } else |_| {}
            }
            unescaped[n] = point[i];
            i += 1;
        }
        try points.append(arena, unescaped[0..n]);
    }
    return points.items;
}

const Found = struct { disc: Disc, path: []const u8, identity: Identity };

const Search = struct {
    found: ?Found,
    /// Where disc 2 turned up, for when disc 1 didn't.
    second: ?[]const u8,
};

/// Looks through `paths` for disc 1: the first of a release the installer knows, or else the first
/// with the installer's cabinet. Paths that aren't discs, or can't be read, are passed over.
fn search(io: Io, arena: Allocator, dir: Io.Dir, paths: []const []const u8, known: []const Release) Search {
    var result: Search = .{ .found = null, .second = null };
    for (paths) |path| {
        const disc = Disc.open(io, dir, path) catch continue;
        const identity = disc.identify(io, arena, known) catch {
            disc.close(io);
            continue;
        };
        switch (identity) {
            .known => {
                if (result.found) |other| other.disc.close(io);
                result.found = .{ .disc = disc, .path = path, .identity = identity };
                return result;
            },
            .unrecognized => if (result.found == null) {
                result.found = .{ .disc = disc, .path = path, .identity = identity };
                continue;
            },
            .second => if (result.second == null) {
                result.second = path;
            },
            .other => {},
        }
        disc.close(io);
    }
    return result;
}

/// What an install works with besides its options, which the tests replace.
const Environment = struct {
    /// Where relative paths lead from.
    dir: Io.Dir,
    /// Where to look for disc 1 when none is named.
    mounted: []const []const u8,
    known: []const Release = &releases,
    out: *Io.Writer,
    err: *Io.Writer,
};

/// `openreliant install`, given its arguments. Returns the exit code.
pub fn main(io: Io, arena: Allocator, args: []const [:0]const u8) !u8 {
    var out_buffer: [4096]u8 = undefined;
    var out: Io.File.Writer = .initStreaming(.stdout(), io, &out_buffer);
    var err_buffer: [1024]u8 = undefined;
    var err: Io.File.Writer = .initStreaming(.stderr(), io, &err_buffer);
    defer {
        out.interface.flush() catch {};
        err.interface.flush() catch {};
    }
    const options = Options.parse(args) catch {
        try err.interface.writeAll(usage);
        return 2;
    };
    return run(io, arena, options, .{
        .dir = .cwd(),
        .mounted = if (options.from == null) try mountedDiscs(io, arena) else &.{},
        .out = &out.interface,
        .err = &err.interface,
    });
}

fn run(io: Io, arena: Allocator, options: Options, env: Environment) !u8 {
    const found: Found = if (options.from) |path| found: {
        const disc = Disc.open(io, env.dir, path) catch |err| switch (err) {
            error.FileNotFound => {
                try env.err.print("openreliant: there's no {s}.\n", .{path});
                return 1;
            },
            error.NotADiscImage, error.NotIso9660, error.UnsupportedBlockSize => {
                if (std.ascii.endsWithIgnoreCase(path, ".cue")) {
                    try env.err.print("openreliant: {s} only describes the disc. Name its .bin instead.\n", .{path});
                } else {
                    try env.err.print("openreliant: {s} is neither a folder nor a disc image.\n", .{path});
                }
                return 1;
            },
            else => |e| return e,
        };
        errdefer disc.close(io);
        break :found .{ .disc = disc, .path = path, .identity = try disc.identify(io, arena, env.known) };
    } else found: {
        try env.out.writeAll("Looking for StarLancer disc 1 in the CD drives.\n");
        try env.out.flush();
        const result = search(io, arena, env.dir, env.mounted, env.known);
        break :found result.found orelse {
            if (result.second) |path| {
                try env.err.print("openreliant: {s} is StarLancer disc 2. Installing needs disc 1.\n", .{path});
            } else {
                try env.err.writeAll(
                    \\openreliant: StarLancer disc 1 isn't in any CD drive. Insert it, or name the disc
                    \\or an image of it with --from.
                    \\
                );
            }
            return 1;
        };
    };
    defer found.disc.close(io);

    const cabinet = switch (found.identity) {
        .known => |known| cabinet: {
            try env.out.print("Installing StarLancer from {s}, disc 1 of {s}.\n", .{ found.path, known.release.name });
            break :cabinet known.cabinet;
        },
        .unrecognized => |cabinet| cabinet: {
            if (!options.force) {
                try env.err.print(
                    \\openreliant: {s} has StarLancer's installer, but it's not a release OpenReliant
                    \\knows: its LANCER.CAB is {d} bytes. If it's from another country's release, install
                    \\from it with --force, and please report it at {s} so it can be added.
                    \\
                , .{ found.path, cabinet.size, issues_url });
                return 1;
            }
            try env.out.print("Installing StarLancer from {s}, a disc 1 OpenReliant doesn't know.\n", .{found.path});
            break :cabinet cabinet;
        },
        .second => {
            try env.err.print("openreliant: {s} is StarLancer disc 2. Installing needs disc 1.\n", .{found.path});
            return 1;
        },
        .other => {
            try env.err.print("openreliant: {s} isn't StarLancer disc 1: it has no {s}.\n", .{ found.path, cabinet_path });
            return 1;
        },
    };
    try env.out.flush();

    const target = open: {
        env.dir.createDirPath(io, options.directory) catch |err| break :open err;
        break :open env.dir.openDir(io, options.directory, .{});
    } catch |err| {
        try env.err.print("openreliant: {s} can't be made: {s}\n", .{ options.directory, @errorName(err) });
        return 1;
    };
    defer target.close(io);
    install(io, arena, found.disc, cabinet, target, env) catch |err| switch (err) {
        error.InstallFailed => return 1,
        else => {
            try env.err.print("openreliant: the install failed: {s}\n", .{@errorName(err)});
            return 1;
        },
    };
    if (missingGameFile(io, target)) |name| {
        try env.err.print("openreliant: the disc is unpacked, but it had no {s}.\n", .{name});
        return 1;
    }
    try env.out.print("StarLancer is installed in {s}. To play it: openreliant {s}\n", .{ options.directory, options.directory });
    try env.out.flush();
    return 0;
}

/// Unpacks the cabinet into `target`, and copies the disc's `GAME/CAB` files next to its files.
fn install(io: Io, arena: Allocator, disc: Disc, cabinet: Entry, target: Io.Dir, env: Environment) !void {
    try unpack(io, arena, cabinet, target, env);
    // Named in upper case, as the disc records them: Linux shows a disc's names in lower case.
    for (try disc.list(io, arena, extras_path) orelse &.{}) |entry| {
        const name = try std.ascii.allocUpperString(arena, entry.name);
        try copy(io, arena, entry, target, name);
        try env.out.print("  {s}\n", .{name});
        try env.out.flush();
    }
}

fn unpack(io: Io, arena: Allocator, cabinet: Entry, target: Io.Dir, env: Environment) !void {
    var reader: Reader = try .open(io, arena, cabinet);
    defer reader.close(io);
    var feed: Feed = .{ .io = io, .reader = &reader };
    const archive = c.archive_read_new() orelse return error.OutOfMemory;
    defer _ = c.archive_read_free(archive);
    _ = c.archive_read_support_format_cab(archive);
    if (c.archive_read_open2(archive, &feed, null, &Feed.read, &Feed.skip, null) != c.ARCHIVE_OK) {
        return failed(archive, &feed, env.err);
    }

    var data: [64 * 1024]u8 = undefined;
    while (true) {
        var entry: ?*c.struct_archive_entry = null;
        switch (c.archive_read_next_header(archive, &entry)) {
            c.ARCHIVE_OK, c.ARCHIVE_WARN => {},
            c.ARCHIVE_EOF => break,
            else => return failed(archive, &feed, env.err),
        }
        const name = entryName(entry) orelse {
            try env.err.writeAll("openreliant: the cabinet has a file whose name can't be read.\n");
            return error.InstallFailed;
        };
        const path = installPath(arena, name) catch |err| switch (err) {
            error.UnsafeName => {
                try env.err.print("openreliant: the cabinet has a file named {s}, outside the install.\n", .{name});
                return error.InstallFailed;
            },
            error.OutOfMemory => |e| return e,
        };
        // A cabinet holds only files, their folders named in their paths.
        if (std.fs.path.dirnamePosix(path)) |folder| try target.createDirPath(io, folder);
        const file = try target.createFile(io, path, .{});
        defer file.close(io);
        var buffer: [64 * 1024]u8 = undefined;
        var writer = file.writer(io, &buffer);
        while (true) {
            const n = c.archive_read_data(archive, &data, data.len);
            if (n == 0) break;
            if (n < 0) return failed(archive, &feed, env.err);
            try writer.interface.writeAll(data[0..@intCast(n)]);
        }
        try writer.interface.flush();
        try env.out.print("  {s}\n", .{path});
        try env.out.flush();
    }
}

/// An entry's path, in UTF-8 when libarchive can give it so.
fn entryName(entry: ?*c.struct_archive_entry) ?[]const u8 {
    const utf8 = c.archive_entry_pathname_utf8(entry);
    if (utf8 != null) return std.mem.span(utf8);
    const local = c.archive_entry_pathname(entry);
    if (local != null) return std.mem.span(local);
    return null;
}

/// Says why the cabinet couldn't be unpacked: the disc couldn't be read, or libarchive's reason.
fn failed(archive: *c.struct_archive, feed: *const Feed, err: *Io.Writer) error{ InstallFailed, WriteFailed } {
    if (feed.failure) |failure| {
        try err.print("openreliant: the disc can't be read: {s}\n", .{@errorName(failure)});
    } else {
        const reason = c.archive_error_string(archive);
        try err.print("openreliant: the cabinet can't be unpacked: {s}\n", .{if (reason != null) std.mem.span(reason) else "no reason given"});
    }
    return error.InstallFailed;
}

fn copy(io: Io, arena: Allocator, entry: Entry, target: Io.Dir, name: []const u8) !void {
    var reader: Reader = try .open(io, arena, entry);
    defer reader.close(io);
    const file = try target.createFile(io, name, .{});
    defer file.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var writer = file.writer(io, &buffer);
    var data: [64 * 1024]u8 = undefined;
    while (true) {
        const n = try reader.read(io, &data);
        if (n == 0) break;
        try writer.interface.writeAll(data[0..n]);
    }
    try writer.interface.flush();
}

const TestFile = struct { path: []const u8, data: []const u8 };

/// A cabinet of `files`, stored in one folder without compression or checksums, for the tests.
fn testCabinet(gpa: Allocator, files: []const TestFile) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var table_size: usize = 0;
    var data_size: usize = 0;
    for (files) |file| {
        table_size += 16 + file.path.len + 1;
        data_size += file.data.len;
    }
    const header_size = 36;
    const folder_size = 8;
    const data_offset = header_size + folder_size + table_size;
    const little = std.builtin.Endian.little;

    var header: [header_size]u8 = @splat(0);
    header[0..4].* = "MSCF".*;
    std.mem.writeInt(u32, header[8..12], @intCast(data_offset + 8 + data_size), little);
    std.mem.writeInt(u32, header[16..20], header_size + folder_size, little);
    header[24] = 3;
    header[25] = 1;
    std.mem.writeInt(u16, header[26..28], 1, little);
    std.mem.writeInt(u16, header[28..30], @intCast(files.len), little);
    try out.appendSlice(gpa, &header);

    var folder: [folder_size]u8 = @splat(0);
    std.mem.writeInt(u32, folder[0..4], @intCast(data_offset), little);
    std.mem.writeInt(u16, folder[4..6], 1, little);
    try out.appendSlice(gpa, &folder);

    var at: u32 = 0;
    for (files) |file| {
        var entry: [16]u8 = @splat(0);
        std.mem.writeInt(u32, entry[0..4], @intCast(file.data.len), little);
        std.mem.writeInt(u32, entry[4..8], at, little);
        std.mem.writeInt(u16, entry[10..12], 0x5421, little);
        std.mem.writeInt(u16, entry[14..16], 0x20, little);
        try out.appendSlice(gpa, &entry);
        try out.appendSlice(gpa, file.path);
        try out.append(gpa, 0);
        at += @intCast(file.data.len);
    }

    var block: [8]u8 = @splat(0);
    std.mem.writeInt(u16, block[4..6], @intCast(data_size), little);
    std.mem.writeInt(u16, block[6..8], @intCast(data_size), little);
    try out.appendSlice(gpa, &block);
    for (files) |file| try out.appendSlice(gpa, file.data);
    return out.toOwnedSlice(gpa);
}

/// A disc image of `files`, for the tests: an ISO 9660 volume labelled `label`, as bare blocks or
/// as raw sectors. Each folder takes one block, room enough for the tests' few files.
fn testImage(gpa: Allocator, label: []const u8, files: []const TestFile, layout: cdimage.Image.Layout) ![]u8 {
    const block_size = cdimage.block_size;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The folders, the top one first, then each folder a file is in, parents before children.
    var folders: std.ArrayList([]const u8) = .empty;
    try folders.append(arena, "");
    for (files) |file| {
        var start: usize = 0;
        while (std.mem.indexOfScalarPos(u8, file.path, start, '/')) |slash| : (start = slash + 1) {
            const folder = file.path[0..slash];
            for (folders.items) |known| {
                if (std.mem.eql(u8, known, folder)) break;
            } else try folders.append(arena, folder);
        }
    }
    const first_folder = iso9660.VolumeDescriptor.first_lba + 2;
    const places = try arena.alloc(u32, files.len);
    var next: u32 = @intCast(first_folder + folders.items.len);
    for (files, places) |file, *place| {
        place.* = next;
        next += @intCast((file.data.len + block_size - 1) / block_size);
    }
    const blocks = try arena.alloc([block_size]u8, next);
    @memset(blocks, @splat(0));

    const Record = iso9660.DirectoryRecord;
    const record = struct {
        fn write(block: *[block_size]u8, pos: *usize, identifier: []const u8, lba: usize, len: usize, directory: bool) void {
            var flags: iso9660.FileFlags = @bitCast(@as(u8, 0));
            flags.directory = directory;
            const size = std.mem.alignForward(usize, @sizeOf(Record) + identifier.len, 2);
            const fixed: *Record = @ptrCast(block[pos.*..][0..@sizeOf(Record)]);
            fixed.* = .{
                .length = @intCast(size),
                .extended_attribute_length = 0,
                .extent = .init(@intCast(lba)),
                .data_length = .init(@intCast(len)),
                .recorded_at = .{ .years_since_1900 = 100, .month = 3, .day = 31, .hour = 12, .minute = 0, .second = 0, .gmt_offset = 0 },
                .flags = flags,
                .file_unit_size = 0,
                .interleave_gap_size = 0,
                .volume_sequence_number = .init(1),
                .identifier_length = @intCast(identifier.len),
            };
            @memcpy(block[pos.* + @sizeOf(Record) ..][0..identifier.len], identifier);
            pos.* += size;
        }
    };

    const primary: *iso9660.VolumeDescriptor = @ptrCast(blocks[iso9660.VolumeDescriptor.first_lba][0..@sizeOf(iso9660.VolumeDescriptor)]);
    primary.type = .primary;
    primary.standard_identifier = iso9660.VolumeDescriptor.magic.*;
    primary.version = 1;
    @memset(&primary.volume_identifier, ' ');
    @memcpy(primary.volume_identifier[0..label.len], label);
    primary.logical_block_size = .init(block_size);
    var root: [block_size]u8 = @splat(0);
    var pos: usize = 0;
    record.write(&root, &pos, Record.self_identifier, first_folder, block_size, true);
    primary.root_directory = @as(*const Record, @ptrCast(root[0..@sizeOf(Record)])).*;
    const terminator = &blocks[iso9660.VolumeDescriptor.first_lba + 1];
    terminator[0] = @intFromEnum(iso9660.VolumeDescriptor.Type.set_terminator);
    terminator[1..6].* = iso9660.VolumeDescriptor.magic.*;

    for (folders.items, 0..) |folder, i| {
        const block = &blocks[first_folder + i];
        const parent = std.fs.path.dirnamePosix(folder) orelse "";
        const parent_index = for (folders.items, 0..) |known, j| {
            if (std.mem.eql(u8, known, parent)) break j;
        } else 0;
        pos = 0;
        record.write(block, &pos, Record.self_identifier, first_folder + i, block_size, true);
        record.write(block, &pos, Record.parent_identifier, first_folder + parent_index, block_size, true);
        for (folders.items[1..], 1..) |sub, j| {
            if (!std.mem.eql(u8, std.fs.path.dirnamePosix(sub) orelse "", folder)) continue;
            record.write(block, &pos, std.fs.path.basenamePosix(sub), first_folder + j, block_size, true);
        }
        for (files, places) |file, place| {
            if (!std.mem.eql(u8, std.fs.path.dirnamePosix(file.path) orelse "", folder)) continue;
            const identifier = try std.fmt.allocPrint(arena, "{s};1", .{std.fs.path.basenamePosix(file.path)});
            record.write(block, &pos, identifier, place, file.data.len, false);
        }
    }
    for (files, places) |file, place| @memcpy(std.mem.sliceAsBytes(blocks[place..])[0..file.data.len], file.data);

    switch (layout) {
        .cooked => return gpa.dupe(u8, std.mem.sliceAsBytes(blocks)),
        .raw => {
            const raw = try gpa.alloc(u8, blocks.len * cdimage.raw_sector_size);
            for (blocks, 0..) |*block, lba| {
                const sector = raw[lba * cdimage.raw_sector_size ..][0..cdimage.raw_sector_size];
                @memset(sector, 0);
                const header: *cdimage.Header = @ptrCast(sector[0..@sizeOf(cdimage.Header)]);
                header.* = .{ .sync = cdimage.sync_pattern, .address = .fromLba(@intCast(lba)), .mode = .mode1 };
                @memcpy(sector[@sizeOf(cdimage.Header)..][0..block_size], block);
            }
            return raw;
        },
    }
}

/// The files of a disc 1, for the tests, with `cabinet` as its `LANCER.CAB`.
fn testDisc1(cabinet: []const u8) [3]TestFile {
    return .{
        .{ .path = "LANCER.CAB", .data = cabinet },
        .{ .path = "GAME/CAB/LANGUAGE.DLL", .data = "strings" },
        .{ .path = "GAME/CAB/LANCER.EXE", .data = "loader" },
    };
}

/// A cabinet with the files the engine checks for, and one in a folder.
fn testGameCabinet(gpa: Allocator) ![]u8 {
    return testCabinet(gpa, &.{
        .{ .path = "CAB\\resource.hog", .data = "resources" },
        .{ .path = "CAB\\tcachehw.dat", .data = "textures" },
        .{ .path = "CAB\\shipstats.bin", .data = "ships" },
        .{ .path = "CAB\\music\\Theme.fat", .data = "music" },
    });
}

/// Writes `files` into the folder `path` of `dir`.
fn testFolder(io: Io, dir: Io.Dir, path: []const u8, files: []const TestFile) !void {
    try dir.createDirPath(io, path);
    var folder = try dir.openDir(io, path, .{});
    defer folder.close(io);
    for (files) |file| {
        if (std.fs.path.dirnamePosix(file.path)) |parent| try folder.createDirPath(io, parent);
        try folder.writeFile(io, .{ .sub_path = file.path, .data = file.data });
    }
}

/// An install's environment for the tests, with its output kept.
const TestRun = struct {
    out: Io.Writer.Allocating,
    err: Io.Writer.Allocating,

    fn init(gpa: Allocator) TestRun {
        return .{ .out = .init(gpa), .err = .init(gpa) };
    }

    fn deinit(test_run: *TestRun) void {
        test_run.out.deinit();
        test_run.err.deinit();
    }

    fn environment(test_run: *TestRun, dir: Io.Dir, mounted: []const []const u8, known: []const Release) Environment {
        return .{ .dir = dir, .mounted = mounted, .known = known, .out = &test_run.out.writer, .err = &test_run.err.writer };
    }
};

fn expectFile(io: Io, dir: Io.Dir, path: []const u8, expected: []const u8) !void {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings(expected, try dir.readFile(io, path, &buffer));
}

test Options {
    const plain = try Options.parse(&.{"games/starlancer"});
    try std.testing.expectEqualStrings("games/starlancer", plain.directory);
    try std.testing.expectEqual(null, plain.from);
    try std.testing.expect(!plain.force);
    const full = try Options.parse(&.{ "--from", "disc1.bin", "--force", "out" });
    try std.testing.expectEqualStrings("out", full.directory);
    try std.testing.expectEqualStrings("disc1.bin", full.from.?);
    try std.testing.expect(full.force);
    try std.testing.expectError(error.Usage, Options.parse(&.{}));
    try std.testing.expectError(error.Usage, Options.parse(&.{"--force"}));
    try std.testing.expectError(error.Usage, Options.parse(&.{ "a", "b" }));
    try std.testing.expectError(error.Usage, Options.parse(&.{ "out", "--from" }));
    try std.testing.expectError(error.Usage, Options.parse(&.{ "--help", "out" }));
}

test installPath {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("resource.hog", try installPath(arena, "CAB\\resource.hog"));
    try std.testing.expectEqualStrings("music/Theme.fat", try installPath(arena, "CAB/music/Theme.fat"));
    try std.testing.expectEqualStrings("readme.txt", try installPath(arena, "readme.txt"));
    try std.testing.expectEqualStrings("cab/CAB", try installPath(arena, "cab/cab/CAB"));
    try std.testing.expectError(error.UnsafeName, installPath(arena, "CAB\\..\\..\\evil.dll"));
    try std.testing.expectError(error.UnsafeName, installPath(arena, "C:\\Windows\\evil.dll"));
    try std.testing.expectError(error.UnsafeName, installPath(arena, "C:evil.dll"));
    try std.testing.expectError(error.UnsafeName, installPath(arena, "/etc/passwd"));
    try std.testing.expectError(error.UnsafeName, installPath(arena, "\\\\server\\share\\evil.dll"));
    try std.testing.expectEqualStrings("CAB", try installPath(arena, "CAB"));
    try std.testing.expectError(error.UnsafeName, installPath(arena, ""));
}

test discMounts {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const table =
        \\sysfs /sys sysfs rw,nosuid,nodev,noexec,relatime 0 0
        \\/dev/nvme0n1p2 / ext4 rw,relatime 0 0
        \\/dev/sr0 /media/player/SL_CD1 iso9660 ro,nosuid,nodev,relatime,nojoliet,check=s,map=n,blocksize=2048 0 0
        \\/dev/loop3 /mnt/star\040lancer\134disc udf ro,relatime 0 0
        \\/dev/sdb1 /media/player/USB vfat rw 0 0
        \\
    ;
    const points = try discMounts(arena, table);
    try std.testing.expectEqual(2, points.len);
    try std.testing.expectEqualStrings("/media/player/SL_CD1", points[0]);
    try std.testing.expectEqualStrings("/mnt/star lancer\\disc", points[1]);
    try std.testing.expectEqual(0, (try discMounts(arena, "")).len);
}

test mountedDiscs {
    // Whatever the system has mounted, and whatever is in its drives, looking doesn't fail.
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    for (try mountedDiscs(std.testing.io, arena_state.allocator())) |path| try std.testing.expect(path.len > 0);
}

test "telling the discs apart" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cabinet = try testGameCabinet(gpa);
    defer gpa.free(cabinet);
    const known = [_]Release{.{ .name = "the test release", .cabinet_size = cabinet.len }};
    const Tag = std.meta.Tag(Identity);
    const Case = struct { path: []const u8, identity: Tag };
    // Linux shows a disc's names in lower case.
    try testFolder(io, tmp.dir, "disc1", &testDisc1(cabinet));
    try testFolder(io, tmp.dir, "copy", &.{.{ .path = "lancer.cab", .data = "a cabinet of another size" }});
    try testFolder(io, tmp.dir, "disc2", &.{.{ .path = "game/cd2.hog", .data = "" }});
    try testFolder(io, tmp.dir, "photos", &.{.{ .path = "GAME/holiday.jpg", .data = "" }});
    const image = try testImage(gpa, "SL_CD1", &testDisc1(cabinet), .raw);
    defer gpa.free(image);
    try tmp.dir.writeFile(io, .{ .sub_path = "disc1.bin", .data = image });
    // Disc 2 is known by its label alone.
    const labelled = try testImage(gpa, "SL_CD2", &.{.{ .path = "README.TXT", .data = "" }}, .cooked);
    defer gpa.free(labelled);
    try tmp.dir.writeFile(io, .{ .sub_path = "disc2.iso", .data = labelled });
    const cases = [_]Case{
        .{ .path = "disc1", .identity = .known },
        .{ .path = "copy", .identity = .unrecognized },
        .{ .path = "disc2", .identity = .second },
        .{ .path = "photos", .identity = .other },
        .{ .path = "disc1.bin", .identity = .known },
        .{ .path = "disc2.iso", .identity = .second },
    };
    for (cases) |case| {
        const disc: Disc = try .open(io, tmp.dir, case.path);
        defer disc.close(io);
        try std.testing.expectEqual(case.identity, std.meta.activeTag(try disc.identify(io, arena, &known)));
    }
    // Of a release the installer doesn't know, disc 1 is still told apart.
    const disc: Disc = try .open(io, tmp.dir, "disc1.bin");
    defer disc.close(io);
    try std.testing.expectEqual(Tag.unrecognized, std.meta.activeTag(try disc.identify(io, arena, &releases)));
}

test "reading a disc's files" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A file over many blocks, read after a skip in pieces of changing sizes.
    const long = try gpa.alloc(u8, 100_000);
    defer gpa.free(long);
    for (long, 0..) |*byte, i| byte.* = @truncate(i * 7 + i / 251);
    const files = [_]TestFile{
        .{ .path = "A.TXT", .data = "short" },
        .{ .path = "DATA/LONG.BIN", .data = long },
        .{ .path = "DATA/EMPTY", .data = "" },
    };
    const image = try testImage(gpa, "TEST", &files, .raw);
    defer gpa.free(image);
    try tmp.dir.writeFile(io, .{ .sub_path = "disc.bin", .data = image });
    try testFolder(io, tmp.dir, "disc", &files);

    for ([_][]const u8{ "disc.bin", "disc" }) |path| {
        const disc: Disc = try .open(io, tmp.dir, path);
        defer disc.close(io);
        try std.testing.expectEqual(null, try disc.find(io, arena, "DATA/MISSING"));
        try std.testing.expectEqual(null, try disc.find(io, arena, "NOWHERE/A.TXT"));
        try std.testing.expectEqual(null, try disc.list(io, arena, "A.TXT"));
        try std.testing.expectEqual(2, (try disc.list(io, arena, "data")).?.len);

        const entry = (try disc.find(io, arena, "data/long.bin")).?;
        try std.testing.expectEqual(long.len, entry.size);
        var reader: Reader = try .open(io, arena, entry);
        defer reader.close(io);
        try std.testing.expectEqual(10, reader.skip(10));
        var read: std.ArrayList(u8) = .empty;
        var piece: [3000]u8 = undefined;
        var size: usize = 1;
        while (true) : (size = size * 3 % piece.len + 1) {
            const n = try reader.read(io, piece[0..size]);
            if (n == 0) break;
            try read.appendSlice(arena, piece[0..n]);
        }
        try std.testing.expectEqualSlices(u8, long[10..], read.items);
        try std.testing.expectEqual(0, reader.skip(1));

        var empty: Reader = try .open(io, arena, (try disc.find(io, arena, "DATA/EMPTY")).?);
        defer empty.close(io);
        try std.testing.expectEqual(0, try empty.read(io, &piece));
    }
}

test "installing from disc images and folders" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cabinet = try testGameCabinet(gpa);
    defer gpa.free(cabinet);
    const known = [_]Release{.{ .name = "the test release", .cabinet_size = cabinet.len }};
    for ([_]cdimage.Image.Layout{ .raw, .cooked }) |layout| {
        const image = try testImage(gpa, "SL_CD1", &testDisc1(cabinet), layout);
        defer gpa.free(image);
        try tmp.dir.writeFile(io, .{ .sub_path = @tagName(layout), .data = image });
    }
    // As Linux shows the disc: every name in lower case.
    try testFolder(io, tmp.dir, "mounted", &.{
        .{ .path = "lancer.cab", .data = cabinet },
        .{ .path = "game/cab/language.dll", .data = "strings" },
    });

    for ([_][]const u8{ "raw", "cooked", "mounted" }) |from| {
        var test_run: TestRun = .init(gpa);
        defer test_run.deinit();
        const directory = try std.fmt.allocPrint(arena, "games/from-{s}", .{from});
        const code = try run(io, arena, .{ .directory = directory, .from = from }, test_run.environment(tmp.dir, &.{}, &known));
        try std.testing.expectEqualStrings("", test_run.err.written());
        try std.testing.expectEqual(0, code);
        try std.testing.expect(std.mem.indexOf(u8, test_run.out.written(), "disc 1 of the test release") != null);

        var target = try tmp.dir.openDir(io, directory, .{});
        defer target.close(io);
        try expectFile(io, target, "resource.hog", "resources");
        try expectFile(io, target, "music/Theme.fat", "music");
        try expectFile(io, target, "LANGUAGE.DLL", "strings");
        try std.testing.expectEqual(null, missingGameFile(io, target));
    }
}

test "looking for disc 1 in the drives" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cabinet = try testGameCabinet(gpa);
    defer gpa.free(cabinet);
    const known = [_]Release{.{ .name = "the test release", .cabinet_size = cabinet.len }};
    const foreign = try testCabinet(gpa, &.{.{ .path = "CAB\\resource.hog", .data = "another country's" }});
    defer gpa.free(foreign);
    try testFolder(io, tmp.dir, "empty", &.{});
    try testFolder(io, tmp.dir, "disc2", &.{.{ .path = "GAME/CD2.HOG", .data = "" }});
    try testFolder(io, tmp.dir, "disc1", &testDisc1(cabinet));
    try testFolder(io, tmp.dir, "foreign", &testDisc1(foreign));

    // Drives that aren't there, or hold something else, are passed over.
    {
        var test_run: TestRun = .init(gpa);
        defer test_run.deinit();
        const mounted = [_][]const u8{ "no-such-drive", "empty", "disc2", "foreign", "disc1" };
        try std.testing.expectEqual(0, try run(io, arena, .{ .directory = "found" }, test_run.environment(tmp.dir, &mounted, &known)));
        try std.testing.expect(std.mem.indexOf(u8, test_run.out.written(), "Installing StarLancer from disc1,") != null);
        try tmp.dir.access(io, "found/LANGUAGE.DLL", .{});
    }
    // With only disc 2 in a drive, that's what's said.
    {
        var test_run: TestRun = .init(gpa);
        defer test_run.deinit();
        const mounted = [_][]const u8{ "empty", "disc2" };
        try std.testing.expectEqual(1, try run(io, arena, .{ .directory = "none" }, test_run.environment(tmp.dir, &mounted, &known)));
        try std.testing.expectEqualStrings("openreliant: disc2 is StarLancer disc 2. Installing needs disc 1.\n", test_run.err.written());
    }
    {
        var test_run: TestRun = .init(gpa);
        defer test_run.deinit();
        try std.testing.expectEqual(1, try run(io, arena, .{ .directory = "none" }, test_run.environment(tmp.dir, &.{"empty"}, &known)));
        try std.testing.expect(std.mem.startsWith(u8, test_run.err.written(), "openreliant: StarLancer disc 1 isn't in any CD drive."));
    }
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "none", .{}));
    // A disc 1 of a release the installer doesn't know is installed from only when asked to. Its
    // cabinet lacks most of the engine's files, which is then said.
    for ([_]bool{ false, true }) |force| {
        var test_run: TestRun = .init(gpa);
        defer test_run.deinit();
        const mounted = [_][]const u8{ "empty", "foreign" };
        try std.testing.expectEqual(1, try run(io, arena, .{ .directory = "foreign-install", .force = force }, test_run.environment(tmp.dir, &mounted, &known)));
        const says = if (force)
            "openreliant: the disc is unpacked, but it had no tcachehw.dat.\n"
        else
            "openreliant: foreign has StarLancer's installer, but it's not a release OpenReliant\nknows: its LANCER.CAB is ";
        try std.testing.expect(std.mem.startsWith(u8, test_run.err.written(), says));
    }
}

test "what the installer refuses" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const escaping = try testCabinet(gpa, &.{.{ .path = "CAB\\..\\..\\evil.dll", .data = "" }});
    defer gpa.free(escaping);
    // A cabinet whose data ends early.
    const damaged = try testGameCabinet(gpa);
    defer gpa.free(damaged);
    try testFolder(io, tmp.dir, "escaping", &testDisc1(escaping));
    try testFolder(io, tmp.dir, "garbage", &testDisc1("not a cabinet"));
    try testFolder(io, tmp.dir, "damaged", &testDisc1(damaged[0 .. damaged.len - 4]));
    try testFolder(io, tmp.dir, "disc2", &.{.{ .path = "GAME/CD2.HOG", .data = "" }});
    try testFolder(io, tmp.dir, "other", &.{.{ .path = "README.TXT", .data = "" }});
    try tmp.dir.writeFile(io, .{ .sub_path = "disc.zip", .data = "PK\x03\x04 not a disc image" });
    try tmp.dir.writeFile(io, .{ .sub_path = "disc.cue", .data = "FILE \"disc.bin\" BINARY\n" });

    const Case = struct { from: []const u8, says: []const u8 };
    const cases = [_]Case{
        .{ .from = "missing.bin", .says = "openreliant: there's no missing.bin.\n" },
        .{ .from = "disc.zip", .says = "openreliant: disc.zip is neither a folder nor a disc image.\n" },
        .{ .from = "disc.cue", .says = "openreliant: disc.cue only describes the disc. Name its .bin instead.\n" },
        .{ .from = "disc2", .says = "openreliant: disc2 is StarLancer disc 2. Installing needs disc 1.\n" },
        .{ .from = "other", .says = "openreliant: other isn't StarLancer disc 1: it has no LANCER.CAB.\n" },
        .{ .from = "escaping", .says = "openreliant: the cabinet has a file named CAB/../../evil.dll, outside the install.\n" },
        .{ .from = "garbage", .says = "openreliant: the cabinet can't be unpacked: " },
        .{ .from = "damaged", .says = "openreliant: the cabinet can't be unpacked: " },
    };
    for (cases) |case| {
        var test_run: TestRun = .init(gpa);
        defer test_run.deinit();
        const code = try run(io, arena, .{ .directory = "install/game", .from = case.from, .force = true }, test_run.environment(tmp.dir, &.{}, &.{}));
        try std.testing.expectEqual(1, code);
        if (!std.mem.startsWith(u8, test_run.err.written(), case.says)) {
            std.debug.print("installing from {s} said: {s}\n", .{ case.from, test_run.err.written() });
            return error.TestUnexpectedResult;
        }
    }
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "evil.dll", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "install/evil.dll", .{}));
}

test missingGameFile {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Each of the game's files in turn, and none once all are there.
    for (game_files) |name| {
        try std.testing.expectEqualStrings(name, missingGameFile(io, tmp.dir).?);
        try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "" });
    }
    try std.testing.expectEqual(null, missingGameFile(io, tmp.dir));
}
