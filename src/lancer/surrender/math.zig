//! Surrender's vector and matrix helpers. The binary does not name their file; their code lies
//! before `srAPI.cpp`'s. Matrices are 3x3, row-major, and a vector is turned by multiplying it on
//! the right.

const std = @import("std");

pub const Vector = @Vector(3, f32);
pub const Matrix = [9]f32;

pub const identity: Matrix = .{ 1, 0, 0, 0, 1, 0, 0, 0, 1 };

pub fn dot(a: Vector, b: Vector) f32 {
    return @reduce(.Add, a * b);
}

pub fn cross(a: Vector, b: Vector) Vector {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}

pub fn length(v: Vector) f32 {
    return @sqrt(dot(v, v));
}

/// `v` scaled to a length of 1; the zero vector stays zero.
pub fn normalize(v: Vector) Vector {
    const l = length(v);
    return if (l == 0) v else v / @as(Vector, @splat(l));
}

/// `m` times `v`.
pub fn transform(m: Matrix, v: Vector) Vector {
    return .{
        m[0] * v[0] + m[1] * v[1] + m[2] * v[2],
        m[3] * v[0] + m[4] * v[1] + m[5] * v[2],
        m[6] * v[0] + m[7] * v[1] + m[8] * v[2],
    };
}

/// The transpose of `m` times `v`: for a rotation, `v` turned back.
pub fn transformTransposed(m: Matrix, v: Vector) Vector {
    return .{
        m[0] * v[0] + m[3] * v[1] + m[6] * v[2],
        m[1] * v[0] + m[4] * v[1] + m[7] * v[2],
        m[2] * v[0] + m[5] * v[1] + m[8] * v[2],
    };
}

pub fn product(a: Matrix, b: Matrix) Matrix {
    var m: Matrix = undefined;
    for (0..3) |row| {
        for (0..3) |column| {
            m[row * 3 + column] = a[row * 3] * b[column] + a[row * 3 + 1] * b[3 + column] + a[row * 3 + 2] * b[6 + column];
        }
    }
    return m;
}

pub fn transpose(m: Matrix) Matrix {
    return .{ m[0], m[3], m[6], m[1], m[4], m[7], m[2], m[5], m[8] };
}

/// The rotation `mat3_from_angles` (`0x004C2410`) builds from a pitch, a yaw and a roll.
pub fn fromAngles(pitch: f32, yaw: f32, roll: f32) Matrix {
    const sp = @sin(pitch);
    const cp = @cos(pitch);
    const sy = @sin(yaw);
    const cy = @cos(yaw);
    const sr = @sin(roll);
    const cr = @cos(roll);
    return .{
        cr * cy,                -(sr * cy),             sy,
        sr * cp + cr * sy * sp, cr * cp - sr * sy * sp, -(cy * sp),
        sr * sp - cr * sy * cp, cr * sp + sr * sy * cp, cy * cp,
    };
}

/// An orientation whose forward axis, its third column, points along `direction`: turned about `Y`,
/// then about `X`, with no roll (`mat3_look_at`, `0x004C1940`). The engine takes the angles from a
/// table; this computes them.
pub fn lookAt(direction: Vector) Matrix {
    const yaw = std.math.atan2(direction[0], direction[2]);
    const cy = @cos(yaw);
    const sy = @sin(yaw);
    // The direction's length in the turned frame, where its x is zero.
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

fn expectVector(expected: Vector, actual: Vector) !void {
    inline for (0..3) |i| try std.testing.expectApproxEqAbs(expected[i], actual[i], 1e-5);
}

test lookAt {
    for ([_]Vector{ .{ 0, 0, 1 }, .{ 1, -0.5, 0.2 }, .{ -1, 0.5, 0 }, .{ 0.2, 0.9, -0.3 } }) |d| {
        const m = lookAt(normalize(d));
        try expectVector(normalize(d), transform(m, .{ 0, 0, 1 }));
        // No roll: the right axis stays level.
        try std.testing.expectApproxEqAbs(0, m[3], 1e-6);
        try expectVector(.{ 0, 0, 1 }, transformTransposed(m, normalize(d)));
    }
}

test fromAngles {
    try std.testing.expectEqual(identity, fromAngles(0, 0, 0));
    // A yaw of -90 degrees turns the forward axis to -X.
    try expectVector(.{ -1, 0, 0 }, transform(fromAngles(0, -std.math.pi / 2.0, 0), .{ 0, 0, 1 }));
}

test product {
    const m = fromAngles(0.3, -0.7, 0.2);
    const back = product(transpose(m), m);
    for (identity, back) |e, a| try std.testing.expectApproxEqAbs(e, a, 1e-5);
    try std.testing.expectEqual(@as(f32, 3), dot(.{ 1, 1, 1 }, .{ 1, 1, 1 }));
    try expectVector(.{ 0, 0, 1 }, cross(.{ 1, 0, 0 }, .{ 0, 1, 0 }));
}
