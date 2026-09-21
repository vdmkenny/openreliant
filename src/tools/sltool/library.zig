//! Finds models by the engine's file names in a directory of extracted game files, ignoring case as
//! the game's file system does.

const std = @import("std");
const Io = std.Io;

const starlancer = @import("starlancer");
const shp = starlancer.shp;

const Context = @import("main.zig").Context;

pub const Library = struct {
    ctx: Context,
    dir: Io.Dir,
    /// Lower-cased file name to the name on disk.
    names: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// Models read so far, by lower-cased file name; null for one the directory lacks.
    models: std.StringHashMapUnmanaged(?shp.Model) = .empty,

    /// The directory holding the file at `path`.
    pub fn beside(ctx: Context, path: []const u8) !Library {
        const dir_path = std.fs.path.dirname(path) orelse ".";
        var dir = try Io.Dir.cwd().openDir(ctx.io, dir_path, .{ .iterate = true });
        errdefer dir.close(ctx.io);

        var library: Library = .{ .ctx = ctx, .dir = dir };
        var it = dir.iterate();
        while (try it.next(ctx.io)) |entry| {
            if (entry.kind != .file) continue;
            const name = try ctx.arena.dupe(u8, entry.name);
            try library.names.put(ctx.arena, try std.ascii.allocLowerString(ctx.arena, name), name);
        }
        return library;
    }

    pub fn deinit(library: *Library) void {
        library.dir.close(library.ctx.io);
    }

    /// The model the file `name` holds, or null when the directory has no such file.
    pub fn load(library: *Library, name: []const u8) !?shp.Model {
        const key = try std.ascii.allocLowerString(library.ctx.arena, name);
        if (library.models.get(key)) |model| return model;
        const model: ?shp.Model = if (library.names.get(key)) |on_disk| blk: {
            const data = try library.dir.readFileAlloc(library.ctx.io, on_disk, library.ctx.arena, .limited(64 << 20));
            break :blk try shp.Model.parse(library.ctx.arena, data);
        } else null;
        try library.models.put(library.ctx.arena, key, model);
        return model;
    }

    /// The components an object of the model `name` lists, or null when the model is missing.
    pub fn components(library: *Library, name: []const u8) !?[]const shp.Component {
        const model = try library.load(name) orelse return null;
        return try shp.components(library.ctx.arena, model, name, library);
    }
};
