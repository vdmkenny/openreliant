//! Portable Executable reader, covering what this project needs: the section table, the data
//! directories, and the import descriptors. Read-only, and it never maps or runs anything.

const std = @import("std");
const assert = std.debug.assert;

pub const dos_magic = "MZ";
pub const nt_signature = "PE\x00\x00";

pub const Machine = enum(u16) {
    i386 = 0x014C,
    amd64 = 0x8664,
    arm64 = 0xAA64,
    _,
};

pub const DosHeader = extern struct {
    magic: [2]u8,
    _unused: [58]u8,
    /// File offset of the PE signature.
    nt_offset: u32,

    comptime {
        assert(@sizeOf(DosHeader) == 64);
    }
};

pub const FileHeader = extern struct {
    machine: Machine,
    section_count: u16,
    timestamp: u32,
    symbol_table_offset: u32,
    symbol_count: u32,
    optional_header_size: u16,
    characteristics: Characteristics,

    pub const Characteristics = packed struct(u16) {
        relocs_stripped: bool,
        executable: bool,
        line_numbers_stripped: bool,
        local_symbols_stripped: bool,
        aggressive_working_set_trim: bool,
        large_address_aware: bool,
        _reserved: u1,
        bytes_reversed_lo: bool,
        machine_32bit: bool,
        debug_stripped: bool,
        removable_run_from_swap: bool,
        net_run_from_swap: bool,
        system: bool,
        dll: bool,
        uniprocessor_only: bool,
        bytes_reversed_hi: bool,
    };

    comptime {
        assert(@sizeOf(FileHeader) == 20);
    }
};

pub const OptionalHeaderMagic = enum(u16) {
    pe32 = 0x010B,
    pe32plus = 0x020B,
    _,
};

/// The PE32 optional header, up to the data directories. PE32+ differs from `image_base` on, which
/// this project has no 64-bit images to need.
pub const OptionalHeader32 = extern struct {
    magic: OptionalHeaderMagic,
    linker_major: u8,
    linker_minor: u8,
    code_size: u32,
    initialized_data_size: u32,
    uninitialized_data_size: u32,
    entry_point: u32,
    code_base: u32,
    data_base: u32,
    image_base: u32,
    section_alignment: u32,
    file_alignment: u32,
    os_major: u16,
    os_minor: u16,
    image_major: u16,
    image_minor: u16,
    subsystem_major: u16,
    subsystem_minor: u16,
    win32_version: u32,
    image_size: u32,
    headers_size: u32,
    checksum: u32,
    subsystem: u16,
    dll_characteristics: u16,
    stack_reserve: u32,
    stack_commit: u32,
    heap_reserve: u32,
    heap_commit: u32,
    loader_flags: u32,
    directory_count: u32,

    comptime {
        assert(@sizeOf(OptionalHeader32) == 96);
    }
};

pub const DataDirectory = extern struct {
    rva: u32,
    size: u32,
};

pub const DirectoryIndex = enum(u32) {
    @"export" = 0,
    import = 1,
    resource = 2,
    exception = 3,
    security = 4,
    base_relocation = 5,
    debug = 6,
    architecture = 7,
    global_pointer = 8,
    tls = 9,
    load_config = 10,
    bound_import = 11,
    /// Import address table: the slots the loader writes resolved addresses into.
    iat = 12,
    delay_import = 13,
    clr = 14,
    _,
};

pub const SectionHeader = extern struct {
    name_bytes: [8]u8,
    virtual_size: u32,
    virtual_address: u32,
    raw_size: u32,
    raw_offset: u32,
    relocations_offset: u32,
    line_numbers_offset: u32,
    relocation_count: u16,
    line_number_count: u16,
    characteristics: Characteristics,

    /// Section names are 8 bytes, NUL-padded rather than NUL-terminated.
    pub fn name(header: *align(1) const SectionHeader) []const u8 {
        const end = std.mem.indexOfScalar(u8, &header.name_bytes, 0) orelse header.name_bytes.len;
        return header.name_bytes[0..end];
    }

    pub const Characteristics = packed struct(u32) {
        _reserved0: u3,
        no_pad: bool,
        _reserved1: u1,
        code: bool,
        initialized_data: bool,
        uninitialized_data: bool,
        link_other: bool,
        link_info: bool,
        _reserved2: u1,
        link_remove: bool,
        link_comdat: bool,
        _reserved3: u2,
        gp_relative: bool,
        _reserved4: u1,
        purgeable: bool,
        locked: bool,
        preload: bool,
        /// Byte alignment, as a power-of-two exponent plus one; zero means the default.
        alignment: u4,
        extended_relocations: bool,
        discardable: bool,
        not_cached: bool,
        not_paged: bool,
        shared: bool,
        execute: bool,
        read: bool,
        write: bool,
    };

    comptime {
        assert(@sizeOf(SectionHeader) == 40);
    }
};

pub const ImportDescriptor = extern struct {
    /// Import lookup table: what the file asks for. Zero in a bound-only descriptor.
    lookup_table_rva: u32,
    timestamp: u32,
    forwarder_chain: u32,
    name_rva: u32,
    /// Import address table: where resolved addresses land. Identical to the lookup table on disk
    /// unless the image was bound or, as here, rewritten by a protection layer.
    address_table_rva: u32,

    pub fn isTerminator(descriptor: *align(1) const ImportDescriptor) bool {
        return descriptor.name_rva == 0 and descriptor.lookup_table_rva == 0 and
            descriptor.address_table_rva == 0;
    }

    comptime {
        assert(@sizeOf(ImportDescriptor) == 20);
    }
};

pub const ParseError = error{
    NotPe,
    UnsupportedFormat,
    /// A header points outside the file.
    Truncated,
};

/// A PE image held in memory. Borrows `bytes`; `Image` never copies or frees them, so a tool that
/// wants to edit an image parses a mutable buffer and writes it back out itself.
pub const Image = struct {
    bytes: []u8,
    file_header: *align(1) FileHeader,
    optional_header: *align(1) OptionalHeader32,
    directories: []align(1) DataDirectory,
    sections: []align(1) SectionHeader,

    pub fn parse(bytes: []u8) ParseError!Image {
        if (bytes.len < @sizeOf(DosHeader)) return error.NotPe;
        const dos: *align(1) const DosHeader = @ptrCast(bytes[0..@sizeOf(DosHeader)]);
        if (!std.mem.eql(u8, &dos.magic, dos_magic)) return error.NotPe;

        const nt = dos.nt_offset;
        const file_header_offset = nt + nt_signature.len;
        if (bytes.len < file_header_offset + @sizeOf(FileHeader)) return error.Truncated;
        if (!std.mem.eql(u8, bytes[nt..][0..nt_signature.len], nt_signature)) return error.NotPe;

        const file_header: *align(1) FileHeader = @ptrCast(bytes[file_header_offset..][0..@sizeOf(FileHeader)]);
        const optional_offset = file_header_offset + @sizeOf(FileHeader);
        if (file_header.optional_header_size < @sizeOf(OptionalHeader32)) return error.UnsupportedFormat;
        if (bytes.len < optional_offset + file_header.optional_header_size) return error.Truncated;

        const optional_header: *align(1) OptionalHeader32 =
            @ptrCast(bytes[optional_offset..][0..@sizeOf(OptionalHeader32)]);
        if (optional_header.magic != .pe32) return error.UnsupportedFormat;

        // `@min` against a literal narrows the result type, so name the type the arithmetic needs.
        const directory_count: usize = @min(optional_header.directory_count, 16);
        const directories_offset = optional_offset + @sizeOf(OptionalHeader32);
        const directories_size = directory_count * @sizeOf(DataDirectory);
        if (bytes.len < directories_offset + directories_size) return error.Truncated;
        const directories: []align(1) DataDirectory =
            @alignCast(std.mem.bytesAsSlice(DataDirectory, bytes[directories_offset..][0..directories_size]));

        const sections_offset = optional_offset + file_header.optional_header_size;
        const sections_size = @as(usize, file_header.section_count) * @sizeOf(SectionHeader);
        if (bytes.len < sections_offset + sections_size) return error.Truncated;
        const sections: []align(1) SectionHeader =
            @alignCast(std.mem.bytesAsSlice(SectionHeader, bytes[sections_offset..][0..sections_size]));

        return .{
            .bytes = bytes,
            .file_header = file_header,
            .optional_header = optional_header,
            .directories = directories,
            .sections = sections,
        };
    }

    pub fn directory(image: Image, index: DirectoryIndex) ?DataDirectory {
        const i = @intFromEnum(index);
        if (i >= image.directories.len) return null;
        const entry = image.directories[i];
        return if (entry.rva == 0) null else entry;
    }

    pub fn sectionByName(image: Image, name: []const u8) ?*align(1) SectionHeader {
        for (image.sections) |*section| {
            if (std.mem.eql(u8, section.name(), name)) return section;
        }
        return null;
    }

    pub fn sectionContaining(image: Image, rva: u32) ?*align(1) SectionHeader {
        for (image.sections) |*section| {
            const size = @max(section.virtual_size, section.raw_size);
            if (rva >= section.virtual_address and rva - section.virtual_address < size) return section;
        }
        return null;
    }

    /// The bytes a section occupies in the file. Shorter than its virtual size when the section
    /// has a zero-filled tail that is not stored.
    pub fn sectionData(image: Image, section: *align(1) const SectionHeader) ![]u8 {
        const end = std.math.add(u32, section.raw_offset, section.raw_size) catch return error.Truncated;
        if (end > image.bytes.len) return error.Truncated;
        return image.bytes[section.raw_offset..end];
    }

    /// Translates a relative virtual address to a file offset.
    pub fn fileOffset(image: Image, rva: u32) ?u32 {
        const section = image.sectionContaining(rva) orelse return null;
        const delta = rva - section.virtual_address;
        if (delta >= section.raw_size) return null;
        return section.raw_offset + delta;
    }

    /// Reads a NUL-terminated string at `rva`.
    pub fn stringAt(image: Image, rva: u32) ?[]const u8 {
        const offset = image.fileOffset(rva) orelse return null;
        const rest = image.bytes[offset..];
        const end = std.mem.indexOfScalar(u8, rest, 0) orelse return null;
        return rest[0..end];
    }

    pub fn imports(image: Image) ?ImportIterator {
        const dir = image.directory(.import) orelse return null;
        const offset = image.fileOffset(dir.rva) orelse return null;
        return .{ .image = image, .offset = offset };
    }
};

pub const ImportIterator = struct {
    image: Image,
    offset: u32,

    pub const Entry = struct {
        descriptor: *align(1) const ImportDescriptor,
        name: []const u8,
    };

    pub fn next(iterator: *ImportIterator) ?Entry {
        const end = iterator.offset + @sizeOf(ImportDescriptor);
        if (end > iterator.image.bytes.len) return null;
        const descriptor: *align(1) const ImportDescriptor =
            @ptrCast(iterator.image.bytes[iterator.offset..][0..@sizeOf(ImportDescriptor)]);
        if (descriptor.isTerminator()) return null;
        iterator.offset = end;
        return .{
            .descriptor = descriptor,
            .name = iterator.image.stringAt(descriptor.name_rva) orelse "",
        };
    }
};

test "parses a minimal image" {
    var bytes: [1024]u8 = @splat(0);
    const dos: *align(1) DosHeader = @ptrCast(bytes[0..@sizeOf(DosHeader)]);
    dos.magic = dos_magic.*;
    dos.nt_offset = 0x80;
    bytes[0x80..][0..4].* = nt_signature.*;

    const file_header: *align(1) FileHeader = @ptrCast(bytes[0x84..][0..@sizeOf(FileHeader)]);
    file_header.* = .{
        .machine = .i386,
        .section_count = 1,
        .timestamp = 0,
        .symbol_table_offset = 0,
        .symbol_count = 0,
        .optional_header_size = @sizeOf(OptionalHeader32) + 16 * @sizeOf(DataDirectory),
        .characteristics = @bitCast(@as(u16, 0x010E)),
    };
    const optional: *align(1) OptionalHeader32 = @ptrCast(bytes[0x98..][0..@sizeOf(OptionalHeader32)]);
    optional.magic = .pe32;
    optional.image_base = 0x400000;
    optional.entry_point = 0x1000;
    optional.directory_count = 16;

    const sections_offset = 0x98 + @sizeOf(OptionalHeader32) + 16 * @sizeOf(DataDirectory);
    const section: *align(1) SectionHeader = @ptrCast(bytes[sections_offset..][0..@sizeOf(SectionHeader)]);
    section.* = std.mem.zeroes(SectionHeader);
    section.name_bytes = ".text\x00\x00\x00".*;
    section.virtual_address = 0x1000;
    section.virtual_size = 0x40;
    section.raw_offset = 0x200;
    section.raw_size = 0x40;
    @memcpy(bytes[0x200..][0..5], "hello");

    const image: Image = try .parse(&bytes);
    try std.testing.expectEqual(Machine.i386, image.file_header.machine);
    try std.testing.expectEqual(@as(u32, 0x400000), image.optional_header.image_base);
    try std.testing.expectEqual(@as(usize, 1), image.sections.len);

    const text = image.sectionByName(".text").?;
    try std.testing.expectEqualStrings(".text", text.name());
    try std.testing.expectEqualSlices(u8, "hello", (try image.sectionData(text))[0..5]);
    try std.testing.expectEqual(@as(?u32, 0x205), image.fileOffset(0x1005));
    try std.testing.expectEqual(@as(?*align(1) SectionHeader, null), image.sectionContaining(0x9999));
    try std.testing.expectEqual(@as(?DataDirectory, null), image.directory(.import));
}

test "rejects non-PE input" {
    var bytes: [64]u8 = @splat(0);
    try std.testing.expectError(error.NotPe, Image.parse(&bytes));
    try std.testing.expectError(error.NotPe, Image.parse(bytes[0..8]));
}
