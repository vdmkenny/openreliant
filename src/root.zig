//! The `starlancer` module: readers for the game's file formats, shared by every tool in this
//! repository and, eventually, by the engine reimplementation.

/// Containers the game shipped in, rather than formats the game itself reads.
pub const cdimage = @import("formats/cdimage.zig");
pub const iso9660 = @import("formats/iso9660.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
