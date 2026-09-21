//! A software renderer that draws a scene by the engine's rules, as the modules under `lancer/`
//! state them: the reference the port's GPU renderer is checked against.

const std = @import("std");

pub const backdrop = @import("render/backdrop.zig");
pub const model = @import("render/model.zig");
pub const raster = @import("render/raster.zig");
pub const scene = @import("render/scene.zig");
pub const texture = @import("render/texture.zig");

test {
    std.testing.refAllDecls(@This());
}
