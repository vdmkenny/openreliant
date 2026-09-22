//! `.HOG` archives: the containers holding the game's assets.
//!
//! The format is Electronic Arts' `BIGF`. A 16-byte header is followed by a directory of
//! variable-length entries, then the members themselves, packed back to back with no padding and
//! no alignment. Every field is big-endian, which is unusual for a game built for x86 and is a
//! leftover of the format's console origins.
//!
//! Most members of `resource.hog` are RefPack-compressed; see `refpack.zig`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const layout = @import("layout.zig");
const Big = layout.Big;
const refpack = @import("refpack.zig");

pub const magic = "BIGF";

/// The fixed header.
pub const Header = extern struct {
    magic: [4]u8,
    archive_size: Big(u32),
    entry_count: Big(u32),
    /// Where the directory ends and the first member begins.
    data_offset: Big(u32),

    comptime {
        std.debug.assert(@sizeOf(Header) == 16);
    }
};

/// A directory record's fixed part, which its name follows, up to a NUL.
pub const Record = extern struct {
    offset: Big(u32),
    size: Big(u32),

    comptime {
        std.debug.assert(@sizeOf(Record) == 8);
    }
};

pub const Entry = struct {
    /// Stored name. Members are a flat namespace: no directories, no path separators.
    name: []const u8,
    offset: u32,
    /// Stored size, which is the compressed size for a RefPack member.
    size: u32,
};

pub const OpenError = error{
    NotAHog,
    /// The header's size field disagrees with the file.
    SizeMismatch,
    /// The directory ran out of room before the first member.
    CorruptDirectory,
};

pub const Archive = struct {
    io: Io,
    file: Io.File,
    header: Header,
    entries: []Entry,
    /// Entries the header counts but that hold no valid record. Two of the shipped archives end
    /// their directory with one uninitialized entry (`0xCD` filler, the MSVC debug pattern); the
    /// members themselves form a complete chain without it.
    phantom_entries: usize,

    pub fn open(gpa: Allocator, io: Io, dir: Io.Dir, path: []const u8) !Archive {
        const file = try dir.openFile(io, path, .{});
        errdefer file.close(io);

        var header: Header = undefined;
        if (try file.readPositionalAll(io, std.mem.asBytes(&header), 0) != @sizeOf(Header))
            return error.NotAHog;
        if (!std.mem.eql(u8, &header.magic, magic)) return error.NotAHog;

        const file_size = try file.length(io);
        if (header.archive_size.get() != file_size) return error.SizeMismatch;

        const directory = try gpa.alloc(u8, header.data_offset.get() -| @sizeOf(Header));
        defer gpa.free(directory);
        _ = try file.readPositionalAll(io, directory, @sizeOf(Header));

        var entries: std.ArrayList(Entry) = .empty;
        errdefer entries.deinit(gpa);

        var pos: usize = 0;
        for (0..header.entry_count.get()) |_| {
            const entry = parseEntry(directory[pos..], @intCast(file_size)) orelse break;
            try entries.append(gpa, .{
                .name = try gpa.dupe(u8, entry.name),
                .offset = entry.offset,
                .size = entry.size,
            });
            pos += entry.encoded_len;
        }
        if (entries.items.len == 0) return error.CorruptDirectory;
        // Read the count before handing the list over: taking the slice empties it.
        const phantom_entries = header.entry_count.get() - entries.items.len;

        return .{
            .io = io,
            .file = file,
            .header = header,
            .entries = try entries.toOwnedSlice(gpa),
            .phantom_entries = phantom_entries,
        };
    }

    pub fn close(archive: *Archive, gpa: Allocator) void {
        for (archive.entries) |entry| gpa.free(entry.name);
        gpa.free(archive.entries);
        archive.file.close(archive.io);
    }

    /// Reads a member exactly as stored, without decompressing it.
    pub fn readRaw(archive: Archive, gpa: Allocator, entry: Entry) ![]u8 {
        const bytes = try gpa.alloc(u8, entry.size);
        errdefer gpa.free(bytes);
        if (try archive.file.readPositionalAll(archive.io, bytes, entry.offset) != bytes.len)
            return error.UnexpectedEnd;
        return bytes;
    }

    /// Reads a member, decompressing it when it is RefPack-compressed.
    pub fn read(archive: Archive, gpa: Allocator, entry: Entry) !Contents {
        const raw = try archive.readRaw(gpa, entry);
        if (!refpack.looksCompressed(raw)) return .{ .bytes = raw, .compressed = false };
        defer gpa.free(raw);
        return .{ .bytes = try refpack.decompressAlloc(gpa, raw), .compressed = true };
    }

    pub const Contents = struct {
        bytes: []u8,
        /// Whether the stored member was RefPack-compressed.
        compressed: bool,

        pub fn deinit(contents: Contents, gpa: Allocator) void {
            gpa.free(contents.bytes);
        }
    };

    pub fn find(archive: Archive, name: []const u8) ?Entry {
        for (archive.entries) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.name, name)) return entry;
        }
        return null;
    }

    /// True when the members tile the file exactly, from `data_offset` to the last byte.
    pub fn isContiguous(archive: Archive) bool {
        var expected = archive.header.data_offset.get();
        for (archive.entries) |entry| {
            if (entry.offset != expected) return false;
            expected = entry.offset + entry.size;
        }
        return expected == archive.header.archive_size.get();
    }
};

const ParsedEntry = struct {
    name: []const u8,
    offset: u32,
    size: u32,
    encoded_len: usize,
};

/// Reads one directory record: a `Record`, then a NUL-terminated name. Returns null when the bytes
/// are not a plausible record, which is how the trailing filler is detected.
fn parseEntry(directory: []const u8, file_size: u32) ?ParsedEntry {
    const record = layout.view(Record, directory) catch return null;
    const offset = record.offset.get();
    const size = record.size.get();
    if (offset > file_size or size > file_size - offset) return null;

    const rest = directory[@sizeOf(Record)..];
    const end = std.mem.indexOfScalar(u8, rest, 0) orelse return null;
    if (end == 0) return null;
    const name = rest[0..end];
    for (name) |c| {
        if (c < 0x20 or c >= 0x7F) return null;
    }
    return .{ .name = name, .offset = offset, .size = size, .encoded_len = @sizeOf(Record) + end + 1 };
}

test parseEntry {
    var directory: [32]u8 = @splat(0);
    (try layout.viewMut(Record, &directory)).* = .{ .offset = .of(0x1000), .size = .of(0x200) };
    @memcpy(directory[@sizeOf(Record)..][0..8], "ship.shp");

    const entry = parseEntry(&directory, 0x10000).?;
    try std.testing.expectEqualStrings("ship.shp", entry.name);
    try std.testing.expectEqual(@as(u32, 0x1000), entry.offset);
    try std.testing.expectEqual(@as(u32, 0x200), entry.size);
    try std.testing.expectEqual(@as(usize, 17), entry.encoded_len);

    // Past the end of the archive, and the uninitialized filler both shipped archives end with.
    try std.testing.expectEqual(@as(?ParsedEntry, null), parseEntry(&directory, 0x100));
    try std.testing.expectEqual(@as(?ParsedEntry, null), parseEntry(&(@as([32]u8, @splat(0xCD))), 0x100000));
}

test "header reads big-endian fields" {
    const header: Header = .{
        .magic = magic.*,
        .archive_size = .{ .bytes = .{ 0x03, 0x5B, 0x92, 0x50 } },
        .entry_count = .{ .bytes = .{ 0x00, 0x00, 0x11, 0x11 } },
        .data_offset = .{ .bytes = .{ 0x00, 0x01, 0x99, 0x68 } },
    };
    try std.testing.expectEqual(@as(u32, 56332880), header.archive_size.get());
    try std.testing.expectEqual(@as(u32, 4369), header.entry_count.get());
    try std.testing.expectEqual(@as(u32, 104808), header.data_offset.get());
}
