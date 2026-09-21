//! The `openreliant` module: readers for the game's file formats, and the payload's own structures and
//! tables, shared by every tool in this repository and, eventually, by the engine reimplementation.

/// Containers the game shipped in, rather than formats the game itself reads.
pub const cdimage = @import("formats/cdimage.zig");
pub const iso9660 = @import("formats/iso9660.zig");

/// The game's files.
pub const dte = @import("formats/dte.zig");
pub const fat = @import("formats/fat.zig");
pub const fnt = @import("formats/fnt.zig");
pub const hog = @import("formats/hog.zig");
pub const refpack = @import("formats/refpack.zig");
pub const shp = @import("formats/shp.zig");
pub const spr = @import("formats/spr.zig");
pub const stats = @import("formats/stats.zig");
pub const tcache = @import("formats/tcache.zig");
pub const tga = @import("formats/tga.zig");

/// Windows executables: the game binary and the protection wrapped around it.
pub const pe = @import("formats/pe.zig");
pub const safedisc = @import("formats/safedisc.zig");
pub const tea = @import("formats/tea.zig");

/// Images the tools write.
pub const png = @import("formats/png.zig");

/// The payload, the game executable: its structures and tables, laid out as its source tree.
pub const lancer = @import("lancer.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
