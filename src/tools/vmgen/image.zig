//! Reads the payload executable's memory by virtual address.

const std = @import("std");

const starlancer = @import("starlancer");
const pe = starlancer.pe;

pub const Error = error{ OutOfImage, BadString };

pub const Reader = struct {
    image: pe.Image,
    bytes: []const u8,
    base: u32,

    pub fn init(image: pe.Image, bytes: []const u8) Reader {
        return .{ .image = image, .bytes = bytes, .base = image.optional_header.image_base };
    }

    pub fn slice(reader: Reader, va: u32, len: usize) Error![]const u8 {
        if (va < reader.base) return error.OutOfImage;
        const offset = reader.image.fileOffset(va - reader.base) orelse return error.OutOfImage;
        if (offset + len > reader.bytes.len) return error.OutOfImage;
        return reader.bytes[offset..][0..len];
    }

    pub fn int(reader: Reader, comptime T: type, va: u32) Error!T {
        return std.mem.readInt(T, (try reader.slice(va, @sizeOf(T)))[0..@sizeOf(T)], .little);
    }

    pub fn word(reader: Reader, va: u32) Error!u32 {
        return reader.int(u32, va);
    }

    /// A NUL-terminated string of printable ASCII at `va`, or empty for a null pointer.
    pub fn string(reader: Reader, va: u32) Error![]const u8 {
        if (va == 0) return "";
        if (va < reader.base) return error.BadString;
        const offset = reader.image.fileOffset(va - reader.base) orelse return error.BadString;
        const rest = reader.bytes[offset..];
        const end = std.mem.indexOfScalar(u8, rest, 0) orelse return error.BadString;
        for (rest[0..end]) |c| if (c < 0x20 or c > 0x7E) return error.BadString;
        return rest[0..end];
    }
};
