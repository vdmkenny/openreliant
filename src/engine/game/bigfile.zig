//! `C:\lancer\game\bigfile.cpp`: the `.HOG` archives the game reads its files from.
//! `WinMain` opens `resource.hog` at start-up, and `msspeech.hog` for the HUD's speech.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hog = @import("../../formats/hog.zig");
const layout = @import("../../formats/layout.zig");
const refpack = @import("../../formats/refpack.zig");

const log = std.log.scoped(.bigfile);

/// The archive `WinMain` opens at start-up, in the game's directory.
pub const resource_name = "resource.hog";

pub const ReadError = Allocator.Error || Io.File.ReadPositionalError || refpack.Error || error{
    /// A name the archive lacks: the game stops with `HOG bigread2: error loading %s`.
    FileMissing,
    UnexpectedEnd,
};

/// An open archive (`hog_open`, `0x004C7E20`): its file and its directory.
pub const Hog = struct {
    archive: hog.Archive,

    pub fn open(gpa: Allocator, io: Io, dir: Io.Dir, path: []const u8) !Hog {
        return .{ .archive = try .open(gpa, io, dir, path) };
    }

    /// `hog_close` (`0x004C7F20`).
    pub fn close(archive: *Hog, gpa: Allocator) void {
        archive.archive.close(gpa);
    }

    /// The member `name` names, expanded when RefPack packed it (`hog_read_file`, `0x004C7F60`).
    /// The game looks it up by `memberName`, ignoring case (`hog_seek`, `0x004C8370`), and takes
    /// it as packed when it starts `10 FB`.
    pub fn readFile(archive: Hog, gpa: Allocator, name: []const u8) ReadError![]u8 {
        var buffer: [128]u8 = undefined;
        const member = memberName(&buffer, name);
        const entry = archive.archive.find(member) orelse {
            log.err("HOG bigread2: error loading {s}", .{member});
            return error.FileMissing;
        };
        const raw = try archive.archive.readRaw(gpa, entry);
        if (!refpack.gameExpands(raw)) return raw;
        defer gpa.free(raw);
        return refpack.decompressAlloc(gpa, raw);
    }
};

/// The name `hog_read_file` looks a file up by: `name` less an extension beginning `ut`, from its
/// last `\` on. Longer names are cut to the game's buffer, 128 bytes.
pub fn memberName(buffer: *[128]u8, name: []const u8) []const u8 {
    const length = @min(name.len, buffer.len);
    @memcpy(buffer[0..length], name[0..length]);
    var copy: []const u8 = buffer[0..length];
    if (std.mem.indexOfScalar(u8, copy, '.')) |dot| {
        if (std.mem.startsWith(u8, copy[dot + 1 ..], "ut")) copy = copy[0..dot];
    }
    if (std.mem.lastIndexOfScalar(u8, copy, '\\')) |slash| copy = copy[slash + 1 ..];
    return copy;
}

test memberName {
    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("USLF_Prd.SHP", memberName(&buffer, "USLF_Prd.SHP"));
    try std.testing.expectEqualStrings("space.tga", memberName(&buffer, "nebula\\space.tga"));
    try std.testing.expectEqualStrings("intro", memberName(&buffer, "movies\\intro.utx"));
}

test Hog {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // One member, `Ship.SHP`, holding `hello`.
    try testing.write(gpa, io, tmp.dir, resource_name, &.{.{ .name = "Ship.SHP", .data = "hello" }});

    var archive: Hog = try .open(gpa, io, tmp.dir, resource_name);
    defer archive.close(gpa);
    const contents = try archive.readFile(gpa, "models\\ship.shp");
    defer gpa.free(contents);
    try std.testing.expectEqualStrings("hello", contents);
}

pub const testing = hog.testing;
