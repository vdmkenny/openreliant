//! `C:\lancer\game\main.cpp`: a mission's loop. `mission_run` (`0x00494040`) runs a game tick for
//! each tick of the timer and draws a frame with `mission_frame` (`0x004924B0`). **Unverified:** the
//! two lie after `language.cpp`'s code, where `main.cpp`'s begins; by what they do they are this
//! file's.
//!
//! Ported so far: the clocks and the pacing, how `mission_frame` frames the objects and puts the
//! scene together and draws it, what the mission's start (`0x004934F0`) fits the player's ship
//! with, and the armour's conditions (`0x00492370`). Not yet: the effects and the rest of what it
//! adds to the scene.

const std = @import("std");
const Allocator = std.mem.Allocator;

const input = @import("../input.zig");
const libcmt = @import("../libcmt.zig");
const shp = @import("../../formats/shp.zig");
const math = @import("../surrender/math.zig");
const srapi = @import("../surrender/surrenderlib/srapi.zig");
const srapiext = @import("../surrender/surrenderlib/srapiext.zig");
const srcore = @import("../surrender/surrenderlib/srcore.zig");
const srtexture = @import("../surrender/surrenderlib/srtexture.zig");
const backdrop = @import("backdrop.zig");
const camera = @import("camera.zig");
const aigeneric = @import("aigeneric.zig");
const create = @import("create.zig");
const gameobj = @import("gameobj.zig");
const guns = @import("guns.zig");
const explode = @import("explode.zig");
const particles = @import("particles.zig");
const shockwave = @import("shockwave.zig");
const hog_snd = @import("hog_snd.zig");
const hud = @import("hud.zig");
const matmanager = @import("matmanager.zig");
const nebula = @import("nebula.zig");
const objects = @import("objects.zig");
const srofiles = @import("srofiles.zig");
const xtrabits = @import("xtrabits.zig");

// --- The clocks and the loop ---------------------------------------------------------------

/// The play time `tick_timer` keeps (`play_time_ticks` to `play_time_hours`, `0x00565070` to
/// `0x00565076`). A second takes 101 ticks, as the roll below has it, so the play time runs a
/// hundredth slow.
pub const PlayTime = struct {
    ticks: u16 = 0,
    seconds: u16 = 0,
    minutes: u16 = 0,
    hours: u16 = 0,
};

/// A mission's clocks, and the pacing they drive: the timer ticks 100 times a second, the loop
/// runs one game tick for each tick of the timer, and the simulation steps on every fourth.
///
/// **Improvement:** the port has no periodic timer. The platform's monotonic counter of hundredths
/// of a second stands in for the multimedia timer `timer_start` (`0x004A70F0`) sets up, so the
/// clocks advance at the same rate without a thread of their own and without the drift a timer
/// whose period the device rounds would bring.
/// How the mission is ending (`0x00588394`), which its end and the debriefing go by: the player's
/// ship destroyed or its pilot ejecting among them. Nothing ends a mission while it is `playing`.
/// The other endings are not known yet.
pub const Ending = enum(u8) {
    playing = 0,
    destroyed = 1,
    ejecting = 8,
    _,
};

pub const Clock = struct {
    /// `timer_ticks` (`0x005DB8E8`): every tick of the timer, the paused ones included.
    timer_ticks: u32 = 0,
    /// `game_ticks` (`0x00565064`): ticks since the mission started, the paused ones aside.
    game_ticks: u32 = 0,
    /// `mission_ticks` (`0x00587CC4`): ticks `game_tick` has run, the paused ones aside.
    mission_ticks: i32 = 0,
    /// `paused_ticks` (`0x00587CB0`): ticks `game_tick` skipped while the game was paused.
    paused_ticks: u32 = 0,
    play: PlayTime = .{},
    /// `paused` (`0x0057E04C`), which stops the ticks and the script clock.
    paused: bool = false,
    /// `frame_start` (`0x005883B0`): `mission_ticks` when the current frame began.
    frame_start: i32 = 0,
    /// `frame_duration` (`0x00588330`): ticks between the previous frame and this one.
    frame_duration: i32 = 0,
    /// `simulation_counter` (`0x00588718`).
    simulation_counter: u32 = 0,
    /// `simulation_turn` (`0x00562FFC`): the object whose orientation `simulation_step`
    /// orthonormalizes this step (`nextTurn`).
    simulation_turn: u32 = 0,
    /// What the loop has already run game ticks for, which `mission_run` keeps to itself.
    ran_to: u32 = 0,
    /// Where the platform's count of hundredths stood at the last tick, in place of the timer.
    timer_at: u64 = 0,
    /// The port's: how far the platform's time has run past the last tick, as a share of a tick,
    /// which `stepFraction` draws between the ticks by.
    past_tick: f32 = 0,

    /// Zeroes the clocks and takes the platform's count of hundredths of a second as their start,
    /// as `mission_run` zeroes them before it loops.
    pub fn start(clock: *Clock, now: u64) void {
        clock.* = .{ .timer_at = now };
    }

    /// Runs the timer on to `now`, the platform's count of hundredths of a second. The ticks come
    /// from the difference between two counts, never from the length of a frame, so a frame that
    /// falls between two ticks loses nothing, a frame that spans several runs all of them, and the
    /// clocks keep to the platform's count however the frames fall.
    pub fn advanceTo(clock: *Clock, now: u64) void {
        const elapsed = now -% clock.timer_at;
        clock.timer_at = now;
        clock.advanceTimer(@truncate(elapsed));
    }

    /// `advanceTo`, from a finer count: the platform's time in units of which `per_tick` make a
    /// tick. What is left past the last tick is kept for drawing between the ticks.
    pub fn advanceToFine(clock: *Clock, now: u64, per_tick: u64) void {
        clock.advanceTo(now / per_tick);
        clock.past_tick = @as(f32, @floatFromInt(now % per_tick)) / @as(f32, @floatFromInt(per_tick));
    }

    /// Runs `ticks` ticks and takes `now` as where the platform's count has reached, for a
    /// screenshot, which takes a tick a frame so that every run settles alike.
    pub fn advanceBy(clock: *Clock, now: u64, ticks: u32) void {
        clock.timer_at = now;
        clock.past_tick = 0;
        clock.advanceTimer(ticks);
    }

    /// Runs the timer on for `ticks` hundredths of a second.
    pub fn advanceTimer(clock: *Clock, ticks: u32) void {
        for (0..ticks) |_| hog_snd.tickTimer(clock);
    }

    /// Runs the next game tick the loop owes, as `mission_run` (`0x00494040`) paces them: one for
    /// each tick of the timer since the last pass. Returns whether the simulation stepped, or null
    /// once the loop has caught up with the timer.
    pub fn nextTick(clock: *Clock, devices: *input.Devices, world: gameobj.World) ?bool {
        if (clock.ran_to == clock.game_ticks) return null;
        clock.ran_to +%= 1;
        return gameobj.gameTick(clock, devices, world);
    }

    /// Every tick the loop owes. Returns how many simulation steps ran.
    pub fn runTicks(clock: *Clock, devices: *input.Devices, world: gameobj.World) u32 {
        var steps: u32 = 0;
        while (clock.nextTick(devices, world)) |stepped| {
            if (stepped) steps += 1;
        }
        return steps;
    }

    /// `frame_begin` (`0x00491E00`): `frame_duration` becomes the ticks since `frame_start`, and
    /// `frame_start` becomes `mission_ticks`. Code that runs once a frame measures time with these.
    pub fn frameBegin(clock: *Clock) void {
        const began = clock.frame_start;
        clock.frame_start = clock.mission_ticks;
        clock.frame_duration = clock.mission_ticks -% began;
    }

    /// `frame_reset` (`0x00491DE0`).
    pub fn frameReset(clock: *Clock) void {
        clock.frame_start = clock.mission_ticks;
        clock.frame_duration = 0;
    }
};

/// What `mission_frame` draws a frame of.
pub const Frame = struct {
    /// The live objects, each drawn by its model's nodes.
    objects: *create.Objects,
    space: *backdrop.Backdrop,
    sky: *nebula.Sky,
    view: camera.View,
    cockpit_mode: camera.CockpitMode,
    /// Last frame's view (`camera_view_last`, `0x00539A64`).
    last_view: camera.View,
    /// What the models' own lights and engine glows are drawn by; each object's own offset into
    /// its lights' blinks and its glow come from its record.
    attachments: objects.View = .{},
    /// What is drawn over the scene once its layers are done, which is the head-up display.
    overlay: ?srcore.Overlay = null,
    /// The cockpit's model and the radar's backing, which view 0 draws over the world in cockpit
    /// mode 1 under the hardware renderers.
    cockpit: ?*objects.Model = null,
    backing: ?*RadarBacking = null,
    /// Whether DISPLAY KILLS is held, which leaves the backing out.
    kills_shown: bool = false,
    /// The particles, which go into the world's layer after the shots, the explosions' bits and
    /// fireballs, and the shockwaves.
    particles: ?*particles.Pool = null,
    explosions: ?*explode.Explosions = null,
    shockwaves: ?*shockwave.Shockwaves = null,
};

/// `mission_frame` (`0x004924B0`), as far as the objects go: every object's orders, which fly the
/// ships and read the player's controls, then the frames they are drawn at, then the shots in
/// flight (`guns.bulletsFrame`), then the particles (`particles.Pool.frame`), the explosions
/// (`explode.Explosions.frame`) and the shockwaves (`shockwave.Shockwaves.frame`). A mission and the sandbox alike run this once a frame, before the
/// camera's own frame and anything drawn.
///
/// Not ported: the rest of the frame's work, which is the mission's events, its scripts and the
/// missiles ([#30](https://github.com/vdmkenny/openreliant/issues/30),
/// [#39](https://github.com/vdmkenny/openreliant/issues/39)).
pub fn missionFrame(orders: aigeneric.Context, fraction: f32) void {
    aigeneric.ordersUpdate(orders);
    frameObjects(orders.world.objects, fraction);
    guns.bulletsFrame(orders.world, orders.clock, fraction);
    if (orders.world.particles) |pool| pool.frame(orders.clock);
    if (orders.world.explosions) |explosions| explosions.frame(orders.world);
    if (orders.world.shockwaves) |waves| waves.frame(orders.world);
}

/// `mission_frame`'s pass over the objects before the camera's frame: each live object, save
/// stand-ins and disabled and jumping ones, has `missile_homing` cleared and is framed `fraction`
/// of the way through the simulation's step (`objects.frameTree`).
///
/// Not ported yet: the cloak's frame (`0x004639B0`).
pub fn frameObjects(all: *create.Objects, fraction: f32) void {
    var walk = all.walk();
    while (walk.next()) |index| {
        const slot = &all.slots[index];
        const object = &slot.object;
        if (object.flags.stand_in or object.flags.disabled or object.flags.jumping) continue;
        object.missile_homing = 0;
        objects.frameTree(&object.root, if (slot.model) |*model| model else null, &slot.drawn, fraction);
    }
}

/// Puts the frame's scene together and draws it, in `mission_frame`'s order: the objects
/// (`drawObjects`), the backdrop, the sky; the star streaks are reset when the view has changed
/// since the last frame; then `sr_render`. `arena` holds what the frame needs until it is drawn.
pub fn drawFrame(gpa: Allocator, arena: Allocator, scene: *srcore.Scene, context: *srapi.Context, frame: Frame, driver: srcore.Driver) Allocator.Error!void {
    scene.clear();
    // How far off an object stops being worth drawing follows the frame's own projection, so the
    // caller does not have to hand it over with the rest.
    var attachments = frame.attachments;
    attachments.scale = context.projection.scale[0];
    try drawObjects(gpa, scene, frame.objects, attachments);
    try guns.drawBullets(gpa, scene, &frame.objects.bullets, context.hardware);
    if (frame.particles) |pool| try pool.draw(gpa, scene);
    if (frame.explosions) |explosions| try explosions.draw(gpa, scene);
    if (frame.shockwaves) |waves| try waves.draw(gpa, scene);
    try frame.space.frame(gpa, scene, context, frame.view, frame.cockpit_mode);
    if (context.hardware) try frame.sky.frame(gpa, scene, context);
    if (frame.view == .cockpit and frame.cockpit_mode == .cockpit and context.hardware) {
        // The backing, then the hands, then the cockpit, all over the world, sorted by depth.
        if (frame.backing) |backing| if (!frame.kills_shown) try xtrabits.sceneAdd(gpa, scene, .{ .mesh = &backing.object }, .overlay);
        if (frame.cockpit) |model| {
            for ([_]usize{ cockpit_hands, cockpit_frame }) |index| {
                if (index < model.parts.len) try xtrabits.sceneAdd(gpa, scene, .{ .mesh = &model.parts[index].object }, .overlay);
            }
        }
    }
    if (frame.view != frame.last_view) frame.space.resetStreaks();
    try srcore.render(arena, context, scene, driver, frame.overlay);
}

/// `mission_frame`'s pass that draws the objects: each live object, save stand-ins and disabled
/// and jumping ones, is drawn with `object_draw` (`objects.Model.draw`), with its own offset into
/// its lights' blinks, its lights unless `lights_disabled`, its engine glows burning by the
/// throttle of its last update times the share of its engines left, and nothing at all while it is
/// `hidden`, as the ship the camera sits in is.
///
/// Not ported yet: the cloak; what else the pass draws for a few types, and the damage's smoke and
/// its models (#41); the cutaway scenes' own rules, and the gate's tunnel, in which no object is
/// drawn.
pub fn drawObjects(gpa: Allocator, scene: *srcore.Scene, all: *create.Objects, attachments: objects.View) Allocator.Error!void {
    var walk = all.walk();
    while (walk.next()) |index| {
        const slot = &all.slots[index];
        const object = &slot.object;
        if (object.flags.stand_in or object.flags.disabled or object.flags.jumping) continue;
        if (object.flags.hidden) continue;
        const model = if (slot.model) |*model| model else continue;
        var view = attachments;
        view.blink_offset = object.blink_offset;
        view.lights = !object.flags.lights_disabled;
        view.throttle = object.last_throttle * object.engines_intact;
        try model.draw(gpa, scene, .world, view);
    }
}

test "the objects are framed and drawn, save those left out" {
    const gpa = std.testing.allocator;
    var random: libcmt.Rand = .{};
    const all = try create.Objects.create(gpa, &random);
    defer all.destroy();
    var model: create.testing.Model = undefined;
    try model.init(gpa);
    defer model.deinit(gpa);
    var tables = create.testing.tables();
    for (0..4) |place| {
        const at: math.Vector = .{ @floatFromInt(place * 100), 0, 0 };
        _ = try create.createObject(all, &tables, model.types(), null, .predator, at, &random);
    }
    // The first is the ship the camera sits in, the second is disabled and the third jumping.
    all.slots[0].object.flags.hidden = true;
    all.slots[1].object.flags.disabled = true;
    all.slots[2].object.flags.jumping = true;
    all.slots[3].object.missile_homing = 1;
    frameObjects(all, 0);
    // Each framed one stands where it was made, and the pass clears the missile warning.
    try std.testing.expectEqual(math.Vector{ 300, 0, 0 }, all.slots[3].drawn.position);
    try std.testing.expectEqual(0, all.slots[3].object.missile_homing);
    var scene: srcore.Scene = .{};
    defer scene.deinit(gpa);
    try drawObjects(gpa, &scene, all, .{});
    // Only the fourth is drawn: its one part.
    try std.testing.expectEqual(1, scene.layers.get(.world).items.len);
    try std.testing.expectEqual(math.Vector{ 300, 0, 0 }, scene.layers.get(.world).items[0].mesh.position);
}

// --- The cockpit ----------------------------------------------------------------------------

/// The cockpit model's two parts `mission_frame` draws: the cockpit's frame and the pilot's hands.
/// A model with more has the rest left out; the Phoenix's has a third, its base.
pub const cockpit_frame = 0;
pub const cockpit_hands = 1;

/// How far the cockpit's every level of detail reaches: the mission's start pushes them all out
/// to this, so the finest is always the one drawn.
pub const cockpit_detail: f32 = 1048576;

/// The lights' masks that reach the cockpit's parts, as a mask of those that do not (`+0xDC`).
pub const cockpit_light_mask: u32 = 0x12;

/// The cockpit as the mission's start (`0x004934F0`) makes it: an object of its own
/// (`0x005883F4`) with a part for each of the cockpit frame model's, each drawn always
/// (`always_drawn`), reached only by the lights `cockpit_light_mask` lets through, and with every
/// level pushed out to `cockpit_detail`; its root then hangs from the camera's frame. Its parts
/// hang as an object's do, its origin at their centre of mass (`object_link_parts`). The levels
/// are made in `gpa`.
pub fn createCockpit(gpa: Allocator, model: *const shp.Model, loaded: *const srofiles.Loaded) Allocator.Error!objects.Model {
    var cockpit: objects.Model = try .create(gpa, model, loaded, .{});
    for (cockpit.parts) |*part| try fitCockpitPart(gpa, part);
    gameobj.linkParts(&cockpit, model);
    return cockpit;
}

/// What the start does to each of the cockpit's parts.
fn fitCockpitPart(gpa: Allocator, part: *objects.Model.Part) Allocator.Error!void {
    part.object.flags.always_drawn = true;
    part.object.light_mask = cockpit_light_mask;
    const levels = try gpa.dupe(srapiext.Level, part.object.levels);
    for (levels) |*level| level.until = cockpit_detail;
    part.object.levels = levels;
}

/// What `camera_frame` reads of the cockpit's model to move it, for a ship turning at `rates`,
/// each over its full rate, and flying at `speed`, over its cruise speed.
pub fn cockpitInput(cockpit: *const objects.Model, model: *const shp.Model, rates: [3]f32, speed: f32) ?camera.Cockpit.Input {
    if (cockpit.parts.len <= cockpit_hands) return null;
    const eye = model.header.eye;
    const pivot = model.parts[cockpit_hands].part.mount_point;
    return .{
        .rates = rates,
        .speed = speed,
        .eye = .{ eye.x, eye.y, eye.z },
        .hands_origin = cockpit.parts[cockpit_hands].origin,
        .hands_pivot = .{ pivot.x, pivot.y, pivot.z },
    };
}

/// Places the cockpit's parts in the world for the camera at `at`: its root hangs from the
/// camera's frame where `placed` puts it, each part stands from the root as it does in the model,
/// and the hands where the camera turned them.
pub fn placeCockpit(cockpit: *objects.Model, at: camera.Place, placed: camera.Cockpit.Placed) void {
    const root = placed.root.within(at);
    cockpit.place(root.position, root.orientation);
    if (cockpit.parts.len <= cockpit_hands) return;
    const hands = placed.hands.within(root);
    const object = &cockpit.parts[cockpit_hands].object;
    object.position = hands.position;
    object.orientation = hands.orientation;
}

/// The radar's backing (`0x005883BC`), which the mission's start makes and the cockpit's view
/// draws first: a rectangle across the radar, from 65 left of the middle of the screen to 67
/// right, and 32 either side of the radar's height, `radaralpha`'s disc on it, 75% black. The
/// start unprojects its corners to 1000 in front of the camera, and the object stands in the
/// camera's frame, so it keeps its place on the screen.
///
/// **Improvement.** The port keeps it on the radar as the display is scaled: its corners are
/// measured in the display's pixels from where the radar stands, and worked out again each frame
/// for the window's size.
pub const RadarBacking = struct {
    positions: [4]math.Vector,
    normals: [4]math.Vector = @splat(@splat(0)),
    polygons: [1]srapiext.Polygon = .{.{ .kind = .triangle, .continues = 0, .first = 0, .count = 4 }},
    indices: [4]u16 = .{ 0, 1, 2, 3 },
    planes: [1]srapiext.Plane = .{.{ .normal = @splat(0), .distance = 0 }},
    biases: [1]f32 = .{0},
    surfaces: [1]srapiext.Surface,
    baked: [4][4]f32 = @splat(colour),
    uv: [4][2]f32 = .{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } },
    mesh: srapiext.Mesh,
    levels: [1]srapiext.Level,
    object: srapiext.MeshObject,

    /// Its corners across from the middle of the screen, and down from the radar's point.
    pub const across: [2]i32 = .{ -65, 67 };
    pub const down: [2]i32 = .{ -32, 32 };
    /// How far in front of the camera the corners stand.
    pub const depth: f32 = 1000;
    pub const colour: [4]f32 = .{ 0, 0, 0, 0.75 };
    pub const texture_name = "radaralpha";

    /// Makes the backing, with its texture from `textures`, as the start does: lit by its own
    /// colours, textured by its own coordinates and blended by alpha, never culled.
    pub fn create(gpa: Allocator, textures: *srtexture.Table) matmanager.Error!*RadarBacking {
        const texture = try matmanager.textureRequire(textures, texture_name);
        const backing = try gpa.create(RadarBacking);
        backing.* = .{
            .positions = @splat(@splat(0)),
            .surfaces = .{.{ .polygons = 1, .material = .{
                .two_pass = false,
                ._unknown_01 = 0,
                .coordinates = .{ .generated, .none },
                .lit = .{ true, false },
                .blend = .{ .alpha, .off },
                .image = .{ .null, .null },
            }, .textures = .{ .{ .image = texture }, .none } }},
            .mesh = undefined,
            .levels = undefined,
            .object = undefined,
        };
        backing.mesh = .{
            .positions = &backing.positions,
            .normals = &backing.normals,
            .polygons = &backing.polygons,
            .indices = &backing.indices,
            .uv = .{ null, null },
            .planes = &backing.planes,
            .biases = &backing.biases,
            .surfaces = &backing.surfaces,
            .baked = &backing.baked,
            .bounds = undefined,
            .radius = undefined,
        };
        backing.levels = .{.{ .mesh = &backing.mesh, .until = std.math.inf(f32) }};
        backing.object = .{
            .flags = .{ .not_culled = true, .baked_mesh = true, .own_first = true },
            .position = @splat(0),
            .radius = 0,
            .levels = &backing.levels,
            .own_uv = .{ &backing.uv, null },
        };
        return backing;
    }

    /// Puts the corners on the radar for this frame's `projection`, and the object at the camera.
    pub fn place(backing: *RadarBacking, projection: srapi.Projection, at: camera.Place, scale: f32) void {
        backing.positions = corners(projection, scale);
        srapi.findBoundingBox(&backing.mesh);
        backing.object.radius = backing.mesh.radius;
        backing.object.position = at.position;
        backing.object.orientation = at.orientation;
    }

    /// The corners in the camera's frame: across from the middle of the screen and down from the
    /// radar's height, in the display's pixels, unprojected to `depth`.
    pub fn corners(projection: srapi.Projection, scale: f32) [4]math.Vector {
        const radar = hud.place(projection.screen, hud.Radar.offset, hud.Radar.across, hud.Radar.down, scale);
        const around = [4][2]i32{ .{ across[0], down[0] }, .{ across[1], down[0] }, .{ across[1], down[1] }, .{ across[0], down[1] } };
        var out: [4]math.Vector = undefined;
        for (&out, around) |*position, corner| {
            const x = @as(f32, @floatFromInt(corner[0])) * scale;
            const y = @as(f32, @floatFromInt(radar[1])) + @as(f32, @floatFromInt(corner[1])) * scale - projection.centre[1];
            position.* = .{ x * depth / projection.scale[0], y * depth / projection.scale[1], depth };
        }
        return out;
    }
};

test "each cockpit part is drawn always, from its finest level" {
    const gpa = std.testing.allocator;
    const srmesh = @import("../surrender/surrenderlib/srmesh.zig");
    const mesh = try srmesh.testing.square(gpa);
    defer mesh.deinit(gpa);
    const levels = [_]srapiext.Level{ .{ .mesh = &mesh, .until = 1000 }, .{ .mesh = &mesh, .until = 5000 } };
    var part: objects.Model.Part = .{
        .hidden = false,
        .parent = null,
        .origin = @splat(0),
        .object = .{ .flags = .{}, .position = @splat(0), .radius = 1, .levels = &levels },
    };
    try fitCockpitPart(gpa, &part);
    defer gpa.free(part.object.levels);
    try std.testing.expect(part.object.flags.always_drawn);
    try std.testing.expectEqual(cockpit_light_mask, part.object.light_mask);
    for (part.object.levels) |level| try std.testing.expectEqual(cockpit_detail, level.until);
    // The model's own levels are left as they were.
    try std.testing.expectEqual(1000, levels[0].until);
}

test placeCockpit {
    var parts = [_]objects.Model.Part{
        .{ .hidden = false, .parent = null, .origin = .{ 0, 0, 100 }, .object = .{ .flags = .{}, .position = @splat(0), .radius = 1, .levels = &.{} } },
        .{ .hidden = false, .parent = null, .origin = .{ 0, 0, 50 }, .object = .{ .flags = .{}, .position = @splat(0), .radius = 1, .levels = &.{} } },
    };
    var model: objects.Model = .{ .parts = &parts, .order = &.{ 0, 1 }, .lights = &.{}, .glows = &.{}, .mounts = &.{} };
    // The camera turned a quarter about Y: the root, set back from the eye, turns with it.
    const at: camera.Place = .{ .position = .{ 1000, 0, 0 }, .orientation = math.rotation(.y, std.math.pi / 2.0) };
    const placed: camera.Cockpit.Placed = .{
        .root = .{ .position = .{ 0, 0, -300 }, .orientation = math.identity },
        .hands = .{ .position = .{ 0, 10, 0 }, .orientation = math.identity },
    };
    placeCockpit(&model, at, placed);
    const root = at.position + math.transform(at.orientation, .{ 0, 0, -300 });
    const frame_at: [3]f32 = root + math.transform(at.orientation, .{ 0, 0, 100 });
    for (frame_at, @as([3]f32, parts[cockpit_frame].object.position)) |e, a| try std.testing.expectApproxEqAbs(e, a, 1e-3);
    // The hands stand where the camera put them, not at their origin.
    const hands_at: [3]f32 = root + math.transform(at.orientation, .{ 0, 10, 0 });
    for (hands_at, @as([3]f32, parts[cockpit_hands].object.position)) |e, a| try std.testing.expectApproxEqAbs(e, a, 1e-3);
}

test "the radar's backing stands where the radar does" {
    // At 640 by 480 and the game's scale, the corners project back to 65 left of the middle to
    // 67 right, and 32 either side of the radar's height, 68 above the foot.
    const projection = srapi.Projection.init(640, 480, .{ 0, 0, 1, 1 }, camera.factors);
    const corners = RadarBacking.corners(projection, 1);
    for (corners, [4][2]f32{ .{ 320 - 65, 480 - 68 - 32 }, .{ 320 + 67, 480 - 68 - 32 }, .{ 320 + 67, 480 - 68 + 32 }, .{ 320 - 65, 480 - 68 + 32 } }) |corner, expected| {
        const screen = projection.transform(corner);
        try std.testing.expectApproxEqAbs(expected[0], screen.x, 0.01);
        try std.testing.expectApproxEqAbs(expected[1], screen.y, 0.01);
    }
}

// --- The armour ---------------------------------------------------------------------------

/// `0x00492370`: what an object's armour does to it, from how much of each quadrant's armour is
/// left of its full armour, `6 * ShipCombat.armor_class - 1`, the fore quadrant being the third
/// and the aft the fourth: the guns' condition (`gun_condition`), half the fore one's share and a
/// quarter of each side's; the cruise speed (`armor_speed_factor`), a quarter plus three quarters
/// of the aft one's; and the shields' recharge (`shield_condition`), a quarter of each quadrant's.
/// `create_object` runs it once the armour is full, and the damage as it wears. **Unverified:** it
/// lies after `language.cpp`'s code, where `main.cpp`'s begins, next to `mission_frame`. For the
/// player's ship it goes on to the warning (`armorWarning`).
pub fn armorConditions(object: *gameobj.GameObject, combat: *const create.ShipCombat) void {
    const full: f32 = @floatFromInt(combat.armor_class * 6 - 1);
    const fore = object.armor.fore / full;
    const aft = object.armor.aft / full;
    const sides = (object.armor.left / full) * 0.25 + (object.armor.right / full) * 0.25;
    object.gun_condition = fore * 0.5 + sides;
    object.armor_speed_factor = aft * 0.75 + 0.25;
    object.shield_condition = fore * 0.25 + aft * 0.25 + sides;
}

/// The rest of `object_armor_conditions` (`0x00492370`), for the player's ship: once a quadrant has
/// lost its shield and half its armour, the cockpit's warning, sound 1 of `betty.fat`, no more than
/// once in 500 ticks.
pub fn armorWarning(hearing: hog_snd.Hearing, object: *const gameobj.GameObject, combat: *const create.ShipCombat) void {
    const sound = hearing.sound;
    const frame_start = hearing.clock.frame_start;
    if (frame_start - sound.armor_warned_at <= 500) return;
    const half = @as(f32, @floatFromInt(combat.armor_class * 6 - 1)) * 0.5;
    for (object.shields.values(), object.armor.values()) |shield, armor| {
        if (shield > 0 or armor >= half) continue;
        if (sound.betty) |bank| _ = sound.play(bank, 1, 127, 1, 64, 0);
        sound.armor_warned_at = frame_start;
        return;
    }
}

test armorWarning {
    const mss = @import("../mss.zig");
    var mixer: mss.Mixer = .init(22050);
    const driver = mixer.driver();
    var sound: hog_snd.Sound = undefined;
    sound.init(driver, 2, null);
    const bytes = comptime hog_snd.testing.bank(2);
    sound.betty = try @import("../../formats/fat.zig").Bank.parse(&bytes);
    var clock: Clock = .{ .frame_start = 1000 };
    const view: camera.Place = .{ .position = @splat(0), .orientation = math.identity };
    const hearing: hog_snd.Hearing = .{ .sound = &sound, .camera = &view, .clock = &clock };
    const combat = std.mem.zeroInit(create.ShipCombat, .{ .armor_class = 5 });
    var object = gameobj.testing.object();
    object.shields = .all(10);
    object.armor = .all(29);

    // Whole, or with its shields up, no warning.
    armorWarning(hearing, &object, &combat);
    object.armor.left = 10;
    armorWarning(hearing, &object, &combat);
    try std.testing.expectEqual(0, sound.armor_warned_at);
    // A quadrant with its shield gone and under half its armour warns, and not again for 500
    // ticks.
    object.shields.left = 0;
    armorWarning(hearing, &object, &combat);
    try std.testing.expectEqual(1000, sound.armor_warned_at);
    clock.frame_start = 1400;
    armorWarning(hearing, &object, &combat);
    try std.testing.expectEqual(1000, sound.armor_warned_at);
}

test armorConditions {
    var object = gameobj.testing.object();
    const combat = std.mem.zeroInit(create.ShipCombat, .{ .armor_class = 5 });
    // Whole, everything works fully.
    object.armor = .all(29);
    armorConditions(&object, &combat);
    try std.testing.expectEqual(1, object.gun_condition);
    try std.testing.expectEqual(1, object.armor_speed_factor);
    try std.testing.expectEqual(1, object.shield_condition);
    // With the aft armour gone the ship is down to a quarter of its speed, and its shields to
    // three quarters; the guns, at the fore, are untouched.
    object.armor.aft = 0;
    armorConditions(&object, &combat);
    try std.testing.expectEqual(1, object.gun_condition);
    try std.testing.expectEqual(0.25, object.armor_speed_factor);
    try std.testing.expectEqual(0.75, object.shield_condition);
}

// --- The mission's start -------------------------------------------------------------------

/// A ship the player can fly, as the mission's start (`0x004934F0`) knows it.
pub const PlayerShip = struct {
    /// The model of the cockpit's frame, which the start loads into `0x0057E048`.
    cockpit: []const u8,
    /// **Unknown.** What the start keeps at `0x005883C0` for the ship.
    _unknown_5883c0: u16,
    spectral_shields: bool = false,
    blind_fire: bool = false,
};

/// The twelve ships the player can fly, by ship type.
///
/// **Unverified:** the start also loads `kamg_frm.shp` for any ship when the word at `0x00562DC8`,
/// which looks like the mission's number, is 25 and `0x00587CDC` is clear.
pub const player_ships = [_]PlayerShip{
    .{ .cockpit = "preg_frm.shp", ._unknown_5883c0 = 0x116, .blind_fire = true },
    .{ .cockpit = "nagg_frm.shp", ._unknown_5883c0 = 0x10E, .spectral_shields = true },
    .{ .cockpit = "gre2_frm.shp", ._unknown_5883c0 = 0x108 },
    .{ .cockpit = "cru3_frm.shp", ._unknown_5883c0 = 0x107, .spectral_shields = true },
    .{ .cockpit = "coyg_frm.shp", ._unknown_5883c0 = 0x106, .blind_fire = true },
    .{ .cockpit = "mirg_frm.shp", ._unknown_5883c0 = 0x10B },
    .{ .cockpit = "temg_frm.shp", ._unknown_5883c0 = 0x11B, .spectral_shields = true },
    .{ .cockpit = "pat2_frm.shp", ._unknown_5883c0 = 0x10F, .blind_fire = true },
    .{ .cockpit = "wolv_frm.shp", ._unknown_5883c0 = 0x11E },
    .{ .cockpit = "rea2_frm.shp", ._unknown_5883c0 = 0x117, .blind_fire = true },
    .{ .cockpit = "shr2_frm.shp", ._unknown_5883c0 = 0x11A, .spectral_shields = true, .blind_fire = true },
    .{ .cockpit = "phe2_frm.shp", ._unknown_5883c0 = 0x112, .blind_fire = true },
};

/// Where the second set of the player's ship types starts: types `0xF4` to `0xFF`, whose models
/// are the first twelve's `t_` twins, are the same twelve ships to the start.
pub const player_twins_first = 0xF4;

/// The player's ship of `ship_type`, or null for a type the start has none for.
pub fn playerShip(ship_type: u32) ?PlayerShip {
    const index = if (ship_type >= player_twins_first) ship_type - player_twins_first else ship_type;
    return if (index < player_ships.len) player_ships[index] else null;
}

/// Fits the display's devices to the player's ship, as the start does after `hud_init` has set
/// the display up: every ship carries an ECM, the ships of `player_ships` that say so spectral
/// shields and blind fire, and a ship whose model can cloak (`shp.Header.Flags.cloak`) a cloak.
/// Blind fire starts on where it is carried; elsewhere it is left as it was.
pub fn fitDevices(display: *hud.State, ship_type: u32, can_cloak: bool) void {
    const ship = playerShip(ship_type);
    display.devices.getPtr(.ecm).setting = .off;
    const spectral = if (ship) |known| known.spectral_shields else false;
    display.devices.getPtr(.spectral_shields).setting = if (spectral) .off else .absent;
    display.devices.getPtr(.cloak).setting = if (can_cloak) .off else .absent;
    display.blind_fire_fitted = if (ship) |known| known.blind_fire else false;
    if (display.blind_fire_fitted) display.blind_fire = true;
}

test fitDevices {
    // The Shroud carries all three, and a cloak where its model has one.
    var display: hud.State = .{ .blind_fire = false };
    fitDevices(&display, 10, true);
    try std.testing.expectEqual(.off, display.devices.get(.spectral_shields).setting);
    try std.testing.expectEqual(.off, display.devices.get(.cloak).setting);
    try std.testing.expect(display.blind_fire_fitted and display.blind_fire);
    // Its twin is the same ship.
    try std.testing.expectEqual(playerShip(10), playerShip(0xFE));
    // The Grendel carries only the ECM.
    fitDevices(&display, 2, false);
    try std.testing.expectEqual(.off, display.devices.get(.ecm).setting);
    try std.testing.expectEqual(.absent, display.devices.get(.spectral_shields).setting);
    try std.testing.expectEqual(.absent, display.devices.get(.cloak).setting);
    try std.testing.expect(!display.blind_fire_fitted);
    // A capital ship is none of the player's.
    try std.testing.expectEqual(null, playerShip(0x0D));
}

test missionFrame {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    // The player's slot, then a ship that turns on the spot under an order of its own.
    for (0..2) |_| _ = try mission.add(.predator, @splat(0));
    const orders = mission.orders();
    try std.testing.expect(try aigeneric.push(orders, 1, .slow_rotate, .{ .kind = .ship, .index = -1, .component = -1 }));

    missionFrame(orders, 0);
    // The frame ran the ship's order, and framed every object where it is drawn.
    try std.testing.expect(mission.objects.slots[1].object.yaw_input > 0);
    try std.testing.expect(!mission.objects.slots[1].object.root.flags.unframed);
}

test "the simulation steps on every fourth tick" {
    var clock: Clock = .{};
    var devices: input.Devices = .{};
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    // A second of the timer: 100 ticks, 100 game ticks, 25 steps.
    clock.advanceTimer(100);
    try std.testing.expectEqual(100, clock.game_ticks);
    try std.testing.expectEqual(25, clock.runTicks(&devices, mission.world()));
    try std.testing.expectEqual(100, clock.mission_ticks);
    // The ticks already run are not run again.
    try std.testing.expectEqual(0, clock.runTicks(&devices, mission.world()));
}

test "a paused game stops its clocks but not the timer" {
    var clock: Clock = .{};
    var devices: input.Devices = .{};
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    clock.advanceTimer(8);
    _ = clock.runTicks(&devices, mission.world());
    clock.paused = true;
    clock.advanceTimer(100);
    // The timer counts the paused ticks; the mission's clocks do not move.
    try std.testing.expectEqual(108, clock.timer_ticks);
    try std.testing.expectEqual(8, clock.game_ticks);
    try std.testing.expectEqual(8, clock.mission_ticks);
    try std.testing.expectEqual(0, clock.runTicks(&devices, mission.world()));
    // Paused ticks are counted only for the game ticks the loop asks for.
    clock.paused = false;
    clock.advanceTimer(4);
    try std.testing.expectEqual(1, clock.runTicks(&devices, mission.world()));
    try std.testing.expectEqual(12, clock.mission_ticks);
}

test "the step reads the keyboard, and the latches it clears" {
    var clock: Clock = .{};
    var devices: input.Devices = .{};
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const keyboard = &devices.keyboard;
    keyboard.down[scan_test_key] = true;
    keyboard.latched[scan_test_key] = true;
    // Three ticks do no work, so the latch stands; the fourth reads and keeps it while held.
    clock.advanceTimer(3);
    _ = clock.runTicks(&devices, mission.world());
    try std.testing.expect(keyboard.latched[scan_test_key]);
    clock.advanceTimer(1);
    try std.testing.expectEqual(1, clock.runTicks(&devices, mission.world()));
    try std.testing.expect(keyboard.latched[scan_test_key]);
    // Released, the next read clears it.
    keyboard.down[scan_test_key] = false;
    clock.advanceTimer(4);
    _ = clock.runTicks(&devices, mission.world());
    try std.testing.expect(!keyboard.latched[scan_test_key]);
}

const scan_test_key: u8 = 0x10;

test "play time rolls a second over after 101 ticks" {
    var clock: Clock = .{};
    clock.advanceTimer(101);
    try std.testing.expectEqual(0, clock.play.ticks);
    try std.testing.expectEqual(1, clock.play.seconds);
    // A minute takes 60 of those seconds, and an hour 60 minutes.
    clock.advanceTimer(101 * 59);
    try std.testing.expectEqual(0, clock.play.seconds);
    try std.testing.expectEqual(1, clock.play.minutes);
    clock.advanceTimer(101 * 60 * 59);
    try std.testing.expectEqual(0, clock.play.minutes);
    try std.testing.expectEqual(1, clock.play.hours);
}

test "a frame measures the ticks since the last one" {
    var clock: Clock = .{};
    var devices: input.Devices = .{};
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    clock.advanceTimer(10);
    _ = clock.runTicks(&devices, mission.world());
    clock.frameBegin();
    try std.testing.expectEqual(10, clock.frame_duration);
    try std.testing.expectEqual(10, clock.frame_start);
    // A frame with no tick between takes no time.
    clock.frameBegin();
    try std.testing.expectEqual(0, clock.frame_duration);
    clock.advanceTimer(3);
    _ = clock.runTicks(&devices, mission.world());
    clock.frameReset();
    try std.testing.expectEqual(13, clock.frame_start);
    try std.testing.expectEqual(0, clock.frame_duration);
}

test "the clocks keep to the platform's count however the frames fall" {
    var clock: Clock = .{};
    var devices: input.Devices = .{};
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const began: u64 = 12_345;
    clock.start(began);
    // Frames of uneven length: several shorter than a tick, one spanning many, one long stall.
    const frames = [_]u64{ 1, 0, 3, 1, 0, 0, 7, 2, 500, 1, 4, 0, 1 };
    var steps: u32 = 0;
    var now = began;
    for (frames) |frame| {
        now += frame;
        clock.advanceTo(now);
        steps += clock.runTicks(&devices, mission.world());
    }
    // Every hundredth between the first count and the last is a tick, and every fourth a step.
    const elapsed: u32 = @intCast(now - began);
    try std.testing.expectEqual(520, elapsed);
    try std.testing.expectEqual(elapsed, clock.timer_ticks);
    try std.testing.expectEqual(elapsed, clock.game_ticks);
    try std.testing.expectEqual(@as(i32, @intCast(elapsed)), clock.mission_ticks);
    try std.testing.expectEqual(elapsed / 4, steps);
    // Frames shorter than a tick neither run one nor lose one: the count rules.
    try std.testing.expectEqual(now, clock.timer_at);
}

test "the frame rate is decoupled from the tick rate" {
    var devices: input.Devices = .{};
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    // The same second of play, drawn at three very different frame rates.
    const rates = [_]u64{ 4, 60, 240 };
    for (rates) |frames| {
        var clock: Clock = .{};
        clock.start(1_000);
        var steps: u32 = 0;
        var drawn: u32 = 0;
        for (1..frames + 1) |frame| {
            // Frame `frame` of `frames` ends this far into the second, in hundredths.
            clock.advanceTo(1_000 + @as(u64, @intCast(frame)) * 100 / frames);
            steps += clock.runTicks(&devices, mission.world());
            clock.frameBegin();
            drawn += 1;
        }
        // However often it drew, a second of play is 100 ticks and 25 simulation steps.
        try std.testing.expectEqual(frames, drawn);
        try std.testing.expectEqual(100, clock.game_ticks);
        try std.testing.expectEqual(100, clock.mission_ticks);
        try std.testing.expectEqual(25, steps);
    }
}

test "a frame faster than the tick runs none, and a slow one runs the lot" {
    var clock: Clock = .{};
    var devices: input.Devices = .{};
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    clock.start(0);
    // Four frames inside one hundredth: no tick falls in them, so the simulation stands still.
    for (0..4) |_| {
        clock.advanceTo(0);
        try std.testing.expectEqual(0, clock.runTicks(&devices, mission.world()));
        clock.frameBegin();
        try std.testing.expectEqual(0, clock.frame_duration);
    }
    // One frame that took a quarter of a second catches up all 25 ticks at once.
    clock.advanceTo(25);
    try std.testing.expectEqual(6, clock.runTicks(&devices, mission.world()));
    clock.frameBegin();
    try std.testing.expectEqual(25, clock.frame_duration);
}
