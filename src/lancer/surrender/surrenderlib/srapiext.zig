//! `C:\lancer\surrender\surrenderlib\srAPIext.cpp`: Surrender's frames, the transforms of its scene
//! graph.

const std = @import("std");
const assert = std.debug.assert;

const lancer = @import("../../../lancer.zig");
const Pointer = lancer.Pointer;
const shp = @import("../../../formats/shp.zig");

/// Surrender's transform (`surrenderlib`), `0xB4` bytes, which `frame_create` (`0x004C51C0`)
/// allocates: a node's place relative to its parent frame.
pub const Frame = extern struct {
    _unknown_00: u32,
    /// Such as `GOroot object` for an object's root.
    name: Pointer(u8),
    _unknown_08: [8]u8,
    parent: Pointer(Frame),
    /// **Unknown**, mostly.
    flags: u32,
    /// Row-major 3x3.
    orientation: [9]f32,
    position: shp.Vec3,
    /// **Unknown.** 1.0 when created.
    _unknown_48: f32,
    _unknown_4c: [0x68]u8,

    comptime {
        assert(@offsetOf(Frame, "orientation") == 0x18);
        assert(@offsetOf(Frame, "position") == 0x3C);
        assert(@sizeOf(Frame) == 0xB4);
    }
};

test {
    std.testing.refAllDecls(@This());
}
