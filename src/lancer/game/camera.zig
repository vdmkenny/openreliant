//! `C:\lancer\game\camera.cpp`: the views and where each puts the camera. `camera_set_view`
//! (`0x0045F1B0`) switches view, `camera_frame` (`0x0045FC90`) places the camera once a frame, and
//! `frame_controls` (`0x00414060`) picks views and steers the orbiting ones from the keyboard.

const std = @import("std");

const math = @import("../surrender/math.zig");
const srapi = @import("../surrender/surrenderlib/srapi.zig");
const controls = @import("../input/controls.zig");
const Vector = math.Vector;
const Matrix = math.Matrix;

/// Where the camera is and which way it looks.
pub const Place = struct {
    position: Vector,
    /// Its columns are the camera's right, down and forward axes.
    orientation: Matrix,
};

// --- Projection ---------------------------------------------------------------------------------

/// The factors every view but `wide_view` projects with (`sr_set_projection`): the screen spans
/// 5/6 of a view unit either side of the middle across and 5/8 up and down, square on a 4:3 screen:
/// about 80 degrees across and 64 down.
pub const factors = [2]f32{ 0.6, 0.8 };

/// View 0x20 projects wider, about 110 degrees across.
pub const wide_view = 0x20;
pub const wide_factors = [2]f32{ 0.35, 0.467 };

/// The cinematic views' bars: the viewport leaves out this much of the screen at the top and the
/// bottom once they have slid in.
pub const letterbox: f32 = 0.1;

/// The port's factors for a screen of any shape: the game's down, and across whatever keeps pixels
/// square. A wider screen shows more at the sides instead of stretching; on a 4:3 screen they are
/// the game's to within a thousandth of a percent.
pub fn unstretched(width: u32, height: u32, base: [2]f32) [2]f32 {
    const w: f32 = @floatFromInt(width);
    const h: f32 = @floatFromInt(height);
    return .{ base[1] * (h - 0.1) / (w - 0.1), base[1] };
}

// --- Views --------------------------------------------------------------------------------------

/// A view, numbered as the game numbers them (`camera_view`, `0x00539A34`). The numbers not named
/// here are the game's cutaways: launches, landings, jumps, deaths and the like.
pub const View = enum(u8) {
    /// From the cockpit, ahead; `CockpitMode` says which of three ways.
    cockpit = 0,
    cockpit_left = 1,
    cockpit_right = 2,
    cockpit_rear = 3,
    /// Behind and above an object, lagging its turns. View 0x1E is the same.
    chase = 4,
    /// Around the player's target, looking at it, steered from the keyboard.
    target = 6,
    /// Around the player's ship, likewise.
    external = 0xC,
    /// Behind a missile.
    missile = 0x12,
    /// From a point the player flies past.
    flyby = 0x24,
    _,

    /// Whether the bars slide in (the view table at `0x004F72A8`): for the cutaways from 7 on,
    /// but not the external view.
    pub fn letterboxed(view: View) bool {
        const n = @intFromEnum(view);
        return n >= 7 and view != .external;
    }

    /// Whether the view is from the cockpit, so the object's own model is not drawn.
    pub fn fromCockpit(view: View) bool {
        return @intFromEnum(view) <= @intFromEnum(View.cockpit_rear);
    }
};

/// What the cockpit view shows (`cockpit_mode`, `0x00539A9C`). The cockpit key cycles it while
/// that view is up; the options set it at the start of a mission.
pub const CockpitMode = enum(u2) {
    /// From the eye, with no cockpit drawn.
    open = 0,
    /// From the eye, with the cockpit's model over the view (hardware renderers only).
    cockpit = 1,
    /// The chase view instead.
    chase = 2,

    pub fn next(mode: CockpitMode) CockpitMode {
        return switch (mode) {
            .open => .cockpit,
            .cockpit => .chase,
            .chase => .open,
        };
    }
};

/// The view a camera key picks (`frame_controls`), or null for another action. The cockpit key
/// picks the cockpit view, and, pressed in it, cycles the cockpit mode.
pub fn keyView(action: controls.Action) ?View {
    return switch (action) {
        .cockpit_camera => .cockpit,
        .left_view_camera => .cockpit_left,
        .right_view_camera => .cockpit_right,
        .rear_view_camera => .cockpit_rear,
        .flyby_camera => .flyby,
        .target_camera => .target,
        .external_camera => .external,
        .missile_camera => .missile,
        else => null,
    };
}

// --- The camera ---------------------------------------------------------------------------------

/// What a view reads of an object.
pub const Subject = struct {
    position: Vector,
    orientation: Matrix,
    /// The model header's eye point.
    eye: Vector = @splat(0),
    /// `GameObject.radius`: its farthest vertex from its origin.
    radius: f32 = 0,
    motion: Chase.Motion = .{},
};

/// What `Camera.frame` reads of the world.
pub const World = struct {
    /// The object the view shows, `Camera.object`.
    object: Subject,
    /// The player's ship.
    player: Subject,
    /// The player's target, when it has one.
    target: ?Subject = null,
    /// Hundredths of a second since the last frame (`frame_duration`).
    ticks: u32,
};

/// The camera: the state `camera_set_view` and `camera_frame` keep in globals, and Surrender's
/// camera frame they place. Leaves out the views not named in `View`, the cockpit's model and the
/// shake from hits.
pub const Camera = struct {
    place: Place = .{ .position = @splat(0), .orientation = math.identity },
    view: View = .cockpit,
    /// The object the view shows (`camera_object`, `0x00539A8C`).
    object: ?u16 = null,
    cockpit_mode: CockpitMode = .open,
    /// Set while a script holds the camera (`0x00539ACC`): the camera keys do nothing.
    locked: bool = false,
    /// How much of the screen each bar covers (`0x00539A38`), and how fast they move
    /// (`0x00539A50`).
    bars: f32 = 0,
    bar_speed: f32 = 0,
    /// `frame_start` when the view last changed (`0x00539AA4`).
    switched: u32 = 0,
    chase: Chase = .{},
    orbit: Orbit = .{},

    /// Bars grow this share of the screen a tick, times their speed.
    pub const bar_rate: f32 = 0.001;

    /// Switches view (`camera_set_view`): `object` is the one the view shows, `lock` keeps the
    /// camera keys off it. Refused while the camera is locked, unless `force`. The game then
    /// places the camera at once, as `frame` does, and has the stars draw no streaks this frame.
    pub fn setView(camera: *Camera, view: View, object: ?u16, lock: bool, force: bool, now: u32) bool {
        if (camera.locked and !force) return false;
        if (view.letterboxed()) {
            camera.bar_speed = 1;
        } else {
            camera.bars = 0;
            camera.bar_speed = 0;
        }
        if (view == .chase and (camera.view != .chase or camera.object != object)) {
            camera.chase.distance = Chase.start_distance;
        }
        camera.locked = lock;
        camera.object = object;
        camera.switched = now;
        camera.view = view;
        switch (view) {
            .cockpit => if (camera.cockpit_mode == .chase) camera.chase.resetTurns(),
            .chase, chase_too => camera.chase.resetTurns(),
            .target, .external => camera.orbit = .{},
            else => {},
        }
        return true;
    }

    /// Whether `object` is not drawn because the camera is in its cockpit: `camera_set_view` sets
    /// the object's flag bit 0 then.
    pub fn inside(camera: Camera, object: u16) bool {
        return camera.object == object and camera.view.fromCockpit() and
            !(camera.view == .cockpit and camera.cockpit_mode == .chase);
    }

    /// A camera key (`frame_controls`): the cockpit key, in the cockpit view, cycles the cockpit
    /// mode first. Returns the view to switch to, with the player's ship as its object for the
    /// views from it, or null for another action or while the camera is locked.
    pub fn key(camera: *Camera, action: controls.Action) ?View {
        const view = keyView(action) orelse return null;
        if (action == .cockpit_camera and camera.view == .cockpit and !camera.locked) {
            camera.cockpit_mode = camera.cockpit_mode.next();
            if (camera.cockpit_mode == .chase) camera.chase.distance = Chase.start_distance;
        }
        return view;
    }

    /// Places the camera for a frame (`camera_frame`): moves the bars, then puts the camera where
    /// the view says. Returns a view to switch to when this one cannot go on, as the game does.
    pub fn frame(camera: *Camera, world: World) ?View {
        const ticks: f32 = @floatFromInt(world.ticks);
        if (camera.bar_speed != 0) {
            camera.bars += ticks * camera.bar_speed * bar_rate;
            if (camera.bars >= 0) {
                if (camera.bars > letterbox) {
                    camera.bars = letterbox;
                    camera.bar_speed = 0;
                }
            } else {
                camera.bars = 0;
                camera.bar_speed = 0;
            }
        }
        switch (camera.view) {
            .cockpit => camera.place = if (camera.cockpit_mode == .chase)
                camera.chase.frame(world.object.motion, world.object.position, world.object.orientation)
            else
                cockpit(0, world.object.position, world.object.orientation, world.object.eye),
            .cockpit_left, .cockpit_right, .cockpit_rear => {
                const n: u2 = @truncate(@intFromEnum(camera.view));
                camera.place = if (camera.view == .cockpit_rear and world.object.motion.ship_type == kamov)
                    kamovRear(world.object.position, world.object.orientation)
                else
                    cockpit(n, world.object.position, world.object.orientation, world.object.eye);
            },
            .chase, chase_too => {
                if (world.object.motion.ship_type >= 0x100) return .cockpit;
                camera.place = camera.chase.frame(world.object.motion, world.object.position, world.object.orientation);
            },
            .target => {
                const target = world.target orelse return .cockpit;
                camera.place = camera.orbit.place(.target, target.position, target.radius);
            },
            .external => camera.place = camera.orbit.place(.external, world.player.position, world.player.radius),
            .flyby => camera.place = flyby(camera.place.position, world.player.position, world.player.orientation, world.player.radius),
            else => {},
        }
        return null;
    }

    /// The projection for the view and the bars on a screen of `width` by `height`, unstretched.
    pub fn projection(camera: Camera, width: u32, height: u32) srapi.Projection {
        const base = if (camera.view == @as(View, @enumFromInt(wide_view))) wide_factors else factors;
        return .init(width, height, .{ 0, camera.bars, 1, 1 - camera.bars }, unstretched(width, height, base));
    }
};

/// View 0x1E, which is the chase view again.
pub const chase_too: View = @enumFromInt(0x1E);

// --- Cockpit ------------------------------------------------------------------------------------

/// How far each cockpit view turns from ahead, about the object's down axis, in degrees.
pub const cockpit_turns = [4]f32{ 0, -90, 90, 180 };

/// Ship type 0x2D, the Kamov, whose rear view is from this far along its back instead of from its
/// eye.
pub const kamov = 0x2D;
pub const kamov_rear_distance: f32 = 1500;

fn kamovRear(position: Vector, orientation: Matrix) Place {
    const turned = math.turned(orientation, .y, std.math.pi);
    return .{ .position = position + math.transform(turned, .{ 0, 0, kamov_rear_distance }), .orientation = turned };
}

/// The camera in a cockpit view: turned from the object's orientation, and at its eye point, the
/// model header's `eye`, turned likewise. `view` is 0 to 3.
pub fn cockpit(view: u2, position: Vector, orientation: Matrix, eye: Vector) Place {
    const turned = math.turned(orientation, .y, std.math.degreesToRadians(cockpit_turns[view]));
    return .{ .position = position + math.transform(turned, eye), .orientation = turned };
}

// --- Chase --------------------------------------------------------------------------------------

/// The chase view (`camera_chase`, `0x0045ED60`): behind the object and above it, the farther the
/// more throttle, swinging with its turns. Its state carries from frame to frame and is smoothed
/// once a frame.
pub const Chase = struct {
    /// Along the object's forward axis; negative is behind.
    distance: f32 = start_distance,
    pitch: f32 = 0,
    yaw: f32 = 0,
    roll: f32 = 0,

    /// Where the camera starts on switching to the view, ahead of the object, to swing round.
    pub const start_distance: f32 = 1500;

    /// A ship type's height, negative for above, and distance behind at no throttle.
    pub const Offset = struct { height: f32, distance: f32 };

    pub fn offset(ship_type: u32) Offset {
        return switch (ship_type) {
            0x02 => .{ .height = -650, .distance = 1800 },
            0x08 => .{ .height = -850, .distance = 2000 },
            0x09 => .{ .height = -800, .distance = 2400 },
            0x2D => .{ .height = -1000, .distance = 3400 },
            else => .{ .height = -750, .distance = 1800 },
        };
    }

    /// Farther back for each unit of throttle; the afterburner counts as 1.5.
    pub const throttle_distance: f32 = 400;
    pub const afterburner_throttle: f32 = 1.5;

    /// How the camera turns against the object's rates of turn, in radians per update, and how
    /// far it may: at most a sixteenth of a turn up or down and a tenth either way.
    pub const pitch_swing: f32 = 5.7;
    pub const yaw_swing: f32 = 5;
    pub const roll_swing: f32 = 3;
    pub const pitch_limit: f32 = std.math.pi / 8.0;
    pub const turn_limit: f32 = std.math.pi / 5.0;

    /// The share of the way to its target the distance, and the turns, go each frame.
    pub const distance_smoothing: f32 = 0.1;
    pub const turn_smoothing: f32 = 0.05;

    /// What the view follows of the object.
    pub const Motion = struct {
        ship_type: u32 = 0,
        throttle: f32 = 0,
        afterburner: bool = false,
        pitch_rate: f32 = 0,
        yaw_rate: f32 = 0,
        roll_rate: f32 = 0,
    };

    /// Levels the swing, as switching to the view does (`0x0045ED40`).
    pub fn resetTurns(chase: *Chase) void {
        chase.pitch = 0;
        chase.yaw = 0;
        chase.roll = 0;
    }

    /// Places the camera for this frame and moves the state on.
    pub fn frame(chase: *Chase, motion: Motion, position: Vector, orientation: Matrix) Place {
        const to = offset(motion.ship_type);
        const throttle = if (motion.afterburner) afterburner_throttle else motion.throttle;
        chase.distance += (-(throttle * throttle_distance + to.distance) - chase.distance) * distance_smoothing;

        // Nose up swings the camera half as far as nose down.
        var pitch = std.math.clamp(-pitch_swing * motion.pitch_rate, -pitch_limit, pitch_limit);
        pitch *= if (pitch < 0) 0.5 else 1.5;
        const yaw = std.math.clamp(-yaw_swing * motion.yaw_rate, -turn_limit, turn_limit);
        const roll = std.math.clamp(-roll_swing * motion.roll_rate, -turn_limit, turn_limit);
        chase.pitch += (pitch - chase.pitch) * turn_smoothing;
        chase.yaw += (yaw - chase.yaw) * turn_smoothing;
        chase.roll += (roll - chase.roll + yaw) * turn_smoothing;

        const swung = math.turned(math.turned(orientation, .x, chase.pitch), .y, chase.yaw);
        return .{
            .position = position + math.transform(swung, .{ 0, to.height, chase.distance }),
            .orientation = math.turned(orientation, .z, chase.roll),
        };
    }
};

// --- Orbit --------------------------------------------------------------------------------------

/// The target and external views: the camera goes round an object, in the world's axes, and looks
/// at it. The arrow keys turn it, Shift with up or down moves it in or out. Its state is reset on
/// switching to either view.
pub const Orbit = struct {
    /// Degrees about `Y`, from 0 to 360.
    yaw: f32 = 0,
    /// Degrees about `X`, from -89.5 to 89.5.
    pitch: f32 = 0,
    /// Degrees a tick.
    yaw_speed: f32 = 0,
    pitch_speed: f32 = 0,
    /// Kept between `near` and the view's farthest, in the object's radii.
    distance: f32 = 0,

    pub const acceleration: f32 = 0.1;
    pub const deceleration: f32 = 0.05;
    pub const max_speed: f32 = 5;
    pub const max_pitch: f32 = 89.5;
    /// Units a tick, with Shift held.
    pub const zoom_speed: f32 = 60;

    pub const near: f32 = 1.8;
    pub fn far(view: View) f32 {
        return if (view == .target) 5.8 else 3.8;
    }

    /// The keys that steer it, held this frame.
    pub const Keys = struct {
        left: bool = false,
        right: bool = false,
        up: bool = false,
        down: bool = false,
        shift: bool = false,
    };

    /// Steers the orbit for a frame `ticks` hundredths of a second long.
    pub fn steer(orbit: *Orbit, keys: Keys, ticks: f32) void {
        if (keys.left) {
            orbit.yaw_speed -= ticks * acceleration;
        } else if (keys.right) {
            orbit.yaw_speed += ticks * acceleration;
        }
        orbit.yaw_speed = settle(std.math.clamp(orbit.yaw_speed, -max_speed, max_speed), ticks);
        orbit.yaw += ticks * orbit.yaw_speed;
        if (orbit.yaw >= 0) {
            if (orbit.yaw > 360) orbit.yaw -= 360;
        } else {
            orbit.yaw += 360;
        }

        if (keys.shift and keys.up) {
            orbit.distance -= ticks * zoom_speed;
        } else if (keys.shift and keys.down) {
            orbit.distance += ticks * zoom_speed;
        } else if (keys.up) {
            orbit.pitch_speed += ticks * acceleration;
        } else if (keys.down) {
            orbit.pitch_speed -= ticks * acceleration;
        }
        orbit.pitch_speed = std.math.clamp(settle(orbit.pitch_speed, ticks), -max_speed, max_speed);
        orbit.pitch = std.math.clamp(orbit.pitch + ticks * orbit.pitch_speed, -max_pitch, max_pitch);
        if (@abs(orbit.pitch) == max_pitch) orbit.pitch_speed = 0;
    }

    /// A speed slowed toward 0 by the deceleration, stopping there.
    fn settle(speed: f32, ticks: f32) f32 {
        if (speed > 0) return @max(speed - ticks * deceleration, 0);
        if (speed < 0) return @min(speed + ticks * deceleration, 0);
        return 0;
    }

    /// Places the camera round an object of `radius` at `centre`, keeping the distance in range.
    pub fn place(orbit: *Orbit, view: View, centre: Vector, radius: f32) Place {
        orbit.distance = std.math.clamp(orbit.distance, radius * near, radius * far(view));
        const turn = math.turned(math.turned(math.identity, .y, std.math.degreesToRadians(orbit.yaw)), .x, std.math.degreesToRadians(orbit.pitch));
        const position = centre + math.transform(turn, .{ 0, 0, orbit.distance });
        return .{ .position = position, .orientation = math.lookAt(math.normalize(centre - position)) };
    }
};

// --- Flyby --------------------------------------------------------------------------------------

/// The flyby view stays where it is, looking at the player, until the player is farther than this;
/// then it moves ahead of the player, a radius below and four ahead.
pub const flyby_range: f32 = 23000;

/// Places the flyby camera, from where it was, for a ship at `position` with `orientation` and
/// `radius`. It never comes nearer than a radius.
pub fn flyby(from: Vector, position: Vector, orientation: Matrix, radius: f32) Place {
    var at = from;
    if (math.length(at - position) > flyby_range) {
        at = position + math.transform(orientation, .{ 0, radius, radius * 4 });
    }
    if (math.length(at - position) < radius) {
        at = position + math.normalize(at - position) * @as(Vector, @splat(radius));
    }
    return .{ .position = at, .orientation = math.lookAt(math.normalize(position - at)) };
}

fn expectVector(expected: Vector, actual: Vector) !void {
    inline for (0..3) |i| try std.testing.expectApproxEqAbs(expected[i], actual[i], 1e-3);
}

test unstretched {
    // At 4:3 the game's own; wider screens widen the view rather than stretch it.
    const four_three = unstretched(1024, 768, factors);
    try std.testing.expectApproxEqAbs(factors[0], four_three[0], 1e-4);
    const camera: Camera = .{};
    const sixteen_nine = camera.projection(1920, 1080);
    try std.testing.expectApproxEqAbs(sixteen_nine.scale[0], sixteen_nine.scale[1], 1e-3);
    try std.testing.expect(sixteen_nine.bounds[2] > 1.1);
    try std.testing.expectApproxEqAbs(0.625, sixteen_nine.bounds[3], 1e-4);
    const wide: Camera = .{ .view = @enumFromInt(wide_view) };
    try std.testing.expect(wide.projection(1024, 768).scale[1] < four_three[1] * 768);
}

test Camera {
    const ship: Subject = .{
        .position = .{ 0, 0, 1000 },
        .orientation = math.identity,
        .eye = .{ 0, -100, 300 },
        .radius = 500,
    };
    var camera: Camera = .{};
    try std.testing.expect(camera.setView(.cockpit, 0, false, false, 10));
    try std.testing.expectEqual(null, camera.frame(.{ .object = ship, .player = ship, .ticks = 3 }));
    try expectVector(.{ 0, -100, 1300 }, camera.place.position);
    try std.testing.expect(camera.inside(0));
    try std.testing.expect(!camera.inside(1));

    // The cockpit key in the cockpit view cycles the mode: to the cockpit model, then the chase.
    try std.testing.expectEqual(View.cockpit, camera.key(.cockpit_camera).?);
    try std.testing.expectEqual(CockpitMode.cockpit, camera.cockpit_mode);
    _ = camera.key(.cockpit_camera);
    try std.testing.expectEqual(CockpitMode.chase, camera.cockpit_mode);
    try std.testing.expect(!camera.inside(0));
    _ = camera.frame(.{ .object = ship, .player = ship, .ticks = 3 });
    try std.testing.expect(camera.place.position[2] > 1000);

    // A locked camera refuses a switch unless forced; cutaways bring in the bars.
    try std.testing.expect(camera.setView(.missile, 0, true, false, 20));
    try std.testing.expect(!camera.setView(.external, 0, false, false, 30));
    try std.testing.expectEqual(1, camera.bar_speed);
    for (0..40) |_| _ = camera.frame(.{ .object = ship, .player = ship, .ticks = 3 });
    try std.testing.expectEqual(letterbox, camera.bars);
    try std.testing.expectEqual(0, camera.bar_speed);
    try std.testing.expectApproxEqAbs(76.8, camera.projection(1024, 768).viewport[1], 1e-3);

    // Forced to the external view: bars gone, orbiting the player at the nearest it may.
    try std.testing.expect(camera.setView(.external, 0, false, true, 40));
    try std.testing.expectEqual(0, camera.bars);
    _ = camera.frame(.{ .object = ship, .player = ship, .ticks = 3 });
    try expectVector(.{ 0, 0, 1000 + 500 * Orbit.near }, camera.place.position);

    // The target view needs a target; without one it asks for the cockpit.
    _ = camera.setView(.target, 0, false, false, 50);
    try std.testing.expectEqual(View.cockpit, camera.frame(.{ .object = ship, .player = ship, .ticks = 3 }).?);
}

test View {
    try std.testing.expect(View.cockpit_rear.fromCockpit());
    try std.testing.expect(!View.chase.fromCockpit());
    try std.testing.expect(!View.external.letterboxed());
    try std.testing.expect(View.missile.letterboxed());
    try std.testing.expect(!View.target.letterboxed());
    try std.testing.expectEqual(View.external, keyView(.external_camera).?);
    try std.testing.expectEqual(null, keyView(.fire_lasers));
    try std.testing.expectEqual(CockpitMode.open, CockpitMode.chase.next());
}

test cockpit {
    const eye: Vector = .{ 0, -100, 300 };
    const ahead = cockpit(0, .{ 10, 0, 0 }, math.identity, eye);
    try expectVector(.{ 10, -100, 300 }, ahead.position);
    // Looking back, the eye point turns with the view.
    const rear = cockpit(3, .{ 0, 0, 0 }, math.identity, eye);
    try expectVector(.{ 0, -100, -300 }, rear.position);
    try expectVector(.{ 0, 0, -1 }, math.transform(rear.orientation, .{ 0, 0, 1 }));
    // Looking left: forward turns to -X.
    try expectVector(.{ -1, 0, 0 }, math.transform(cockpit(1, @splat(0), math.identity, eye).orientation, .{ 0, 0, 1 }));
}

test Chase {
    var chase: Chase = .{};
    // Level flight at half throttle: the distance closes on -2000, a tenth of the way a frame.
    const still = chase.frame(.{ .throttle = 0.5 }, .{ 0, 0, 0 }, math.identity);
    try std.testing.expectApproxEqAbs(1500 + (-2000 - 1500) * 0.1, chase.distance, 1e-3);
    try expectVector(.{ 0, -750, chase.distance }, still.position);
    for (0..200) |_| _ = chase.frame(.{ .throttle = 0.5 }, .{ 0, 0, 0 }, math.identity);
    try std.testing.expectApproxEqAbs(-2000, chase.distance, 1e-2);

    // Turning, the camera swings the other way, within its limit.
    for (0..400) |_| _ = chase.frame(.{ .yaw_rate = 1 }, .{ 0, 0, 0 }, math.identity);
    try std.testing.expectApproxEqAbs(-Chase.turn_limit, chase.yaw, 1e-3);
    try std.testing.expectEqual(Chase.Offset{ .height = -1000, .distance = 3400 }, Chase.offset(0x2D));
}

test Orbit {
    var orbit: Orbit = .{};
    // Held right for a while, the orbit turns ever faster up to its limit, less the frame's
    // slowing, which comes after.
    for (0..100) |_| orbit.steer(.{ .right = true }, 3);
    try std.testing.expectApproxEqAbs(Orbit.max_speed - 3 * Orbit.deceleration, orbit.yaw_speed, 1e-5);
    // Let go, it slows to a stop.
    for (0..100) |_| orbit.steer(.{}, 3);
    try std.testing.expectEqual(0, orbit.yaw_speed);
    try std.testing.expect(orbit.yaw >= 0 and orbit.yaw < 360);
    // Pitched all the way, it stops at the limit.
    for (0..400) |_| orbit.steer(.{ .up = true }, 3);
    try std.testing.expectEqual(Orbit.max_pitch, orbit.pitch);

    var level: Orbit = .{};
    const place = level.place(.external, .{ 0, 0, 100 }, 50);
    // Pulled out to the nearest it may be, ahead along +Z, looking back at the centre.
    try std.testing.expectEqual(90, level.distance);
    try expectVector(.{ 0, 0, 190 }, place.position);
    try expectVector(.{ 0, 0, -1 }, math.transform(place.orientation, .{ 0, 0, 1 }));
}

test flyby {
    // Too far: the camera moves ahead of the ship, and looks back at it.
    const place = flyby(.{ 0, 0, 30000 + 23000 }, .{ 0, 0, 0 }, math.identity, 100);
    try expectVector(.{ 0, 100, 400 }, place.position);
    // Too near: it backs off to a radius.
    try expectVector(.{ 0, 0, 100 }, flyby(.{ 0, 0, 10 }, .{ 0, 0, 0 }, math.identity, 100).position);
}
