//! `C:\lancer\game\camera.cpp`: the views and where each puts the camera. `camera_set_view`
//! (`0x0045F1B0`) switches view, `camera_frame` (`0x0045FC90`) places the camera once a frame, and
//! `frame_controls` (`0x00414060`) picks views and steers the orbiting ones from the keyboard.

const std = @import("std");

const math = @import("../surrender/math.zig");
const srapi = @import("../surrender/surrenderlib/srapi.zig");
const input = @import("../input.zig");
const controls = @import("../input/controls.zig");
const libcmt = @import("../libcmt.zig");
const Vector = math.Vector;

/// The view table, which [`camera/views.zig`](camera/views.zig) transcribes.
pub const views = @import("camera/views.zig");
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
/// square. **Improvement:** the game uses its factors on every screen, which stretches the picture
/// on any but a 4:3 one; the port shows more at the sides instead. On a 4:3 screen the factors are
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

    /// The view's record in the view table (`0x004F72A8`), or null for a number past it, which
    /// `camera_set_view` stops the game for as an invalid camera type.
    pub fn record(view: View) ?views.Record {
        const n = @intFromEnum(view);
        return if (n < views.records.len) views.records[n] else null;
    }

    /// Whether the bars slide in: for the cutaways from 7 to `0x27` and `0x2B`, but not the
    /// external view.
    pub fn letterboxed(view: View) bool {
        return if (view.record()) |found| found.bars else false;
    }

    /// Whether the view is from the cockpit, so the object's own model is not drawn: views 0 to 3.
    pub fn fromCockpit(view: View) bool {
        return if (view.record()) |found| found.cockpit else false;
    }

    /// The language string that names the view, which `hud_draw` shows at the top of the screen
    /// in every view but the one ahead from the cockpit.
    pub fn name(view: View) ?u16 {
        return if (view.record()) |found| found.name else null;
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

/// The options' cockpit setting (`cockpit_mode_setting`, `0x005D5A78`), which the game keeps in
/// its ini as `[Device] View`, 0 when the ini has none.
pub const CockpitSetting = enum(u32) {
    cockpit = 0,
    chase = 1,
    none = 2,
    _,

    /// The cockpit mode a mission's launch ends in (`launch_run`, `0x0041B240`), as it switches
    /// the camera from the launch's cutaway to view 0: the cockpit's model for 0, the chase view
    /// for 1, and no cockpit for any other.
    pub fn mode(setting: CockpitSetting) CockpitMode {
        return switch (setting) {
            .cockpit => .cockpit,
            .chase => .chase,
            else => .open,
        };
    }
};

/// The camera keys, in the order `frame_controls` reads them.
pub const camera_actions = [_]controls.Action{
    .cockpit_camera, .left_view_camera, .right_view_camera, .rear_view_camera,
    .flyby_camera,   .target_camera,    .external_camera,   .missile_camera,
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
    /// The cockpit's model and what moves it, for view 0 outside the chase mode; null for an
    /// object with no cockpit.
    cockpit: ?Cockpit.Input = null,
    /// The runtime's `rand`, which the cockpit's jitter and the shake from hits draw on.
    random: ?*libcmt.Rand = null,
};

/// The camera: the state `camera_set_view` and `camera_frame` keep in globals, and Surrender's
/// camera frame they place, with the cockpit's model it moves in view 0. Leaves out the views not
/// named in `View`, and the shake from hits in any view but 0.
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
    /// How hard the last hit shook the camera (`hit_shake`, `0x00588724`): at most 2, and less by
    /// 0.02 a tick.
    hit_shake: f32 = 0,
    /// The guns' kick on the cockpit's hands (`0x005636E0`): 1 as the player's guns fire
    /// (`0x0047BE3A`), and a twentieth less each frame.
    recoil: f32 = 0,
    /// Where the cockpit's model stands this frame, in view 0 outside the chase mode; null in the
    /// rest.
    cockpit_place: ?Cockpit.Placed = null,

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

    /// The camera's part of `frame_controls` for a frame `ticks` hundredths of a second long: in
    /// the target and external views, the arrow keys steer the orbit, with Shift up and down to
    /// zoom; then each camera key pressed picks its view, the last one in the game's order
    /// winning, with `player` as the object. The keys are read as the game reads them, in its order,
    /// since `key_pressed` frees latches. Not yet ported: the joystick's hat.
    pub fn frameControls(camera: *Camera, keyboard: *input.Keyboard, player: u16, ticks: u32, now: u32) void {
        if (camera.view == .target or camera.view == .external) {
            const scan = input.scan;
            var keys: Orbit.Keys = .{};
            if (keyboard.pressed(scan.left, .none, false)) {
                keys.left = true;
            } else if (keyboard.pressed(scan.right, .none, false)) {
                keys.right = true;
            }
            if (keyboard.pressed(scan.up, .shift, false)) {
                keys = .{ .left = keys.left, .right = keys.right, .up = true, .shift = true };
            } else if (keyboard.pressed(scan.down, .shift, false)) {
                keys = .{ .left = keys.left, .right = keys.right, .down = true, .shift = true };
            } else if (keyboard.pressed(scan.up, .none, false)) {
                keys.up = true;
            } else if (keyboard.pressed(scan.down, .none, false)) {
                keys.down = true;
            }
            camera.orbit.steer(keys, @floatFromInt(ticks));
        }
        var chosen: ?View = null;
        for (camera_actions) |action| {
            if (input.controlActive(keyboard, controls.binding(action), true, false)) chosen = camera.key(action);
        }
        if (chosen) |view| _ = camera.setView(view, player, false, false, now);
    }

    /// Places the camera for a frame (`camera_frame`): moves the bars, then puts the camera where
    /// the view says. Returns a view to switch to when this one cannot go on, as the game does.
    pub fn frame(camera: *Camera, world: World) ?View {
        const ticks: f32 = @floatFromInt(world.ticks);
        // What the shake from hits jitters by this frame, before it dies away some more.
        var shake: f32 = 0;
        if (camera.hit_shake > 0) {
            if (camera.hit_shake > Cockpit.shake_most) camera.hit_shake = Cockpit.shake_most;
            shake = camera.hit_shake * Cockpit.shake_share;
            camera.hit_shake -= ticks * Cockpit.shake_fade;
            if (camera.hit_shake < 0) camera.hit_shake = 0;
        }
        camera.cockpit_place = null;
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
            .cockpit => if (camera.cockpit_mode == .chase) {
                camera.place = camera.chase.frame(world.object.motion, world.object.position, world.object.orientation);
            } else {
                camera.place = cockpit(0, world.object.position, world.object.orientation, world.object.eye);
                if (world.cockpit) |model| camera.cockpit_place = Cockpit.place(model, &camera.recoil, shake, world.random);
                // The camera itself shakes with a hit, by what is left of it.
                if (shake > 0) camera.place.orientation = math.product(
                    Cockpit.jitter(camera.hit_shake * Cockpit.camera_shake, world.random),
                    camera.place.orientation,
                );
            },
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

// --- The cockpit's model ------------------------------------------------------------------------

/// The cockpit's model as `camera_frame` moves it in view 0 outside the chase mode. The mission's
/// start makes an object of the ship's cockpit frame (`0x005883F4`) and hangs its root from the
/// camera's frame; each frame the camera sways the root against the ship's turns and slides it
/// with its speed, and turns the hands, its second part, with the stick.
pub const Cockpit = struct {
    /// How far the root turns against each rate of turn at its full: its pitch, its yaw and its
    /// roll.
    pub const sway: [3]f32 = .{ -0.1, -0.15, -0.1 };
    /// How far it slides back at the cruise speed.
    pub const slide: f32 = 50;
    /// How far the hands turn: their pitch with the ship's pitch rate, and their roll with its
    /// roll and its yaw rates together.
    pub const hands_pitch: f32 = 0.15;
    pub const hands_roll: f32 = 0.2;
    /// How far the guns' kick moves the hands back at its full, and what is left of it the frame
    /// after.
    pub const recoil_kick: f32 = 30;
    pub const recoil_fade: f32 = 0.95;
    /// The shake from a hit: `hit_shake` goes no higher than `shake_most` and dies away by
    /// `shake_fade` a tick; the root jitters by a random share of `shake_share` of it, up to half
    /// of that either way, and the camera by a share of `camera_shake` of what is left.
    pub const shake_most: f32 = 2;
    pub const shake_share: f32 = 0.1;
    pub const shake_fade: f32 = 0.02;
    pub const camera_shake: f32 = 0.03;

    /// What moves the cockpit, and where its model stands.
    pub const Input = struct {
        /// The ship's rates of turn over its flight model's full ones: pitch, yaw and roll.
        rates: [3]f32,
        /// Its speed over its cruise speed (`object_cruise_speed`).
        speed: f32,
        /// The cockpit frame model's eye (its header's vector at `0x08`), which the root is set
        /// back by so that the eye stands at the camera.
        eye: Vector,
        /// Where the hands stand from the root, their part's position less the object's centre,
        /// and the point they turn about, their part's mount point.
        hands_origin: Vector,
        hands_pivot: Vector,
    };

    /// Where the root stands in the camera's frame, and the hands in the root's.
    pub const Placed = struct {
        root: Place,
        hands: Place,
    };

    /// Moves the cockpit for a frame. The rates and the speed count to 1 either way at most.
    pub fn place(model: Input, recoil: *f32, shake: f32, random: ?*libcmt.Rand) Placed {
        var rates = model.rates;
        for (&rates) |*rate| rate.* = std.math.clamp(rate.*, -1, 1);
        const speed = std.math.clamp(model.speed, -1, 1);
        const swayed = math.fromAngles(rates[0] * sway[0], rates[1] * sway[1], rates[2] * sway[2]);
        const root: Place = .{
            .position = Vector{ 0, 0, speed * slide } - model.eye,
            .orientation = math.product(jitter(shake * 0.5, random), swayed),
        };

        const turn = math.fromAngles(rates[0] * hands_pitch, 0, (rates[2] + rates[1]) * hands_roll);
        var at = model.hands_origin;
        at[2] -= recoil.* * recoil_kick;
        recoil.* *= recoil_fade;
        // They turn about their mount point rather than their origin.
        at += model.hands_pivot - math.transform(turn, model.hands_pivot);
        return .{ .root = root, .hands = .{ .position = at, .orientation = turn } };
    }

    /// A turn of up to half of `amount` either way in yaw and in roll, as `camera_frame` draws two
    /// of `rand`'s numbers, the first for the roll. Without a `rand` it draws none, and does not
    /// turn.
    pub fn jitter(amount: f32, random: ?*libcmt.Rand) Matrix {
        const source = random orelse return math.identity;
        const roll = share(source.rand()) * amount;
        const yaw = share(source.rand()) * amount;
        return math.fromAngles(0, yaw, roll);
    }

    /// One of `rand`'s numbers as a share between -0.5 and 0.5.
    fn share(value: u15) f32 {
        return @as(f32, @floatFromInt(value)) * (1.0 / @as(f32, libcmt.Rand.max)) - 0.5;
    }
};

test Cockpit {
    const model: Cockpit.Input = .{
        .rates = .{ 0, 0, 0 },
        .speed = 0,
        .eye = .{ 0, -100, 300 },
        .hands_origin = .{ 10, 20, 30 },
        .hands_pivot = .{ 0, 0, 50 },
    };
    // At rest the root stands back by the eye, unturned, and the hands where their part does.
    var recoil: f32 = 0;
    const still = Cockpit.place(model, &recoil, 0, null);
    try expectVector(.{ 0, 100, -300 }, still.root.position);
    try std.testing.expectEqual(math.identity, still.root.orientation);
    try expectVector(.{ 10, 20, 30 }, still.hands.position);

    // Flying at the cruise speed, the root slides 50 back; turning, it sways against the turn,
    // to no more than a full rate's worth.
    var moving = model;
    moving.speed = 3;
    moving.rates = .{ 2, 0, 0 };
    const swayed = Cockpit.place(moving, &recoil, 0, null);
    try expectVector(.{ 0, 100, -250 }, swayed.root.position);
    for (math.fromAngles(-0.1, 0, 0), swayed.root.orientation) |e, a| try std.testing.expectApproxEqAbs(e, a, 1e-6);

    // The guns' kick moves the hands back, and fades by a twentieth each frame.
    recoil = 1;
    const kicked = Cockpit.place(model, &recoil, 0, null);
    try expectVector(.{ 10, 20, 0 }, kicked.hands.position);
    try std.testing.expectApproxEqAbs(0.95, recoil, 1e-6);

    // The hands turn about their mount point: that point stays where it is.
    var turning = model;
    turning.rates = .{ 1, 0, 0 };
    const turned = Cockpit.place(turning, &recoil, 0, null);
    const pivot_after = turned.hands.position + math.transform(turned.hands.orientation, model.hands_pivot);
    try expectVector(model.hands_origin + model.hands_pivot - Vector{ 0, 0, 0.95 * 30 }, pivot_after);
}

test "the shake from a hit dies away and turns the camera" {
    var camera: Camera = .{ .hit_shake = 3 };
    var random: libcmt.Rand = .{};
    const ship: Subject = .{ .position = @splat(0), .orientation = math.identity };
    _ = camera.frame(.{ .object = ship, .player = ship, .ticks = 10, .random = &random });
    // It goes no higher than 2, then dies away by 0.02 a tick.
    try std.testing.expectApproxEqAbs(1.8, camera.hit_shake, 1e-6);
    // The camera is turned off the ship's own orientation.
    try std.testing.expect(!std.meta.eql(math.identity, camera.place.orientation));
    // Without a cockpit model there is nothing to place.
    try std.testing.expectEqual(null, camera.cockpit_place);
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
    // The last few views have no bars, but for the table's last.
    try std.testing.expect(!@as(View, @enumFromInt(0x28)).letterboxed());
    try std.testing.expect(@as(View, @enumFromInt(0x2B)).letterboxed());
    // A view past the table has no record.
    try std.testing.expectEqual(null, @as(View, @enumFromInt(0x2C)).record());
    try std.testing.expect(!@as(View, @enumFromInt(0x2C)).fromCockpit());
    // Each named view has its own string; the cutaways share theirs.
    try std.testing.expectEqual(170, View.cockpit.name().?);
    try std.testing.expectEqual(180, View.external.name().?);
    try std.testing.expectEqual(View.chase.name(), @as(View, @enumFromInt(0x0D)).name());
    try std.testing.expectEqual(View.external, keyView(.external_camera).?);
    try std.testing.expectEqual(null, keyView(.fire_lasers));
    try std.testing.expectEqual(CockpitMode.open, CockpitMode.chase.next());
    try std.testing.expectEqual(CockpitMode.cockpit, CockpitSetting.cockpit.mode());
    try std.testing.expectEqual(CockpitMode.chase, CockpitSetting.chase.mode());
    try std.testing.expectEqual(CockpitMode.open, CockpitSetting.none.mode());
    try std.testing.expectEqual(CockpitMode.open, @as(CockpitSetting, @enumFromInt(7)).mode());
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

test "Camera.frameControls" {
    var camera: Camera = .{};
    var keyboard: input.Keyboard = .{};
    // The external camera's key, 7, picks its view once for the press.
    keyboard.down[controls.binding(.external_camera).key] = true;
    camera.frameControls(&keyboard, 0, 1, 100);
    try std.testing.expectEqual(View.external, camera.view);
    try std.testing.expectEqual(100, camera.switched);
    camera.switched = 0;
    camera.frameControls(&keyboard, 0, 1, 200);
    try std.testing.expectEqual(0, camera.switched);

    // In it, the left arrow turns the orbit.
    keyboard.down[input.scan.left] = true;
    camera.frameControls(&keyboard, 0, 10, 300);
    try std.testing.expect(camera.orbit.yaw_speed < 0);

    // The cockpit key, pressed in the cockpit view, cycles the cockpit mode.
    _ = camera.setView(.cockpit, 0, false, false, 0);
    keyboard = .{};
    keyboard.down[controls.binding(.cockpit_camera).key] = true;
    camera.frameControls(&keyboard, 0, 1, 400);
    try std.testing.expectEqual(CockpitMode.cockpit, camera.cockpit_mode);
}
