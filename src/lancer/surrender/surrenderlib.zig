//! `C:\lancer\surrender\surrenderlib`: the Surrender library, a module for each file this project
//! describes.

const std = @import("std");

pub const srapiext = @import("surrenderlib/srapiext.zig");

test {
    std.testing.refAllDecls(@This());
}
