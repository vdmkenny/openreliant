//! Surrender's vector and matrix helpers. The binary does not name their file; their code lies
//! before `srAPI.cpp`'s. Matrices are 3x3, row-major, and a vector is turned by multiplying it on
//! the right.

const std = @import("std");

pub const Vector = @Vector(3, f32);
pub const Matrix = [9]f32;

pub const identity: Matrix = .{ 1, 0, 0, 0, 1, 0, 0, 0, 1 };

// The helpers add in the order the engine's do, which with the FPU rounding to single precision, as
// it does once Direct3D is running, gives the same results.

/// `vec3_dot` (`0x004C11C0`).
pub fn dot(a: Vector, b: Vector) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

pub fn cross(a: Vector, b: Vector) Vector {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}

/// `vec3_length_squared` (`0x004C12A0`).
pub fn lengthSquared(v: Vector) f32 {
    return v[0] * v[0] + v[2] * v[2] + v[1] * v[1];
}

/// `vec3_length` (`0x004C1270`).
pub fn length(v: Vector) f32 {
    return @sqrt(lengthSquared(v));
}

/// `v` scaled to a length of 1 (`vec3_normalize`, `0x004C1370`). The zero vector becomes a tiny
/// one pointing forward.
pub fn normalize(v: Vector) Vector {
    const l = length(v);
    if (l == 0) return .{ 0, 0, 7.523164e-37 };
    return v * @as(Vector, @splat(1 / l));
}

/// `m` times `v` (`vec3_turn`, `0x004C22B0`; `mat3_transform`, `0x004C23C0`).
pub fn transform(m: Matrix, v: Vector) Vector {
    return .{
        m[1] * v[1] + m[2] * v[2] + m[0] * v[0],
        m[3] * v[0] + m[4] * v[1] + m[5] * v[2],
        m[6] * v[0] + m[7] * v[1] + m[8] * v[2],
    };
}

/// The transpose of `m` times `v`: for a rotation, `v` turned back (`vec3_turn_back`,
/// `0x004C2310`; `mat3_transform_transposed`, `0x004C2370`).
pub fn transformTransposed(m: Matrix, v: Vector) Vector {
    return .{
        m[3] * v[1] + m[6] * v[2] + m[0] * v[0],
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

/// `mat3_orthonormalize` (`0x004C2690`): `m` with its axes, the columns, made unit length and
/// perpendicular again. The Z axis keeps its direction, the Y axis becomes Z × X normalized, and
/// the X axis Y × Z (`mat3_from_axes`, `0x004C2610`).
pub fn orthonormalize(m: Matrix) Matrix {
    const x: Vector = .{ m[0], m[3], m[6] };
    const z = normalize(.{ m[2], m[5], m[8] });
    const y = normalize(cross(z, x));
    const new_x = cross(y, z);
    return .{ new_x[0], y[0], z[0], new_x[1], y[1], z[1], new_x[2], y[2], z[2] };
}

/// `mat3_angles` (`0x004C2740`): the angles about X, Y and Z that make up `m`, in radians. When
/// the Y angle is close to a right angle, the X angle takes all of the turn and Z is 0.
pub fn angles(m: Matrix) Vector {
    const across = @sqrt(m[1] * m[1] + m[0] * m[0]);
    const y = atan2(m[2], across);
    if (across > 1.6e-5) return .{ atan2(-m[5], m[8]), y, atan2(-m[1], m[0]) };
    return .{ atan2(m[7], m[4]), y, 0 };
}

/// A small turn by the angles `a` about X, Y and Z, to first order: turning a vector `v` by it
/// adds `cross(a, v)`.
pub fn smallTurn(a: Vector) Matrix {
    return .{ 1, -a[2], a[1], a[2], 1, -a[0], -a[1], a[0], 1 };
}

/// The steps of the tangent `atan_table` holds, 1/4096 apart from 0 to 1.
const atan_steps = 4096;

/// `atan_table` (`0x005DE344`): the arctangent of each step. The engine fills it when it starts
/// (`0x004C3000`); here it is computed at compile time.
const atan_table = table: {
    @setEvalBranchQuota(1_000_000);
    var table: [atan_steps + 1]f32 = undefined;
    for (&table, 0..) |*angle, step| {
        angle.* = @floatCast(std.math.atan(@as(f64, @floatFromInt(step)) / atan_steps));
    }
    break :table table;
};

/// `sr_atan2` (`0x004C3200`): the angle whose tangent is `y / x`, from -π to π. The engine looks
/// it up in `atan_table` by the smaller of `y / x` and `x / y`, rounded to the nearest step, so
/// it can be off by up to half a step. 0/0 gives π/2.
pub fn atan2(y: f32, x: f32) f32 {
    const pi: f32 = std.math.pi;
    const half_pi: f32 = std.math.pi / 2.0;
    if (@abs(y) < @abs(x)) {
        const step = atanStep(y / x);
        const angle = atan_table[@abs(step)];
        if (x < 0) return if (step < 0) pi - angle else angle - pi;
        return if (step < 0) -angle else angle;
    }
    const step = atanStep(x / y);
    const angle = atan_table[@abs(step)];
    if (y < 0) return if (step < 0) angle - half_pi else -half_pi - angle;
    return if (step < 0) angle + half_pi else half_pi - angle;
}

/// The step of `atan_table` nearest the tangent `t`, which is between -1 and 1, rounded as
/// `sr_round` (`FISTP`) rounds. The engine multiplies by 4096 before it divides, `y * 4096 / x`;
/// multiplying by a power of two is exact, so the step is the same.
fn atanStep(t: f32) i32 {
    // 0/0 and ∞/∞. The engine's step is then -2^31, and its table address wraps round to the
    // first entry, 0, which gives the same angle as step 0 here.
    if (std.math.isNan(t)) return 0;
    return @intFromFloat(roundEven(t * atan_steps));
}

/// `x` rounded to the nearest whole number, halves to even, as the x87 rounds by default (`FISTP`).
pub fn roundEven(x: f32) f32 {
    const r = @round(x);
    if (@abs(x - @trunc(x)) == 0.5 and @mod(r, 2) != 0) return r - std.math.sign(x);
    return r;
}

pub const Axis = enum { x, y, z };

/// A right-handed turn by `angle` radians about `axis`.
pub fn rotation(axis: Axis, angle: f32) Matrix {
    const c = @cos(angle);
    const s = @sin(angle);
    return switch (axis) {
        .x => .{ 1, 0, 0, 0, c, -s, 0, s, c },
        .y => .{ c, 0, s, 0, 1, 0, -s, 0, c },
        .z => .{ c, -s, 0, s, c, 0, 0, 0, 1 },
    };
}

/// `m` turned by `angle` about its own `axis`, `m` times the rotation (`mat3_turn_x`, `0x004C2100`;
/// `mat3_turn_y`, `0x004C2190`; `mat3_turn_z`, `0x004C2220`).
pub fn turned(m: Matrix, axis: Axis, angle: f32) Matrix {
    return product(m, rotation(axis, angle));
}

/// The rotation `mat3_from_angles` (`0x004C2410`) builds from a pitch, a yaw and a roll: turns about
/// `X`, then `Y`, then `Z`.
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
/// then about `X`, with no roll (`mat3_look_at`, `0x004C1940`).
pub fn lookAt(direction: Vector) Matrix {
    const yaw = atan2(direction[0], direction[2]);
    const cy = @cos(yaw);
    const sy = @sin(yaw);
    // The direction's length in the turned frame, where its x is zero.
    const along = direction[0] * sy + direction[2] * cy;
    const pitch = atan2(direction[1], along);
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
        // Within the precision of the angles `atan2` looks up.
        const forward = transform(m, .{ 0, 0, 1 });
        inline for (0..3) |i| try std.testing.expectApproxEqAbs(normalize(d)[i], forward[i], atan2_precision);
        // No roll: the right axis stays level.
        try std.testing.expectApproxEqAbs(0, m[3], 1e-6);
    }
}

/// How far off `atan2` can be: half a step of the tangent, and a little for rounding.
const atan2_precision: f32 = 0.5 / @as(f32, atan_steps) + 1e-6;

test atan2 {
    // Around the circle, the looked-up angle stays within half a step of the tangent of the real one.
    for (0..720) |i| {
        const angle = (@as(f32, @floatFromInt(i)) - 360) / 360 * std.math.pi;
        const found = atan2(@sin(angle) * 3, @cos(angle) * 3);
        try std.testing.expectApproxEqAbs(0, std.math.wrap(found - angle, std.math.pi), atan2_precision);
    }
    // Exact on the table's steps.
    try std.testing.expectEqual(atan_table[1024], atan2(1, 4));
    try std.testing.expectEqual(@as(f32, std.math.pi / 4.0), atan2(1, 1));
    try std.testing.expectEqual(-@as(f32, std.math.pi / 2.0), atan2(-2, 0));
    try std.testing.expectEqual(@as(f32, std.math.pi / 2.0), atan2(0, 0));
    // A tangent that rounds to step 0 from below, for a y a little above 0 and an x below it,
    // gives -π rather than π, as the engine's does.
    try std.testing.expectEqual(-@as(f32, std.math.pi), atan2(1e-5, -1));
    try std.testing.expectEqual(@as(f32, std.math.pi) - atan_table[41], atan2(0.01, -1));
}

test smallTurn {
    const a: Vector = .{ 0.001, -0.002, 0.0015 };
    const v: Vector = .{ 3, -1, 2 };
    try expectVector(v + cross(a, v), transform(smallTurn(a), v));
    // To first order, the same as turning about each axis in turn.
    const turn = fromAngles(a[0], a[1], a[2]);
    for (turn, smallTurn(a)) |e, found| try std.testing.expectApproxEqAbs(e, found, 1e-5);
}

test normalize {
    try std.testing.expectEqual(@as(Vector, .{ 0.6, 0, 0.8 }), normalize(.{ 3, 0, 4 }));
    try std.testing.expectEqual(@as(Vector, .{ 0, 0, 7.523164e-37 }), normalize(.{ 0, 0, 0 }));
}

test fromAngles {
    try std.testing.expectEqual(identity, fromAngles(0, 0, 0));
    // A yaw of -90 degrees turns the forward axis to -X.
    try expectVector(.{ -1, 0, 0 }, transform(fromAngles(0, -std.math.pi / 2.0, 0), .{ 0, 0, 1 }));
}

test roundEven {
    try std.testing.expectEqual(2, roundEven(2.5));
    try std.testing.expectEqual(4, roundEven(3.5));
    try std.testing.expectEqual(-2, roundEven(-2.5));
    try std.testing.expectEqual(3, roundEven(2.6));
    try std.testing.expectEqual(128, roundEven(127.5));
}

test turned {
    // A quarter turn about Y takes forward to +X, about X takes down to forward.
    try expectVector(.{ 1, 0, 0 }, transform(rotation(.y, std.math.pi / 2.0), .{ 0, 0, 1 }));
    try expectVector(.{ 0, 0, 1 }, transform(rotation(.x, std.math.pi / 2.0), .{ 0, 1, 0 }));
    try expectVector(.{ 0, 1, 0 }, transform(rotation(.z, std.math.pi / 2.0), .{ 1, 0, 0 }));
    // `fromAngles` is the three turns in order.
    const m = turned(turned(turned(identity, .x, 0.3), .y, -0.7), .z, 0.2);
    for (fromAngles(0.3, -0.7, 0.2), m) |e, a| try std.testing.expectApproxEqAbs(e, a, 1e-6);
}

test product {
    const m = fromAngles(0.3, -0.7, 0.2);
    const back = product(transpose(m), m);
    for (identity, back) |e, a| try std.testing.expectApproxEqAbs(e, a, 1e-5);
    try std.testing.expectEqual(@as(f32, 3), dot(.{ 1, 1, 1 }, .{ 1, 1, 1 }));
    try expectVector(.{ 0, 0, 1 }, cross(.{ 1, 0, 0 }, .{ 0, 1, 0 }));
}

test orthonormalize {
    // A rotation stays as it is; a skewed, stretched one comes back square, keeping its Z axis.
    const turn = rotation(.y, 0.5);
    for (turn, orthonormalize(turn)) |a, b| try std.testing.expectApproxEqAbs(a, b, 1e-6);
    const skewed: Matrix = .{ 2, 0.3, 0, 0, 1, 0, 0.2, 0, 3 };
    const square = orthonormalize(skewed);
    const x: Vector = .{ square[0], square[3], square[6] };
    const y: Vector = .{ square[1], square[4], square[7] };
    const z: Vector = .{ square[2], square[5], square[8] };
    try std.testing.expectApproxEqAbs(1, length(x), 1e-6);
    try std.testing.expectApproxEqAbs(0, dot(x, y), 1e-6);
    try std.testing.expectApproxEqAbs(0, dot(y, z), 1e-6);
    try std.testing.expectApproxEqAbs(0, z[0], 1e-6);
}

test angles {
    // A turn about one axis at a time gives that angle back, as closely as `atan2` looks it up.
    for ([_]Axis{ .x, .y, .z }, 0..) |axis, index| {
        const found: [3]f32 = angles(rotation(axis, 0.3));
        for (found, 0..) |angle, i| try std.testing.expectApproxEqAbs(if (i == index) @as(f32, 0.3) else 0, angle, atan2_precision);
    }
    try std.testing.expectEqual(Vector{ 0, 0, 0 }, angles(identity));
    // At a right angle about Y, the X angle takes all of the turn and Z is 0.
    const found: [3]f32 = angles(fromAngles(0.4, std.math.pi / 2.0, 0.2));
    try std.testing.expectApproxEqAbs(0.6, found[0], atan2_precision);
    try std.testing.expectApproxEqAbs(std.math.pi / 2.0, found[1], atan2_precision);
    try std.testing.expectEqual(0, found[2]);
}
