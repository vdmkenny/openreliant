//! The platform the port runs on, in place of Win32 and DirectX: SDL3. Nothing here is the
//! game's; the game's code in `openreliant` reaches the platform only through what this exposes.

const std = @import("std");

pub const gpu = @import("platform/gpu.zig");
pub const keyboard = @import("platform/keyboard.zig");
pub const window = @import("platform/window.zig");

test {
    std.testing.refAllDecls(@This());
}
