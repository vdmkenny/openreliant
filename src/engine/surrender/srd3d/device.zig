//! The parts of Direct3D 7 the driver uses (`IDirect3DDevice7`), as the port provides them: a
//! device that draws transformed, lit vertices with the states `set_material` and `set_depth`
//! choose. `software.zig` draws them as Direct3D 7 rasterizes; the executable's device draws them
//! with SDL's GPU interface.

const std = @import("std");

const math = @import("../math.zig");
const srd3d = @import("srd3d.zig");
const srshadow = @import("../surrenderlib/srshadow.zig");
const srtexture = @import("../surrenderlib/srtexture.zig");

/// A vertex as the driver hands it over (`D3DFVF_XYZRHW | D3DFVF_DIFFUSE | D3DFVF_SPECULAR |
/// D3DFVF_TEX1`, `0x1C4`): on the screen, with pixel centres at whole numbers, as Direct3D 7 has
/// them. The fields after `v` are the port's, for a device that lights each pixel (`lights`).
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
    /// Where the vertex stands in the camera's frame, and its normal there.
    view: [3]f32 = .{ 0, 0, 0 },
    normal: [3]f32 = .{ 0, 0, 0 },
    /// The lights that don't reach it, as its object's light mask (`srlight.Light.reaches`). All
    /// ones, as for everything but a lit mesh, when the device lights none of its pixels:
    /// `diffuse` is then its whole colour.
    light_mask: u32 = no_lights,

    comptime {
        std.debug.assert(@sizeOf(Vertex) == 60);
    }
};

/// A vertex's light mask when no light reaches it.
pub const no_lights: u32 = std.math.maxInt(u32);

/// A directional or point light as a device that lights each pixel takes it (`Device.lights`), in
/// the camera's frame. It reaches a vertex whose light mask shares no bit with `mask`, and adds to
/// the vertex's colour what `srmesh` would add to it, for each pixel instead of each vertex.
pub const Light = struct {
    mask: u32,
    kind: Kind,
    /// Kept off what a caster shades from it, for a device that draws shadows.
    shadowed: bool = false,

    pub const Kind = union(enum) {
        /// `colour` times the dot product of the pixel's normal with `toward`, where that is
        /// positive. `toward` points at the light and is as long as its intensity.
        directional: struct { toward: [3]f32, colour: [3]f32 },
        /// `colour` times `intensity`, times `(1 - r / reach)²` and the cosine of the angle
        /// between the normal and the light, for a pixel `r` from `position` and within `reach`.
        point: struct { position: [3]f32, reach: f32, colour: [3]f32, intensity: f32 },
    };
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
    /// The port's: the shadows the draw's lit pixels are looked up in, for a device that draws
    /// them.
    receives: Receives = .nothing,
};

/// Which shadows a draw's pixels take, which the layer sets: none, the world's cascades, or the
/// cockpit's map (`srshadow`).
pub const Receives = enum(u32) {
    nothing = 0,
    world = 1,
    cockpit = 2,
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
        /// Marks where the scene ends and what is drawn over it begins. The game drew its display
        /// straight over the finished frame, so a device that adds anything to the frame of its
        /// own, as the GPU's bloom does, leaves out what follows this.
        overlay: *const fn (*anyopaque) void,
        /// The port's: takes the frame's directional and point lights, most wanted first, and
        /// returns how many of them, from the first, it adds to each pixel. The driver lights
        /// the vertices with the rest. A device without it lights nothing itself, and the
        /// driver's vertices come lit, as Direct3D 7's did.
        lights: ?*const fn (*anyopaque, []const Light) usize = null,
        /// The port's: how it draws shadows, or null where it draws none. A device without it
        /// draws none.
        shadow_settings: ?*const fn (*anyopaque) ?srshadow.Settings = null,
        /// The port's: the frame's shadows, after its lights, which last until the scene ends.
        shadows: ?*const fn (*anyopaque, *const srshadow.Frame) void = null,
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

    pub fn overlay(device: Device) void {
        device.vtable.overlay(device.ptr);
    }

    /// Hands the device the frame's lights, most wanted first, and returns how many of them it
    /// adds to each pixel.
    pub fn lights(device: Device, list: []const Light) usize {
        const take = device.vtable.lights orelse return 0;
        return take(device.ptr, list);
    }

    /// How the device draws shadows, or null where it draws none.
    pub fn shadowSettings(device: Device) ?srshadow.Settings {
        const settings = device.vtable.shadow_settings orelse return null;
        return settings(device.ptr);
    }

    /// Hands the device the frame's shadows.
    pub fn shadows(device: Device, frame: *const srshadow.Frame) void {
        const take = device.vtable.shadows orelse return;
        take(device.ptr, frame);
    }
};

test pack {
    try std.testing.expectEqual(0xFF804000, pack(.{ 0.5, 0.25, 0, 1 }));
    try std.testing.expectEqual(white, pack(.{ 1, 1, 1, 1 }));
}
