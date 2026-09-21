//! `C:\lancer\surrender\surrenderlib\srAPIext.cpp`: Surrender's frames, the transforms of its scene
//! graph, and its meshes' materials.

const std = @import("std");
const assert = std.debug.assert;

const lancer = @import("../../../lancer.zig");
const Pointer = lancer.Pointer;
const shp = @import("../../../formats/shp.zig");
const tcache = @import("../../../formats/tcache.zig");

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

/// How a group of a mesh's polygons is drawn: a first pass and, with `two_pass`, a second over it.
/// Each field but `two_pass` holds one value per pass. A mesh (`mesh_create`, `0x004C4440`) holds a
/// `Group` for each run of polygons, from `+0x64`; the Direct3D driver reads the material as is.
pub const Material = extern struct {
    two_pass: bool,
    _unknown_01: u8,
    /// Where the texture coordinates come from; `none` draws untextured.
    coordinates: [2]Coordinates,
    /// Colour by the vertex lighting, else by white.
    lit: [2]bool,
    blend: [2]Blend,
    /// The texture. Below 8, one of the Direct3D driver's highlight textures.
    image: [2]Pointer(tcache.Image),

    pub const Coordinates = enum(u8) {
        none = 0,
        /// The mesh's own.
        mesh = 1,
        /// Made each frame from the vertex normals, turned into the camera's frame: `u` is
        /// `0.5 + 0.5 * x`, `v` is `0.5 + 0.5 * y`.
        normals = 2,
        _,
    };

    /// How a pass combines with what is already drawn. Blended polygons are drawn after the rest
    /// of their layer, back to front.
    pub const Blend = enum(u8) {
        /// Replaces it.
        off = 0,
        /// Adds to it.
        add = 1,
        /// Adds to it, scaled by one minus the source alpha.
        premultiplied = 2,
        /// Mixes by the source alpha.
        alpha = 3,
        /// Adds, scaled by the source alpha.
        add_alpha = 4,
        _,
    };

    comptime {
        assert(@offsetOf(Material, "blend") == 6);
        assert(@sizeOf(Material) == 0x10);
    }
};

/// A run of a mesh's polygons with one material.
pub const Group = extern struct {
    polygons: u32,
    material: Material,

    comptime {
        assert(@sizeOf(Group) == 0x14);
    }
};

test {
    std.testing.refAllDecls(@This());
}
