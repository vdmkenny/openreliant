//! RIFF, the container of the game's WAVE sounds (`wave.zig`) and its force-feedback effects
//! (`frc.zig`): a header naming the form, then chunks, each an id, a length and that many bytes,
//! padded to an even length. A `LIST` chunk holds a form of its own, then chunks.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const layout = @import("layout.zig");

pub const Error = error{Truncated};

/// What a form, and a list's, takes: four characters.
pub const form_len = 4;

/// A list chunk's id.
pub const list_id = "LIST";

/// The file's header: `RIFF`, the length of what follows, and the form, such as `WAVE`.
pub const Header = extern struct {
    id: [4]u8,
    /// The form and the chunks after it.
    size: u32,
    form: [form_len]u8,

    pub const riff_id = "RIFF";

    comptime {
        assert(@sizeOf(Header) == 12);
    }
};

/// What starts each chunk: its id and its length, which leaves out the padding to an even length.
pub const ChunkHeader = extern struct {
    id: [4]u8,
    size: u32,

    /// The chunk's length with its padding.
    pub fn paddedSize(chunk: ChunkHeader) usize {
        return @as(usize, chunk.size) + (chunk.size & 1);
    }

    comptime {
        assert(@sizeOf(ChunkHeader) == 8);
    }
};

pub const Chunk = struct {
    id: [4]u8,
    body: []const u8,
};

/// The header of `bytes` where it is a RIFF file of `form`; null for anything else.
pub fn header(bytes: []const u8, form: *const [form_len]u8) ?*align(1) const Header {
    const riff = layout.view(Header, bytes) catch return null;
    if (!std.mem.eql(u8, &riff.id, Header.riff_id) or !std.mem.eql(u8, &riff.form, form)) return null;
    return riff;
}

/// Walks chunks, a chunk at a time.
pub const Chunks = struct {
    rest: []const u8,
    /// Whether the chunks of each list are walked in its place, rather than the list returned as
    /// one chunk.
    into_lists: bool = false,

    /// The next chunk, or null once no bytes are left. A header or a body that runs past the end
    /// is an error; a missing pad byte after the last chunk is not.
    pub fn next(chunks: *Chunks) Error!?Chunk {
        while (chunks.rest.len > 0) {
            const chunk = try layout.view(ChunkHeader, chunks.rest);
            const after = chunks.rest[@sizeOf(ChunkHeader)..];
            if (chunk.size > after.len) return error.Truncated;
            if (chunks.into_lists and std.mem.eql(u8, &chunk.id, list_id)) {
                if (chunk.size < form_len) return error.Truncated;
                chunks.rest = after[form_len..];
                continue;
            }
            chunks.rest = after[@min(after.len, chunk.paddedSize())..];
            return .{ .id = chunk.id, .body = after[0..chunk.size] };
        }
        return null;
    }
};

/// Builds RIFF files, for tests.
pub const testing = struct {
    /// A chunk of `body`, with its header and its padding.
    pub fn chunk(comptime id: *const [4]u8, comptime body: []const u8) []const u8 {
        const padding = if (body.len % 2 == 1) "\x00" else "";
        return std.mem.toBytes(ChunkHeader{ .id = id.*, .size = body.len }) ++ body ++ padding;
    }

    /// Appends a chunk of `body`, with its header and its padding, to `out`.
    pub fn appendChunk(gpa: Allocator, out: *std.ArrayList(u8), id: *const [4]u8, body: []const u8) Allocator.Error!void {
        try out.appendSlice(gpa, std.mem.asBytes(&ChunkHeader{ .id = id.*, .size = @intCast(body.len) }));
        try out.appendSlice(gpa, body);
        if (body.len % 2 == 1) try out.append(gpa, 0);
    }
};

test header {
    const file = comptime testing.chunk(Header.riff_id, "WAVE" ++ testing.chunk("data", "abc"));
    try std.testing.expectEqual(4 + 8 + 4, header(file, "WAVE").?.size);
    try std.testing.expectEqual(null, header(file, "FORC"));
    try std.testing.expectEqual(null, header("RIFF\x04\x00\x00\x00", "WAVE"));
    try std.testing.expectEqual(null, header("LIST\x04\x00\x00\x00WAVE", "WAVE"));
}

test Chunks {
    // A chunk of odd length and its pad byte, a list of one chunk, then the last chunk without the
    // pad byte its odd length asks for.
    const bytes = comptime testing.chunk("id  ", "odd") ++ testing.chunk(list_id, "efct" ++ testing.chunk("data", "ab")) ++ "last\x01\x00\x00\x00x";

    var flat: Chunks = .{ .rest = bytes, .into_lists = true };
    try std.testing.expectEqualStrings("odd", (try flat.next()).?.body);
    const data = (try flat.next()).?;
    try std.testing.expectEqualStrings("data", &data.id);
    try std.testing.expectEqualStrings("ab", data.body);
    try std.testing.expectEqualStrings("x", (try flat.next()).?.body);
    try std.testing.expectEqual(null, try flat.next());

    // Without going into lists, the list is one chunk.
    var nested: Chunks = .{ .rest = bytes };
    _ = try nested.next();
    try std.testing.expectEqualStrings(list_id, &(try nested.next()).?.id);

    // A body past the end, and a header cut short.
    var long: Chunks = .{ .rest = "data\x09\x00\x00\x00abc" };
    try std.testing.expectError(error.Truncated, long.next());
    var short: Chunks = .{ .rest = "data" };
    try std.testing.expectError(error.Truncated, short.next());
}
