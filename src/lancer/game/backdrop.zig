//! The space backdrop: the star fields, the dust, the sun and its flares, and the lights every
//! mission starts with. `backdrop_create` (`0x004A4E70`) builds them once, `backdrop_place`
//! (`0x004A5A00`) aims them from a mission's markers and `backdrop_frame` (`0x004A5CD0`) adds them to
//! the scene each frame. The binary does not name the file; its code lies between `srofiles.cpp`'s
//! and `timer.cpp`'s. [`nebula.zig`](nebula.zig) has the sky dome and the nebula.

const std = @import("std");
const Allocator = std.mem.Allocator;

const tga = @import("../../formats/tga.zig");
const math = @import("../surrender/math.zig");
const srlight = @import("../surrender/surrenderlib/srlight.zig");

/// The star map, in `resource.hog`: grey pixels on black, one star each.
pub const star_map_name = "space.tga";

/// The star map's side, in pixels. It spans half the sky, half a degree to a pixel.
pub const star_map_size = 360;

/// Radians to a star-map pixel, and to a unit of the field angles below: half a degree.
pub const half_degree: f32 = std.math.pi / 360.0;

/// A field is a 36-pixel square of the map, 18 degrees across.
pub const field_size = 36;
pub const fields_per_side = star_map_size / field_size;
pub const field_count = fields_per_side * fields_per_side;

pub const Star = struct {
    /// In the field's frame: `(sin(dx), sin(dy), 1)`, with `dx` and `dy` the pixel's angles from
    /// the field's centre.
    position: [3]f32,
    /// The pixel's colour.
    colour: [3]u8,
};

pub const Field = struct {
    /// Where the field is centred: its frame's forward axis.
    axis: [3]f32,
    /// The field's frame, turned to face `axis` (`mat3_look_at`, `0x004C1940`).
    orientation: math.Matrix,
    stars: []const Star,
};

/// Field `row`, `column`'s axis: the polar angle, from `+Y`, follows the map's rows and the azimuth,
/// from `+X` toward `+Z`, its columns, so the fields cover the half of the sky where `z` is positive.
pub fn fieldAxis(row: usize, column: usize) [3]f32 {
    const polar = @as(f32, @floatFromInt(row * field_size + field_size / 2)) * half_degree;
    const azimuth = @as(f32, @floatFromInt(column * field_size + field_size / 2)) * half_degree;
    return .{ @cos(azimuth) * @sin(polar), @cos(polar), @sin(azimuth) * @sin(polar) };
}

/// The fields `backdrop_create` builds from the star map, in its order: by rows of fields, then
/// columns, and within a field by rows of pixels. Every pixel that is not black is a star.
pub fn fields(gpa: Allocator, map: tga.Image) (error{WrongSize} || Allocator.Error)![field_count]Field {
    if (map.width != star_map_size or map.height != star_map_size) return error.WrongSize;
    var result: [field_count]Field = undefined;
    var made: usize = 0;
    errdefer for (result[0..made]) |field| gpa.free(field.stars);
    for (0..fields_per_side) |row| {
        for (0..fields_per_side) |column| {
            var stars: std.ArrayList(Star) = .empty;
            errdefer stars.deinit(gpa);
            for (0..field_size) |y| {
                for (0..field_size) |x| {
                    const colour = map.pixel(column * field_size + x, row * field_size + y);
                    if (std.mem.allEqual(u8, &colour, 0)) continue;
                    try stars.append(gpa, .{ .position = .{ offsetSine(x), offsetSine(y), 1 }, .colour = colour });
                }
            }
            const axis = fieldAxis(row, column);
            result[made] = .{ .axis = axis, .orientation = math.lookAt(axis), .stars = try stars.toOwnedSlice(gpa) };
            made += 1;
        }
    }
    return result;
}

fn offsetSine(pixel: usize) f32 {
    const offset: f32 = @as(f32, @floatFromInt(pixel)) - field_size / 2;
    return @sin(offset * half_degree);
}

pub fn freeFields(gpa: Allocator, all: *const [field_count]Field) void {
    for (all) |field| gpa.free(field.stars);
}

/// The dust: motes in a cube around the camera, grey at half brightness, placed at random.
pub const dust_count = 200;
pub const dust_cube_mask = 0x1FFF;
pub const dust_grey: f32 = 0.5;

pub const Light = srlight.Light;

/// The key light: the sun, warm white, where no marker says otherwise.
pub const sun_direction: [3]f32 = math.normalize(.{ 1, -0.5, 0.2 });

/// The fill light, which the nebula colours.
pub const fill_direction: [3]f32 = math.normalize(.{ -1, 0.5, 0 });

/// The fill lights' colour until `nebula_select` gives them the nebula's.
pub const default_fill: [3]f32 = .{ 0, 0.5, 1 };

/// The lights `backdrop_create` makes, with the fill lights in `fill`. Models whose objects list
/// components take the first three and the last; the rest take the last four
/// (`objects.lightMask`).
pub fn lightsWith(fill: [3]f32) [6]Light {
    return .{
        .{ .mask = 0x01, .intensity = 1, .colour = .{ 1, 1, 0.8 }, .kind = .{ .directional = sun_direction } },
        .{ .mask = 0x02, .intensity = 1, .colour = fill, .kind = .{ .directional = fill_direction } },
        .{ .mask = 0x04, .intensity = 1, .colour = .{ 0.04, 0.04, 0.04 }, .kind = .ambient },
        .{ .mask = 0x08, .intensity = 1, .colour = .{ 1, 1, 0.8 }, .kind = .{ .directional = sun_direction } },
        .{ .mask = 0x10, .intensity = 0.7, .colour = fill, .kind = .{ .directional = fill_direction } },
        .{ .mask = 0x20, .intensity = 1, .colour = .{ 0.09, 0.09, 0.09 }, .kind = .ambient },
    };
}

pub const lights = lightsWith(default_fill);

/// A sprite's half width and half height, in the camera's units, against its texture's width and
/// height in pixels times its depth (`backdrop_frame`); the sprite pipeline (`0x004CE4D0`) draws it
/// that far to each side of its centre. On screen it reaches its texture's size times the view's
/// scale over 768, in pixels, each way, whatever the distance.
pub const sprite_scale: f32 = 1.0 / 768.0;

/// The sun's sprites, each textured, coloured grey and added on the background layer toward the sun.
pub const SunLayer = enum {
    sunlayer1,
    sunlayer2,
    sunlayer3,

    pub fn texture(layer: SunLayer) []const u8 {
        return @tagName(layer);
    }

    /// Its size against a lens flare's.
    pub fn size(layer: SunLayer) f32 {
        return switch (layer) {
            .sunlayer1 => 0.5,
            .sunlayer2, .sunlayer3 => 2,
        };
    }

    /// Whether it is drawn, for the sun's visibility and the flares' brightness. Only the hardware
    /// renderers have `sunlayer2`.
    pub fn shown(layer: SunLayer, visibility: f32, brightness: f32) bool {
        return switch (layer) {
            .sunlayer1 => true,
            .sunlayer2 => brightness > 0,
            .sunlayer3 => visibility > 0.5,
        };
    }

    /// Its grey, for the flares' brightness. `sunlayer2` and `sunlayer3` take theirs while the
    /// brightness is above 0 and keep it otherwise.
    pub fn grey(layer: SunLayer, brightness: f32) f32 {
        return switch (layer) {
            .sunlayer1 => 1,
            .sunlayer2 => @min(2 * brightness, 1),
            .sunlayer3 => if (brightness < 0.8) 0.15 * brightness + 0.1 else 0.3 * brightness,
        };
    }
};

/// How much of the sun shows (`backdrop_frame`): its distance in pixels from the nearest edge of
/// the screen, at most `max_visibility`, and 0 when it is off the screen. The renderer then lessens
/// it for each triangle of an object flagged `0x8000` that covers the sun's point. It is worked out
/// after the sprites are placed, so each frame uses the last frame's.
pub const max_visibility: f32 = 10;

pub fn sunVisibility(point: [2]f32, width: f32, height: f32) f32 {
    const edge = @min(@min(point[0], point[1]), @min(width - point[0], height - point[1]));
    return std.math.clamp(edge, 0, max_visibility);
}

/// The flares' brightness, for the sun's visibility and `offset`, its distance from the middle of
/// the view in view units: position over depth.
pub fn flareBrightness(visibility: f32, offset: f32) f32 {
    return (0.5 + 0.05 * visibility) * (1 - @min(offset, 1));
}

/// The lens flares, textured, coloured by the flares' brightness and added on the overlay layer:
/// each at `along` times the sun's offset from the middle of the view, so on the line through the
/// sun and the middle, past it when negative. **Unknown:** which views show them (`0x00539A34`,
/// `0x00539A9C`).
pub const Flare = struct { texture: []const u8, along: f32 };
pub const flares = [6]Flare{
    .{ .texture = "sunflare2", .along = 0.5 },
    .{ .texture = "sunflare1", .along = 0.33 },
    .{ .texture = "sunflare3", .along = 0.2 },
    .{ .texture = "sunflare2", .along = -0.2 },
    .{ .texture = "sunflare3", .along = -0.6 },
    .{ .texture = "sunflare4", .along = -0.5 },
};

/// Object types that `backdrop_place` reads a mission's markers from: the sun's aims the key light
/// and the sun, the nebula's the fill light and the nebula.
pub const sun_marker_type = 0x3DC;
pub const nebula_marker_type = 0x3DD;

test fieldAxis {
    // The first field is 9 degrees from +Y, toward +X and +Z; the middle ones straddle the horizon.
    const first = fieldAxis(0, 0);
    try std.testing.expectApproxEqAbs(@cos(9 * std.math.pi / 180.0), first[1], 1e-6);
    for (0..fields_per_side) |row| {
        for (0..fields_per_side) |column| try std.testing.expect(fieldAxis(row, column)[2] > 0);
    }
}

test fields {
    const gpa = std.testing.allocator;
    const rgb = try gpa.alloc(u8, star_map_size * star_map_size * 3);
    defer gpa.free(rgb);
    @memset(rgb, 0);
    // A star at the centre of the first field, and one at the corner of the last.
    rgb[(18 * star_map_size + 18) * 3 ..][0..3].* = .{ 90, 90, 90 };
    rgb[((star_map_size - 1) * star_map_size + star_map_size - 1) * 3 ..][0..3].* = .{ 200, 200, 200 };
    const map: tga.Image = .{ .width = star_map_size, .height = star_map_size, .rgb = rgb };

    const all = try fields(gpa, map);
    defer freeFields(gpa, &all);
    try std.testing.expectEqual(1, all[0].stars.len);
    try std.testing.expectEqual([3]f32{ 0, 0, 1 }, all[0].stars[0].position);
    try std.testing.expectEqual(1, all[field_count - 1].stars.len);
    try std.testing.expectApproxEqAbs(@sin(17 * half_degree), all[field_count - 1].stars[0].position[0], 1e-6);
    try std.testing.expectEqual(0, all[50].stars.len);

    const wrong: tga.Image = .{ .width = 1, .height = 1, .rgb = rgb[0..3] };
    try std.testing.expectError(error.WrongSize, fields(gpa, wrong));
}

test SunLayer {
    try std.testing.expectEqualStrings("sunlayer3", SunLayer.sunlayer3.texture());
    try std.testing.expectEqual(0.5, SunLayer.sunlayer1.size());
    // A sun in full view: every layer shows, `sunlayer2` at full grey.
    try std.testing.expect(SunLayer.sunlayer3.shown(max_visibility, 1));
    try std.testing.expectEqual(1, SunLayer.sunlayer2.grey(0.75));
    try std.testing.expectApproxEqAbs(0.19, SunLayer.sunlayer3.grey(0.6), 1e-6);
    try std.testing.expectApproxEqAbs(0.27, SunLayer.sunlayer3.grey(0.9), 1e-6);
    // Off the screen only `sunlayer1` is left.
    try std.testing.expect(!SunLayer.sunlayer3.shown(0, 0));
    try std.testing.expect(!SunLayer.sunlayer2.shown(0, 0));
    try std.testing.expect(SunLayer.sunlayer1.shown(0, 0));
}

test sunVisibility {
    try std.testing.expectEqual(max_visibility, sunVisibility(.{ 320, 240 }, 640, 480));
    try std.testing.expectEqual(4, sunVisibility(.{ 636, 240 }, 640, 480));
    try std.testing.expectEqual(0, sunVisibility(.{ -20, 240 }, 640, 480));
}

test flareBrightness {
    // Brightest with the sun in the middle of the view, gone a view unit away.
    try std.testing.expectEqual(1, flareBrightness(max_visibility, 0));
    try std.testing.expectEqual(0.25, flareBrightness(max_visibility, 0.75));
    try std.testing.expectEqual(0, flareBrightness(max_visibility, 2));
}

test lights {
    // Each class of model takes four of the six.
    const with_components: u32 = 24;
    const without: u32 = 3;
    var reaching_with: usize = 0;
    var reaching_without: usize = 0;
    for (lights) |light| {
        if (light.mask & with_components == 0) reaching_with += 1;
        if (light.mask & without == 0) reaching_without += 1;
    }
    try std.testing.expectEqual(4, reaching_with);
    try std.testing.expectEqual(4, reaching_without);

    // A nebula colours both fill lights and nothing else.
    const orange = lightsWith(.{ 0.92, 0.66, 0.33 });
    try std.testing.expectEqual([3]f32{ 0.92, 0.66, 0.33 }, orange[1].colour);
    try std.testing.expectEqual([3]f32{ 0.92, 0.66, 0.33 }, orange[4].colour);
    try std.testing.expectEqual(lights[0], orange[0]);
    try std.testing.expectEqual(lights[5], orange[5]);
}
