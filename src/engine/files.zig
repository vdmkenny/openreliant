//! The game's own file names, as it hands them to Windows: folders split by `\`, each name found
//! whatever its case. `find` and `readFile` find them the same way on any system, so that a file
//! a player drops into the game's folders is found however its name is spelled.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// The longest path the game builds, Windows' `MAX_PATH`.
pub const max_path = 260;

/// The most OpenReliant reads of one of the game's files into memory, far past the largest.
pub const max_file_size = 64 << 20;

/// The file or folder `path` names under `dir`, spelled as it is on disk and with `/` between its
/// names, in `buffer`; null where none does. `.` names the folder itself, and `\` and `/` both
/// split the names.
pub fn find(io: Io, dir: Io.Dir, path: []const u8, buffer: *[max_path]u8) ?[]const u8 {
    var found: usize = 0;
    var names = std.mem.tokenizeAny(u8, path, "\\/");
    while (names.next()) |name| {
        if (std.mem.eql(u8, name, ".")) continue;
        var folder = dir.openDir(io, if (found == 0) "." else buffer[0..found], .{ .iterate = true }) catch return null;
        defer folder.close(io);
        const spelled = entryNamed(io, folder, name) orelse return null;
        const separator: usize = @intFromBool(found > 0);
        if (found + separator + spelled.len > buffer.len) return null;
        if (separator > 0) buffer[found] = '/';
        @memcpy(buffer[found + separator ..][0..spelled.len], spelled);
        found += separator + spelled.len;
    }
    return buffer[0..found];
}

/// The name of the entry of `folder` spelled `name` whatever its case, which lives as long as the
/// iteration's buffer: until `folder` is closed.
fn entryNamed(io: Io, folder: Io.Dir, name: []const u8) ?[]const u8 {
    var entries = folder.iterate();
    while (entries.next(io) catch return null) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.name, name)) return entry.name;
    }
    return null;
}

/// Whether `path` names a file or folder under `dir`, as the game asks with `_access`.
pub fn exists(io: Io, dir: Io.Dir, path: []const u8) bool {
    var buffer: [max_path]u8 = undefined;
    return find(io, dir, path, &buffer) != null;
}

/// The whole of the file `path` names under `dir`, made in `gpa`, found as `find` finds it; null
/// where there is none.
pub fn readFile(io: Io, gpa: Allocator, dir: Io.Dir, path: []const u8, limit: Io.Limit) Io.Dir.ReadFileAllocError!?[]u8 {
    var buffer: [max_path]u8 = undefined;
    const spelled = find(io, dir, path, &buffer) orelse return null;
    return try dir.readFileAlloc(io, spelled, gpa, limit);
}

test find {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "Missions");
    try tmp.dir.writeFile(io, .{ .sub_path = "Missions/Mission1.DTE", .data = "mission" });

    // Found whatever the case, from the game's own spelling.
    var buffer: [max_path]u8 = undefined;
    try std.testing.expectEqualStrings("Missions/Mission1.DTE", find(io, tmp.dir, ".\\missions\\mission1.dte", &buffer).?);
    try std.testing.expect(exists(io, tmp.dir, "missions/MISSION1.dte"));
    try std.testing.expect(exists(io, tmp.dir, "missions"));
    try std.testing.expect(!exists(io, tmp.dir, "missions\\mission2.dte"));
    try std.testing.expect(!exists(io, tmp.dir, "other\\mission1.dte"));

    const bytes = (try readFile(io, std.testing.allocator, tmp.dir, "MISSIONS\\mission1.dte", .unlimited)).?;
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("mission", bytes);
    try std.testing.expectEqual(null, try readFile(io, std.testing.allocator, tmp.dir, "missions\\mission2.dte", .unlimited));
}
