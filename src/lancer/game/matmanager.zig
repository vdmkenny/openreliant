//! `C:\lancer\game\matmanager.cpp`: the game's side of looking up textures.

const std = @import("std");
const Allocator = std.mem.Allocator;

const srtexture = @import("../surrender/surrenderlib/srtexture.zig");

const log = std.log.scoped(.matmanager);

pub const Error = Allocator.Error || error{ImageMissing};

/// The texture of that name, which must exist (`texture_require`, `0x00494A30`): on a miss the game
/// stops with `Could not find image %s`, and this logs that and fails.
pub fn textureRequire(table: *srtexture.Table, name: []const u8) Error!*srtexture.Image {
    return try table.find(name) orelse {
        log.err("Could not find image {s}", .{name});
        return error.ImageMissing;
    };
}
