//! `C:\lancer\surrender\surrenderlib`: the Surrender library, a module for each file this project
//! describes.

const std = @import("std");

pub const srapiext = @import("surrenderlib/srapiext.zig");
pub const srlight = @import("surrenderlib/srlight.zig");
pub const srmesh = @import("surrenderlib/srmesh.zig");
pub const srstars = @import("surrenderlib/srstars.zig");

test {
    std.testing.refAllDecls(@This());
}
