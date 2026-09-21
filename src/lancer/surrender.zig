//! `C:\lancer\surrender`: the Surrender renderer's sources linked into the payload.

const std = @import("std");

pub const surrenderlib = @import("surrender/surrenderlib.zig");

test {
    std.testing.refAllDecls(@This());
}
