//! ISO 9660 filesystem reader, with Joliet long file names.
//!
//! Read-only and deliberately small: enough to list and extract the contents of a game disc
//! straight from a `cdimage.Image`, without mounting anything.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const cdimage = @import("cdimage.zig");
const block_size = cdimage.block_size;

/// ISO 9660 records every multi-byte integer twice: little-endian, then big-endian.
pub fn BothEndian(comptime T: type) type {
    return extern struct {
        little: [@sizeOf(T)]u8,
        big: [@sizeOf(T)]u8,

        const Self = @This();

        pub fn init(value: T) Self {
            var both: Self = undefined;
            std.mem.writeInt(T, &both.little, value, .little);
            std.mem.writeInt(T, &both.big, value, .big);
            return both;
        }

        pub fn get(both: Self) T {
            return std.mem.readInt(T, &both.little, .little);
        }
    };
}

pub const RecordingTime = extern struct {
    years_since_1900: u8,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
    /// Offset from GMT, in 15 minute steps.
    gmt_offset: i8,

    pub fn format(time: RecordingTime, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{
            @as(u16, time.years_since_1900) + 1900, time.month, time.day, time.hour, time.minute,
        });
    }
};

pub const FileFlags = packed struct(u8) {
    hidden: bool,
    directory: bool,
    associated_file: bool,
    record_format: bool,
    protection: bool,
    _reserved: u2,
    /// The file continues in the next directory record (files over 4 GiB).
    multi_extent: bool,
};

/// The fixed part of a directory record. `identifier_length` bytes of name follow it.
pub const DirectoryRecord = extern struct {
    length: u8,
    extended_attribute_length: u8,
    extent: BothEndian(u32),
    data_length: BothEndian(u32),
    recorded_at: RecordingTime,
    flags: FileFlags,
    file_unit_size: u8,
    interleave_gap_size: u8,
    volume_sequence_number: BothEndian(u16),
    identifier_length: u8,

    /// Identifiers of the two records that open every directory.
    pub const self_identifier = "\x00";
    pub const parent_identifier = "\x01";

    comptime {
        assert(@sizeOf(DirectoryRecord) == 33);
    }
};

/// Layout shared by the primary and supplementary volume descriptors, up to the root directory.
pub const VolumeDescriptor = extern struct {
    type: Type,
    standard_identifier: [5]u8,
    version: u8,
    /// Supplementary descriptors only.
    volume_flags: u8,
    system_identifier: [32]u8,
    volume_identifier: [32]u8,
    _unused: [8]u8,
    volume_space_size: BothEndian(u32),
    /// Supplementary descriptors only. Joliet announces itself here.
    escape_sequences: [32]u8,
    volume_set_size: BothEndian(u16),
    volume_sequence_number: BothEndian(u16),
    logical_block_size: BothEndian(u16),
    path_table_size: BothEndian(u32),
    path_table_locations: [16]u8,
    root_directory: DirectoryRecord,

    pub const Type = enum(u8) {
        boot_record = 0,
        primary = 1,
        supplementary = 2,
        partition = 3,
        set_terminator = 255,
        _,
    };

    pub const magic = "CD001";
    /// Volume descriptors start here and run until a `set_terminator`.
    pub const first_lba = 16;

    comptime {
        assert(@offsetOf(VolumeDescriptor, "volume_identifier") == 40);
        assert(@offsetOf(VolumeDescriptor, "escape_sequences") == 88);
        assert(@offsetOf(VolumeDescriptor, "logical_block_size") == 128);
        assert(@offsetOf(VolumeDescriptor, "root_directory") == 156);
    }

    /// The UCS-2 level a supplementary descriptor declares, if it is a Joliet one.
    pub fn jolietLevel(descriptor: *const VolumeDescriptor) ?JolietLevel {
        if (descriptor.type != .supplementary) return null;
        inline for (@typeInfo(JolietLevel).@"enum".fields) |field| {
            const level: JolietLevel = @enumFromInt(field.value);
            if (std.mem.startsWith(u8, &descriptor.escape_sequences, level.escapeSequence())) return level;
        }
        return null;
    }
};

pub const JolietLevel = enum {
    level1,
    level2,
    level3,

    pub fn escapeSequence(level: JolietLevel) []const u8 {
        return switch (level) {
            .level1 => "%/@",
            .level2 => "%/C",
            .level3 => "%/E",
        };
    }
};

pub const Extent = struct {
    lba: u32,
    len: u32,
};

pub const Entry = struct {
    /// UTF-8, without the ISO 9660 version suffix.
    name: []const u8,
    kind: Kind,
    extent: Extent,
    recorded_at: RecordingTime,

    pub const Kind = enum { file, directory };
};

pub const Volume = struct {
    image: cdimage.Image,
    namespace: Namespace,
    descriptor: VolumeDescriptor,

    /// Which of the disc's directory hierarchies names are read from.
    pub const Namespace = enum {
        /// The primary hierarchy: 8.3 upper-case names.
        iso9660,
        /// The Joliet hierarchy: long UCS-2 names.
        joliet,
    };

    pub const OpenError = error{ NotIso9660, UnsupportedBlockSize };

    /// Opens the filesystem on `image`, preferring Joliet names when the disc has them.
    pub fn open(image: cdimage.Image) !Volume {
        var primary: ?VolumeDescriptor = null;
        var joliet: ?VolumeDescriptor = null;

        var lba: u32 = VolumeDescriptor.first_lba;
        while (true) : (lba += 1) {
            var block: [block_size]u8 = undefined;
            image.readBlocks(lba, &block) catch |err| switch (err) {
                error.EndOfImage => return error.NotIso9660,
                else => |e| return e,
            };
            const descriptor: *const VolumeDescriptor = @ptrCast(block[0..@sizeOf(VolumeDescriptor)]);
            if (!std.mem.eql(u8, &descriptor.standard_identifier, VolumeDescriptor.magic))
                return error.NotIso9660;

            switch (descriptor.type) {
                .primary => primary = descriptor.*,
                .supplementary => if (descriptor.jolietLevel() != null) {
                    joliet = descriptor.*;
                },
                .set_terminator => break,
                .boot_record, .partition, _ => {},
            }
        }

        const namespace: Namespace = if (joliet != null) .joliet else .iso9660;
        const descriptor = joliet orelse primary orelse return error.NotIso9660;
        if (descriptor.logical_block_size.get() != block_size) return error.UnsupportedBlockSize;
        return .{ .image = image, .namespace = namespace, .descriptor = descriptor };
    }

    pub fn root(volume: *const Volume) Extent {
        const record = &volume.descriptor.root_directory;
        return .{ .lba = record.extent.get(), .len = record.data_length.get() };
    }

    /// The volume label, in UTF-8.
    pub fn label(volume: *const Volume, arena: Allocator) ![]const u8 {
        const name = try volume.decodeIdentifier(arena, &volume.descriptor.volume_identifier);
        return std.mem.trimEnd(u8, name, " ");
    }

    /// Lists the directory stored at `dir`, leaving out its "." and ".." records.
    pub fn readDirectory(volume: *const Volume, arena: Allocator, dir: Extent) ![]Entry {
        const bytes = try arena.alloc(u8, std.mem.alignForward(usize, dir.len, block_size));
        try volume.image.readBlocks(dir.lba, bytes);

        var entries: std.ArrayList(Entry) = .empty;
        var pos: usize = 0;
        while (pos < dir.len) {
            const record_len = bytes[pos];
            if (record_len == 0) {
                // Records never straddle a block: the rest of this one is padding.
                pos = std.mem.alignForward(usize, pos + 1, block_size);
                continue;
            }
            if (record_len < @sizeOf(DirectoryRecord) or bytes.len - pos < record_len) return error.CorruptDirectory;
            const record: *const DirectoryRecord = @ptrCast(bytes[pos..][0..@sizeOf(DirectoryRecord)]);
            if (@sizeOf(DirectoryRecord) + @as(usize, record.identifier_length) > record_len) return error.CorruptDirectory;
            const identifier = bytes[pos + @sizeOf(DirectoryRecord) ..][0..record.identifier_length];
            pos += record_len;

            if (std.mem.eql(u8, identifier, DirectoryRecord.self_identifier) or
                std.mem.eql(u8, identifier, DirectoryRecord.parent_identifier)) continue;
            if (record.flags.multi_extent) return error.MultiExtentUnsupported;

            const kind: Entry.Kind = if (record.flags.directory) .directory else .file;
            const name = try volume.decodeIdentifier(arena, identifier);
            try entries.append(arena, .{
                .name = switch (kind) {
                    .file => stripVersion(name),
                    .directory => name,
                },
                .kind = kind,
                .extent = .{ .lba = record.extent.get(), .len = record.data_length.get() },
                .recorded_at = record.recorded_at,
            });
        }
        return entries.toOwnedSlice(arena);
    }

    /// Depth-first traversal of the whole volume. Everything is allocated from `arena`.
    pub fn walk(volume: *const Volume, arena: Allocator) !Walker {
        var walker: Walker = .{ .volume = volume, .arena = arena, .stack = .empty };
        try walker.push("", volume.root());
        return walker;
    }

    fn decodeIdentifier(volume: *const Volume, arena: Allocator, identifier: []const u8) ![]const u8 {
        switch (volume.namespace) {
            .iso9660 => return arena.dupe(u8, identifier),
            .joliet => {
                if (identifier.len % 2 != 0) return error.CorruptDirectory;
                const units = try arena.alloc(u16, identifier.len / 2);
                for (units, 0..) |*unit, i| {
                    const big = std.mem.readInt(u16, identifier[i * 2 ..][0..2], .big);
                    unit.* = std.mem.nativeToLittle(u16, big);
                }
                return std.unicode.utf16LeToUtf8Alloc(arena, units);
            },
        }
    }
};

pub const Walker = struct {
    volume: *const Volume,
    arena: Allocator,
    stack: std.ArrayList(Frame),

    const Frame = struct {
        path: []const u8,
        entries: []const Entry,
        index: usize = 0,
    };

    pub const Item = struct {
        /// Path from the root of the volume, `/`-separated.
        path: []const u8,
        entry: Entry,
    };

    pub fn next(walker: *Walker) !?Item {
        while (walker.stack.items.len > 0) {
            const frame = &walker.stack.items[walker.stack.items.len - 1];
            if (frame.index == frame.entries.len) {
                _ = walker.stack.pop();
                continue;
            }
            const entry = frame.entries[frame.index];
            frame.index += 1;

            const path = if (frame.path.len == 0)
                entry.name
            else
                try std.mem.concat(walker.arena, u8, &.{ frame.path, "/", entry.name });
            // `frame` is invalidated by the push below.
            if (entry.kind == .directory) try walker.push(path, entry.extent);
            return .{ .path = path, .entry = entry };
        }
        return null;
    }

    fn push(walker: *Walker, path: []const u8, dir: Extent) !void {
        const entries = try walker.volume.readDirectory(walker.arena, dir);
        try walker.stack.append(walker.arena, .{ .path = path, .entries = entries });
    }
};

/// Drops the `;1` version suffix, and the `.` ISO 9660 leaves on names without an extension.
fn stripVersion(name: []const u8) []const u8 {
    var end = std.mem.lastIndexOfScalar(u8, name, ';') orelse name.len;
    if (end > 0 and name[end - 1] == '.') end -= 1;
    return name[0..end];
}

test stripVersion {
    try std.testing.expectEqualStrings("LANCER.EXE", stripVersion("LANCER.EXE;1"));
    try std.testing.expectEqualStrings("README", stripVersion("README.;1"));
    try std.testing.expectEqualStrings("Setup.exe", stripVersion("Setup.exe"));
}

test "BothEndian stores both byte orders" {
    const both: BothEndian(u32) = .init(0x11223344);
    try std.testing.expectEqualSlices(u8, &.{ 0x44, 0x33, 0x22, 0x11, 0x11, 0x22, 0x33, 0x44 }, std.mem.asBytes(&both));
    try std.testing.expectEqual(@as(u32, 0x11223344), both.get());
}

/// Minimal in-memory disc builder for the tests below.
const TestDisc = struct {
    blocks: [block_count][block_size]u8 = @splat(@splat(0)),

    const block_count = 24;
    const root_lba = 20;
    const sub_lba = 21;
    const file_lba = 22;
    const file_contents = "hello from the disc";

    fn writeRecord(block: *[block_size]u8, pos: *usize, identifier: []const u8, extent: Extent, flags: FileFlags) void {
        const len = std.mem.alignForward(usize, @sizeOf(DirectoryRecord) + identifier.len, 2);
        const record: *DirectoryRecord = @ptrCast(block[pos.*..][0..@sizeOf(DirectoryRecord)]);
        record.* = .{
            .length = @intCast(len),
            .extended_attribute_length = 0,
            .extent = .init(extent.lba),
            .data_length = .init(extent.len),
            .recorded_at = .{ .years_since_1900 = 100, .month = 3, .day = 31, .hour = 12, .minute = 0, .second = 0, .gmt_offset = 0 },
            .flags = flags,
            .file_unit_size = 0,
            .interleave_gap_size = 0,
            .volume_sequence_number = .init(1),
            .identifier_length = @intCast(identifier.len),
        };
        @memcpy(block[pos.* + @sizeOf(DirectoryRecord) ..][0..identifier.len], identifier);
        pos.* += len;
    }

    fn init() TestDisc {
        const file_flags: FileFlags = @bitCast(@as(u8, 0));
        var dir_flags = file_flags;
        dir_flags.directory = true;
        const root_extent: Extent = .{ .lba = root_lba, .len = block_size };
        const sub_extent: Extent = .{ .lba = sub_lba, .len = block_size };

        var disc: TestDisc = .{};

        const primary: *VolumeDescriptor = @ptrCast(disc.blocks[16][0..@sizeOf(VolumeDescriptor)]);
        primary.type = .primary;
        primary.standard_identifier = VolumeDescriptor.magic.*;
        primary.version = 1;
        primary.volume_identifier = ("SL_TEST" ++ " " ** 25).*;
        primary.logical_block_size = .init(block_size);
        var pos: usize = 0;
        var root_record: [block_size]u8 = @splat(0);
        writeRecord(&root_record, &pos, DirectoryRecord.self_identifier, root_extent, dir_flags);
        primary.root_directory = @as(*const DirectoryRecord, @ptrCast(root_record[0..@sizeOf(DirectoryRecord)])).*;

        disc.blocks[17][0] = @intFromEnum(VolumeDescriptor.Type.set_terminator);
        disc.blocks[17][1..6].* = VolumeDescriptor.magic.*;

        pos = 0;
        writeRecord(&disc.blocks[root_lba], &pos, DirectoryRecord.self_identifier, root_extent, dir_flags);
        writeRecord(&disc.blocks[root_lba], &pos, DirectoryRecord.parent_identifier, root_extent, dir_flags);
        writeRecord(&disc.blocks[root_lba], &pos, "DATA", sub_extent, dir_flags);
        writeRecord(&disc.blocks[root_lba], &pos, "README.;1", .{ .lba = file_lba, .len = file_contents.len }, file_flags);

        pos = 0;
        writeRecord(&disc.blocks[sub_lba], &pos, DirectoryRecord.self_identifier, sub_extent, dir_flags);
        writeRecord(&disc.blocks[sub_lba], &pos, DirectoryRecord.parent_identifier, root_extent, dir_flags);
        writeRecord(&disc.blocks[sub_lba], &pos, "LANCER.EXE;1", .{ .lba = file_lba, .len = file_contents.len }, file_flags);

        @memcpy(disc.blocks[file_lba][0..file_contents.len], file_contents);
        return disc;
    }
};

test "walk a volume" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const disc: TestDisc = .init();
    const image: cdimage.Image = try .init(.{ .memory = std.mem.asBytes(&disc.blocks) });
    const volume: Volume = try .open(image);
    try std.testing.expectEqual(Volume.Namespace.iso9660, volume.namespace);
    try std.testing.expectEqualStrings("SL_TEST", try volume.label(arena));

    var walker = try volume.walk(arena);
    const expected = [_]struct { []const u8, Entry.Kind }{
        .{ "DATA", .directory },
        .{ "DATA/LANCER.EXE", .file },
        .{ "README", .file },
    };
    for (expected) |want| {
        const item = (try walker.next()).?;
        try std.testing.expectEqualStrings(want[0], item.path);
        try std.testing.expectEqual(want[1], item.entry.kind);
    }
    try std.testing.expectEqual(@as(?Walker.Item, null), try walker.next());

    var contents: [TestDisc.file_contents.len]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&contents);
    try image.streamExtent(TestDisc.file_lba, contents.len, &writer);
    try std.testing.expectEqualStrings(TestDisc.file_contents, &contents);
}

test "not a filesystem" {
    const blank: [20 * block_size]u8 = @splat(0);
    const image: cdimage.Image = try .init(.{ .memory = &blank });
    try std.testing.expectError(error.NotIso9660, Volume.open(image));
}
