//! The `starlancer` module: readers for the game's file formats, shared by every tool in this
//! repository and, eventually, by the engine reimplementation.

/// Containers the game shipped in, rather than formats the game itself reads.
pub const cdimage = @import("formats/cdimage.zig");
pub const hog = @import("formats/hog.zig");
pub const iso9660 = @import("formats/iso9660.zig");
pub const refpack = @import("formats/refpack.zig");
pub const shp = @import("formats/shp.zig");

/// Windows executables: the game binary and the protection wrapped around it.
pub const pe = @import("formats/pe.zig");
pub const safedisc = @import("formats/safedisc.zig");
pub const tea = @import("formats/tea.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
