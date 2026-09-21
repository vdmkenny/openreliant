//! The space backdrop: the star fields, the dust, the sun and its flares, and the lights every
//! mission starts with. `backdrop_create` (`0x004A4E70`) builds them once, `backdrop_place`
//! (`0x004A5A00`) aims them from a mission's markers and `backdrop_frame` (`0x004A5CD0`) adds them to
//! the scene each frame. The binary does not name the file; its code lies between `srofiles.cpp`'s
//! and `timer.cpp`'s. [`nebula.zig`](nebula.zig) has the sky dome and the nebula.

const std = @import("std");
const Allocator = std.mem.Allocator;

const tga = @import("../../formats/tga.zig");

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
    /// Row-major, the field's frame turned to face `axis` (`mat3_look_at`, `0x004C1940`).
    orientation: [9]f32,
    stars: []const Star,
};

/// Field `row`, `column`'s axis: the polar angle, from `+Y`, follows the map's rows and the azimuth,
/// from `+X` toward `+Z`, its columns, so the fields cover the half of the sky where `z` is positive.
pub fn fieldAxis(row: usize, column: usize) [3]f32 {
    const polar = @as(f32, @floatFromInt(row * field_size + field_size / 2)) * half_degree;
    const azimuth = @as(f32, @floatFromInt(column * field_size + field_size / 2)) * half_degree;
    return .{ @cos(azimuth) * @sin(polar), @cos(polar), @sin(azimuth) * @sin(polar) };
}

/// A row-major orientation whose forward axis points along `direction`: turned about `Y`, then about
/// `X`, with no roll.
pub fn lookAt(direction: [3]f32) [9]f32 {
    const yaw = std.math.atan2(direction[0], direction[2]);
    const cy = @cos(yaw);
    const sy = @sin(yaw);
    // The direction in the turned frame, where its x is zero.
    const along = direction[0] * sy + direction[2] * cy;
    const pitch = std.math.atan2(direction[1], along);
    const cp = @cos(pitch);
    const sp = @sin(pitch);
    return .{
        cy,  -sy * sp, sy * cp,
        0,   cp,       sp,
        -sy, -cy * sp, cy * cp,
    };
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
            result[made] = .{ .axis = axis, .orientation = lookAt(axis), .stars = try stars.toOwnedSlice(gpa) };
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

pub const Light = struct {
    /// Reaches an object whose light mask shares no bit with it.
    mask: u32,
    intensity: f32,
    colour: [3]f32,
    source: Source,

    pub const Source = union(enum) {
        ambient,
        /// Lights a surface in proportion to its normal's dot product with this axis.
        directional: [3]f32,
    };
};

/// The key light: the sun, warm white, where no marker says otherwise.
pub const sun_direction = normalize(.{ 1, -0.5, 0.2 });

/// The fill light, which the nebula colours.
pub const fill_direction = normalize(.{ -1, 0.5, 0 });

/// The lights `backdrop_create` makes. Models whose objects list components take the first three
/// and the last; the rest take the last four (`objects.lightMask`).
pub const lights = [6]Light{
    .{ .mask = 0x01, .intensity = 1, .colour = .{ 1, 1, 0.8 }, .source = .{ .directional = sun_direction } },
    .{ .mask = 0x02, .intensity = 1, .colour = .{ 0, 0.5, 1 }, .source = .{ .directional = fill_direction } },
    .{ .mask = 0x04, .intensity = 1, .colour = .{ 0.04, 0.04, 0.04 }, .source = .ambient },
    .{ .mask = 0x08, .intensity = 1, .colour = .{ 1, 1, 0.8 }, .source = .{ .directional = sun_direction } },
    .{ .mask = 0x10, .intensity = 0.7, .colour = .{ 0, 0.5, 1 }, .source = .{ .directional = fill_direction } },
    .{ .mask = 0x20, .intensity = 1, .colour = .{ 0.09, 0.09, 0.09 }, .source = .ambient },
};

/// The sun's sprites, drawn on the background layer toward the sun, added. Each is its texture's
/// size in pixels times `size`, on a screen 768 pixels tall, whatever the distance.
pub const SunLayer = struct { texture: []const u8, size: f32 };
pub const sun_layers = [3]SunLayer{
    .{ .texture = "sunlayer1", .size = 0.5 },
    .{ .texture = "sunlayer2", .size = 2 },
    .{ .texture = "sunlayer3", .size = 2 },
};

/// The lens flares, drawn on the overlay layer, added: each at `along` times the sun's offset from
/// the middle of the view, so on the line through the sun and the middle, past it when negative.
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

fn normalize(v: [3]f32) [3]f32 {
    const length = @sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    return .{ v[0] / length, v[1] / length, v[2] / length };
}

fn transform(m: [9]f32, v: [3]f32) [3]f32 {
    return .{
        m[0] * v[0] + m[1] * v[1] + m[2] * v[2],
        m[3] * v[0] + m[4] * v[1] + m[5] * v[2],
        m[6] * v[0] + m[7] * v[1] + m[8] * v[2],
    };
}

test fieldAxis {
    // The first field is 9 degrees from +Y, toward +X and +Z; the middle ones straddle the horizon.
    const first = fieldAxis(0, 0);
    try std.testing.expectApproxEqAbs(@cos(9 * std.math.pi / 180.0), first[1], 1e-6);
    for (0..fields_per_side) |row| {
        for (0..fields_per_side) |column| try std.testing.expect(fieldAxis(row, column)[2] > 0);
    }
}

test lookAt {
    for ([_][3]f32{ .{ 0, 0, 1 }, sun_direction, fill_direction, fieldAxis(3, 7), .{ 0, -1, 0.001 } }) |d| {
        const m = lookAt(normalize(d));
        const forward = transform(m, .{ 0, 0, 1 });
        const expected = normalize(d);
        for (0..3) |i| try std.testing.expectApproxEqAbs(expected[i], forward[i], 1e-5);
        // A rotation: its right axis stays level.
        try std.testing.expectApproxEqAbs(0, m[3], 1e-6);
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
}
