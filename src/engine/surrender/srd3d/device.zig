//! The parts of Direct3D 7 the driver uses (`IDirect3DDevice7`), as the port provides them: a
//! device that draws transformed, lit vertices with the states `set_material` and `set_depth`
//! choose. `software.zig` draws them as Direct3D 7 rasterizes; the executable's device draws them
//! with SDL's GPU interface.

const std = @import("std");

const math = @import("../math.zig");
const srd3d = @import("srd3d.zig");
const srtexture = @import("../surrenderlib/srtexture.zig");

/// A vertex as the driver hands it over (`D3DFVF_XYZRHW | D3DFVF_DIFFUSE | D3DFVF_SPECULAR |
/// D3DFVF_TEX1`, `0x1C4`): on the screen, with pixel centres at whole numbers, as Direct3D 7 has
/// them.
pub const Vertex = extern struct {
    x: f32,
    y: f32,
    /// Depth: nearer is greater.
    z: f32,
    /// One over the depth, scaled; texture coordinates and colours are interpolated by it.
    rhw: f32,
    /// Alpha, red, green and blue, from the top byte down.
    diffuse: u32,
    specular: u32 = 0,
    u: f32 = 0,
    v: f32 = 0,

    comptime {
        std.debug.assert(@sizeOf(Vertex) == 32);
    }
};

/// Packs a colour as the driver does: each channel times 255, rounded, alpha at the top.
pub fn pack(colour: [4]f32) u32 {
    return (@as(u32, channel(colour[3])) << 24) | (@as(u32, channel(colour[0])) << 16) |
        (@as(u32, channel(colour[1])) << 8) | channel(colour[2]);
}

fn channel(c: f32) u8 {
    return std.math.lossyCast(u8, math.roundEven(c * 255));
}

pub const white: u32 = 0xFFFF_FFFF;

/// The primitives the driver draws (`D3DPRIMITIVETYPE`).
pub const Primitive = enum {
    points,
    lines,
    triangles,
    strip,
    fan,
};

/// The render states for a draw: the texture, modulated by the diffuse colour, or the diffuse colour
/// alone without one; the depth test and writes; and the blend factors, or none for blending off.
pub const State = struct {
    texture: ?*srtexture.Image,
    depth: srd3d.Depth,
    blend: ?srd3d.Factors,
};

pub const Device = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Clears to black and to depth 0 (`Clear`), and begins the scene.
        begin: *const fn (*anyopaque) void,
        end: *const fn (*anyopaque) void,
        /// Draws `vertices`, or those `indices` pick, as `primitive` (`DrawPrimitive`,
        /// `DrawIndexedPrimitive`).
        draw: *const fn (*anyopaque, State, Primitive, []const Vertex, ?[]const u16) void,
    };

    pub fn begin(device: Device) void {
        device.vtable.begin(device.ptr);
    }

    pub fn end(device: Device) void {
        device.vtable.end(device.ptr);
    }

    pub fn draw(device: Device, state: State, primitive: Primitive, vertices: []const Vertex, indices: ?[]const u16) void {
        device.vtable.draw(device.ptr, state, primitive, vertices, indices);
    }
};

test pack {
    try std.testing.expectEqual(0xFF804000, pack(.{ 0.5, 0.25, 0, 1 }));
    try std.testing.expectEqual(white, pack(.{ 1, 1, 1, 1 }));
}
