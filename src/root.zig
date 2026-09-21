//! The `starlancer` module: readers for the game's file formats, shared by every tool in this
//! repository and, eventually, by the engine reimplementation.

/// Containers the game shipped in, rather than formats the game itself reads.
pub const cdimage = @import("formats/cdimage.zig");
/// The player's actions and the bindings the game starts with, transcribed from the executable.
pub const controls = @import("formats/controls.zig");
pub const dte = @import("formats/dte.zig");
pub const fat = @import("formats/fat.zig");
pub const fnt = @import("formats/fnt.zig");
pub const hog = @import("formats/hog.zig");
pub const iso9660 = @import("formats/iso9660.zig");
/// The combat maneuvers the Fight order runs, transcribed from the game executable, and the
/// language of their scripts.
pub const maneuvers = @import("formats/maneuvers.zig");
pub const maneuver_script = @import("formats/maneuver_script.zig");
/// The models the engine loads by number, transcribed from the game executable.
pub const models = @import("formats/models.zig");
/// The orders objects follow, transcribed from the game executable.
pub const orders = @import("formats/orders.zig");
pub const refpack = @import("formats/refpack.zig");
pub const shp = @import("formats/shp.zig");
pub const spr = @import("formats/spr.zig");
pub const stats = @import("formats/stats.zig");

/// Windows executables: the game binary and the protection wrapped around it.
pub const pe = @import("formats/pe.zig");
pub const png = @import("formats/png.zig");
pub const safedisc = @import("formats/safedisc.zig");
pub const tea = @import("formats/tea.zig");

/// The game executable's own run-time structures.
pub const lancer = @import("lancer.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
