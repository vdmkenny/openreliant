//! `C:\lancer\surrender\surrenderlib\srstars.cpp`: star fields, scene objects of type 7. The driver
//! draws each visible star as a point, or as a line back to where it was last frame when that is
//! more than a pixel away, the tail at half brightness.

const std = @import("std");
const assert = std.debug.assert;

const lancer = @import("../../../lancer.zig");
const Pointer = lancer.Pointer;
const shp = @import("../../../formats/shp.zig");
const srapiext = @import("srapiext.zig");

/// A star field (`stars_create`, `0x004C5240`): its stars' positions and colours, and what
/// `stars_project` (`0x004C5380`) makes of them each frame.
pub const Stars = extern struct {
    object: srapiext.Frame,
    /// Its depth key while in a layer's list of blended objects.
    sort_key: u32,
    /// `material`.
    drawn: Pointer(srapiext.Material),
    /// The next in a layer's list of blended objects.
    blended_next: Pointer(Stars),
    /// The object itself.
    self: Pointer(Stars),
    kind: Kind,
    /// Dust: the field's offset from the camera last frame.
    previous_offset: shp.Vec3,
    /// The rotation into the camera's frame last frame.
    previous_rotation: [9]f32,
    /// Untextured, lit and added: each star takes its own colour.
    material: srapiext.Material,
    count: u32,
    /// Stars drawn this frame, listed in `visible_indices`.
    visible: u32,
    /// Four floats a star. Sky: `(x, y, 1)` in the field's frame. Dust: within the cube.
    positions: Pointer(f32),
    /// Four floats a star: red, green and blue at `[1]` to `[3]`.
    colours: Pointer(f32),
    /// One a visible star.
    brightness: Pointer(f32),
    /// Two floats a visible star: its position over its depth, this frame and last.
    screen: Pointer(f32),
    previous_screen: Pointer(f32),
    visible_indices: Pointer(u16),
    /// Dust: the cube's side less one. Positions wrap by masking with it.
    cube_mask: u32,
    /// `2000.0`. **Unknown.**
    _unknown_12c: f32,

    pub const Kind = enum(u32) {
        /// At infinity: only the camera's rotation moves it.
        sky = 0,
        /// A cube of motes around the camera, wrapping as it moves.
        dust = 1,
        _,
    };

    comptime {
        assert(@offsetOf(Stars, "kind") == 0xC4);
        assert(@offsetOf(Stars, "material") == 0xF8);
        assert(@offsetOf(Stars, "count") == 0x108);
        assert(@sizeOf(Stars) == 0x130);
    }
};

/// A sky field is drawn only while its axis is within this cosine of the view axis, or of its
/// opposite. A field behind the camera is drawn mirrored through it, so each field also covers the
/// opposite part of the sky.
pub const field_cosine: f32 = 0.6;

pub const FieldView = enum { hidden, ahead, mirrored };

/// How a sky field is drawn, for the cosine of its axis with the view axis.
pub fn fieldView(cosine: f32) FieldView {
    if (@abs(cosine) < field_cosine) return .hidden;
    return if (cosine > 0) .ahead else .mirrored;
}

/// A sky star is drawn only while its direction is within the first cosine of the view axis this
/// frame and last, and within the second in at least one of them.
pub const star_cosines = [2]f64{ 0.6, 0.7 };

/// Whether a sky star is drawn, for the cosines of its direction with the view axis this frame and
/// last.
pub fn starShown(now: f32, last: f32) bool {
    return @min(now, last) >= star_cosines[0] and @max(now, last) >= star_cosines[1];
}

/// Longest streak, in view units: a star's screen position over its depth, before scaling to the
/// viewport. A longer one is cut back along its line.
pub const streak_limit: f32 = 0.1;

/// A sky star's brightness, for `motion`, `|dx| + |dy|` in view units since last frame.
pub fn skyBrightness(motion: f32) f32 {
    return std.math.clamp(1 / (motion * 100 + 1), 0, 1);
}

/// A dust mote's brightness at `distance_squared` from the camera: full nearby, gone by half the
/// cube's side.
pub fn dustBrightness(distance_squared: f32, cube_mask: u32, motion: f32) f32 {
    const side: f32 = @floatFromInt(cube_mask);
    return std.math.clamp((0.25 - distance_squared / (side * side)) * 16 / (motion * 100 + 1), 0, 1);
}

test fieldView {
    try std.testing.expectEqual(FieldView.ahead, fieldView(0.9));
    try std.testing.expectEqual(FieldView.mirrored, fieldView(-0.9));
    try std.testing.expectEqual(FieldView.hidden, fieldView(0.3));
    try std.testing.expectEqual(FieldView.hidden, fieldView(-0.5));
}

test starShown {
    // A still camera: both frames alike, so within the second cosine.
    try std.testing.expect(starShown(0.75, 0.75));
    try std.testing.expect(!starShown(0.65, 0.65));
    // Moving: within the first both times and the second once.
    try std.testing.expect(starShown(0.65, 0.8));
    try std.testing.expect(!starShown(0.5, 0.9));
}

test skyBrightness {
    try std.testing.expectEqual(1, skyBrightness(0));
    try std.testing.expectApproxEqAbs(0.5, skyBrightness(0.01), 1e-6);
    try std.testing.expectApproxEqAbs(1.0 / 11.0, skyBrightness(streak_limit), 1e-6);
}

test dustBrightness {
    const cube = 0x1FFF;
    try std.testing.expectEqual(1, dustBrightness(0, cube, 0));
    try std.testing.expectEqual(0, dustBrightness(4096 * 4096, cube, 0));
    // Full out to where 16 * (0.25 - d^2 / side^2) falls to 1.
    try std.testing.expectEqual(1, dustBrightness(3500 * 3500, cube, 0));
    try std.testing.expect(dustBrightness(3800 * 3800, cube, 0) < 1);
}
