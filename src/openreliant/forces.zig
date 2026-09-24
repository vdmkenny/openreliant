//! The force feedback's effects, read from the game's `forces\` folder as `load_force_effects`
//! (`0x004BD800`) reads them, into `engine.input.force.Library`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const openreliant = @import("openreliant");
const force = openreliant.engine.input.force;
const frc = openreliant.frc;

/// The effects read, and those the game lacks.
pub const Found = struct {
    library: force.Library = .{},
    /// The effects whose files are missing, can't be read or aren't effect files, which play
    /// nothing.
    lacking: std.EnumSet(force.Effect) = .initFull(),
};

/// Each effect's file in `forces\` under `directory`, the folder and the files found whatever the
/// case of their names, as Windows finds them.
pub fn load(io: Io, arena: Allocator, directory: Io.Dir) Found {
    var found: Found = .{};
    var folder = openFolder(io, arena, directory) orelse return found;
    defer folder.close(io);
    for (std.enums.values(force.Effect)) |effect| {
        const name = entryNamed(io, arena, folder, effect.fileName()) orelse continue;
        const bytes = folder.readFileAlloc(io, name, arena, .limited(1 << 20)) catch continue;
        const file = frc.File.parse(arena, bytes) catch continue;
        found.library.files.set(effect, file);
        found.lacking.remove(effect);
    }
    return found;
}

/// The `forces` folder under `directory`, however its name is spelled.
fn openFolder(io: Io, arena: Allocator, directory: Io.Dir) ?Io.Dir {
    var listed = directory.openDir(io, ".", .{ .iterate = true }) catch return null;
    defer listed.close(io);
    const name = entryNamed(io, arena, listed, "forces") orelse return null;
    return directory.openDir(io, name, .{ .iterate = true }) catch null;
}

/// The name of the entry of `dir` spelled `name` whatever its case.
fn entryNamed(io: Io, arena: Allocator, dir: Io.Dir, name: []const u8) ?[]const u8 {
    var entries = dir.iterate();
    while (entries.next(io) catch return null) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.name, name)) return arena.dupe(u8, entry.name) catch null;
    }
    return null;
}

test load {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // Without the folder, nothing plays.
    try std.testing.expect(load(io, arena, tmp.dir).lacking.contains(.lc));

    // The folder and its files are found whatever the case of their names; a file that isn't one
    // is left out.
    try tmp.dir.createDirPath(io, "Forces");
    const bytes = try frc.testing.file(arena, &.{.{ .id = 0, .name = "Sine1", .kind = 2, .type = 102, .duration = 305, .rest = &.{ 4, 30, @bitCast(@as(i32, -30)) } }});
    try tmp.dir.writeFile(io, .{ .sub_path = "Forces/Lc.FRC", .data = bytes });
    try tmp.dir.writeFile(io, .{ .sub_path = "Forces/SHAKE.frc", .data = "not an effect" });
    const found = load(io, arena, tmp.dir);
    try std.testing.expectEqual(305, found.library.files.get(.lc).?.effects[0].duration);
    try std.testing.expect(!found.lacking.contains(.lc));
    try std.testing.expectEqual(null, found.library.files.get(.shake));
    try std.testing.expect(found.lacking.contains(.shake) and found.lacking.contains(.missile));
}
