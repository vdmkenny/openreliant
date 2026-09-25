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
        if (!refPacked(raw)) return raw;
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

/// The start of a member the game expands, which `hog_read_file` compares its first word with,
/// read big-endian, as `0x10FB`: RefPack's flags with only `magic` set, then its `signature`.
const packed_start = [2]u8{
    @bitCast(refpack.Header.Flags{ .compressed_size_present = false, ._unused = 0, .magic = 1, ._unused2 = 0, .wide_sizes = false }),
    refpack.signature,
};

/// Whether a member starts as `packed_start`, the one form the game expands. A RefPack stream
/// with other flags, which `refpack.looksCompressed` takes, the game reads as it is.
fn refPacked(raw: []const u8) bool {
    return std.mem.startsWith(u8, raw, &packed_start);
}

test refPacked {
    try std.testing.expect(refPacked(&.{ 0x10, 0xFB, 0x00, 0x00, 0x05 }));
    // Sizes of four bytes, or the packed size given, are not the game's form.
    try std.testing.expect(!refPacked(&.{ 0x90, 0xFB, 0x00, 0x00, 0x00, 0x05 }));
    try std.testing.expect(!refPacked(&.{ 0x11, 0xFB }));
    try std.testing.expect(!refPacked(&.{0x10}));
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

pub const testing = struct {
    pub const Member = struct { name: []const u8, data: []const u8 };

    /// Writes an archive of `members`, stored as they are, to `path` in `dir`: its header, then
    /// a record and a NUL-terminated name for each member, then their data.
    pub fn write(gpa: Allocator, io: Io, dir: Io.Dir, path: []const u8, members: []const Member) !void {
        var data_at: usize = @sizeOf(hog.Header);
        var data_size: usize = 0;
        for (members) |member| {
            data_at += @sizeOf(hog.Record) + member.name.len + 1;
            data_size += member.data.len;
        }
        const bytes = try gpa.alloc(u8, data_at + data_size);
        defer gpa.free(bytes);
        (try layout.viewMut(hog.Header, bytes)).* = .{
            .magic = hog.magic.*,
            .archive_size = .of(@intCast(bytes.len)),
            .entry_count = .of(@intCast(members.len)),
            .data_offset = .of(@intCast(data_at)),
        };
        var entry_at: usize = @sizeOf(hog.Header);
        var datum_at = data_at;
        for (members) |member| {
            (try layout.viewMut(hog.Record, bytes[entry_at..])).* = .{ .offset = .of(@intCast(datum_at)), .size = .of(@intCast(member.data.len)) };
            const name_at = entry_at + @sizeOf(hog.Record);
            @memcpy(bytes[name_at..][0..member.name.len], member.name);
            bytes[name_at + member.name.len] = 0;
            entry_at = name_at + member.name.len + 1;
            @memcpy(bytes[datum_at..][0..member.data.len], member.data);
            datum_at += member.data.len;
        }
        try dir.writeFile(io, .{ .sub_path = path, .data = bytes });
    }
};
