//! `C:\lancer\game\main.cpp`: a mission's loop. `mission_run` (`0x00494040`) runs a game tick for
//! each tick of the timer and draws a frame with `mission_frame` (`0x004924B0`). **Unverified:** the
//! two lie after `language.cpp`'s code, where `main.cpp`'s begins; by what they do they are this
//! file's.
//!
//! Ported so far: the clocks and the pacing, and how `mission_frame` puts the scene together and
//! draws it. Not yet: the simulation's own work, the HUD, the cockpit, the effects and the rest of
//! what it adds to the scene.

const std = @import("std");
const Allocator = std.mem.Allocator;

const input = @import("../input.zig");
const srapi = @import("../surrender/surrenderlib/srapi.zig");
const srcore = @import("../surrender/surrenderlib/srcore.zig");
const backdrop = @import("backdrop.zig");
const camera = @import("camera.zig");
const nebula = @import("nebula.zig");
const objects = @import("objects.zig");

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
    /// What the loop has already run game ticks for, which `mission_run` keeps to itself.
    ran_to: u32 = 0,
    /// Where the platform's count of hundredths stood at the last tick, in place of the timer.
    timer_at: u64 = 0,

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

    /// Runs `ticks` ticks and takes `now` as where the platform's count has reached, for a
    /// screenshot, which takes a tick a frame so that every run settles alike.
    pub fn advanceBy(clock: *Clock, now: u64, ticks: u32) void {
        clock.timer_at = now;
        clock.advanceTimer(ticks);
    }

    /// What `tick_timer` (`0x004827C0`) does to the clocks, 100 times a second. Its other half,
    /// which keeps the Miles streams and the sound voices going, belongs with the sound.
    pub fn timerTick(clock: *Clock) void {
        clock.timer_ticks +%= 1;
        if (clock.paused) return;
        clock.game_ticks +%= 1;
        clock.play.ticks += 1;
        if (clock.play.ticks > 100) {
            clock.play.ticks = 0;
            // Each unit rolls when it stood past 58 before this one, so each counts 0 to 59.
            const second_over = clock.play.seconds > 58;
            clock.play.seconds += 1;
            if (second_over) {
                clock.play.seconds = 0;
                const minute_over = clock.play.minutes > 58;
                clock.play.minutes += 1;
                if (minute_over) {
                    clock.play.minutes = 0;
                    clock.play.hours +%= 1;
                }
            }
        }
    }

    /// Runs the timer on for `ticks` hundredths of a second.
    pub fn advanceTimer(clock: *Clock, ticks: u32) void {
        for (0..ticks) |_| clock.timerTick();
    }

    /// `simulation_step` (`0x004774D0`): the work of every fourth tick, so 25 times a second, which
    /// is why the [flight model](../../../docs/engine/objects.md#motion) moves at that rate. It
    /// reads the input devices, then runs each object's own updates and moves them all with
    /// `objects_update`. Returns whether it did that work.
    ///
    /// Ported so far: the pacing, and the keyboard `read_keyboard` reads here rather than once a
    /// frame. Not yet: the joystick and the mouse, and the object updates, which the caller stands
    /// in for until they are ported.
    pub fn simulationStep(clock: *Clock, keyboard: *input.Keyboard) bool {
        clock.simulation_counter += 1;
        if (clock.simulation_counter < 4) return false;
        keyboard.read();
        clock.simulation_counter = 0;
        return true;
    }

    /// `game_tick` (`0x00477850`): one tick of the mission. Paused, it counts the tick and does
    /// nothing else. Returns whether the simulation stepped.
    ///
    /// Not ported: the countdown at `0x0052A474` that it steps once a second, and the timed
    /// sections it brackets the tick with outside a network game.
    pub fn gameTick(clock: *Clock, keyboard: *input.Keyboard) bool {
        if (clock.paused) {
            clock.paused_ticks +%= 1;
            return false;
        }
        clock.mission_ticks +%= 1;
        return clock.simulationStep(keyboard);
    }

    /// Runs the next game tick the loop owes, as `mission_run` (`0x00494040`) paces them: one for
    /// each tick of the timer since the last pass. Returns whether the simulation stepped, so that
    /// the caller can do the step's own work, or null once the loop has caught up with the timer.
    pub fn nextTick(clock: *Clock, keyboard: *input.Keyboard) ?bool {
        if (clock.ran_to == clock.game_ticks) return null;
        clock.ran_to +%= 1;
        return clock.gameTick(keyboard);
    }

    /// Every tick the loop owes, for a caller with no work of its own in the step. Returns how many
    /// simulation steps ran.
    pub fn runTicks(clock: *Clock, keyboard: *input.Keyboard) u32 {
        var steps: u32 = 0;
        while (clock.nextTick(keyboard)) |stepped| {
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
    /// The live objects shown, each by its model's nodes.
    models: []objects.Model,
    space: *backdrop.Backdrop,
    sky: *nebula.Sky,
    view: camera.View,
    cockpit_mode: camera.CockpitMode,
    /// Last frame's view (`camera_view_last`, `0x00539A64`).
    last_view: camera.View,
    /// What the models' own lights and engine glows are drawn by.
    attachments: objects.View = .{},
};

/// Puts the frame's scene together and draws it, in `mission_frame`'s order: the objects, the
/// backdrop, the sky; the star streaks are reset when the view has changed since the last frame;
/// then `sr_render`. `arena` holds what the frame needs until it is drawn.
pub fn drawFrame(gpa: Allocator, arena: Allocator, scene: *srcore.Scene, context: *srapi.Context, frame: Frame, driver: srcore.Driver) Allocator.Error!void {
    scene.clear();
    for (frame.models) |*model| try model.draw(gpa, scene, .world, frame.attachments);
    try frame.space.frame(gpa, scene, context, frame.view, frame.cockpit_mode);
    if (context.hardware) try frame.sky.frame(gpa, scene, context);
    if (frame.view != frame.last_view) frame.space.resetStreaks();
    try srcore.render(arena, context, scene, driver);
}

test "the simulation steps on every fourth tick" {
    var clock: Clock = .{};
    var keyboard: input.Keyboard = .{};
    // A second of the timer: 100 ticks, 100 game ticks, 25 steps.
    clock.advanceTimer(100);
    try std.testing.expectEqual(100, clock.game_ticks);
    try std.testing.expectEqual(25, clock.runTicks(&keyboard));
    try std.testing.expectEqual(100, clock.mission_ticks);
    // The ticks already run are not run again.
    try std.testing.expectEqual(0, clock.runTicks(&keyboard));
}

test "a paused game stops its clocks but not the timer" {
    var clock: Clock = .{};
    var keyboard: input.Keyboard = .{};
    clock.advanceTimer(8);
    _ = clock.runTicks(&keyboard);
    clock.paused = true;
    clock.advanceTimer(100);
    // The timer counts the paused ticks; the mission's clocks do not move.
    try std.testing.expectEqual(108, clock.timer_ticks);
    try std.testing.expectEqual(8, clock.game_ticks);
    try std.testing.expectEqual(8, clock.mission_ticks);
    try std.testing.expectEqual(0, clock.runTicks(&keyboard));
    // Paused ticks are counted only for the game ticks the loop asks for.
    clock.paused = false;
    clock.advanceTimer(4);
    try std.testing.expectEqual(1, clock.runTicks(&keyboard));
    try std.testing.expectEqual(12, clock.mission_ticks);
}

test "the step reads the keyboard, and the latches it clears" {
    var clock: Clock = .{};
    var keyboard: input.Keyboard = .{};
    keyboard.down[scan_test_key] = true;
    keyboard.latched[scan_test_key] = true;
    // Three ticks do no work, so the latch stands; the fourth reads and keeps it while held.
    clock.advanceTimer(3);
    _ = clock.runTicks(&keyboard);
    try std.testing.expect(keyboard.latched[scan_test_key]);
    clock.advanceTimer(1);
    try std.testing.expectEqual(1, clock.runTicks(&keyboard));
    try std.testing.expect(keyboard.latched[scan_test_key]);
    // Released, the next read clears it.
    keyboard.down[scan_test_key] = false;
    clock.advanceTimer(4);
    _ = clock.runTicks(&keyboard);
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
    var keyboard: input.Keyboard = .{};
    clock.advanceTimer(10);
    _ = clock.runTicks(&keyboard);
    clock.frameBegin();
    try std.testing.expectEqual(10, clock.frame_duration);
    try std.testing.expectEqual(10, clock.frame_start);
    // A frame with no tick between takes no time.
    clock.frameBegin();
    try std.testing.expectEqual(0, clock.frame_duration);
    clock.advanceTimer(3);
    _ = clock.runTicks(&keyboard);
    clock.frameReset();
    try std.testing.expectEqual(13, clock.frame_start);
    try std.testing.expectEqual(0, clock.frame_duration);
}

test "the clocks keep to the platform's count however the frames fall" {
    var clock: Clock = .{};
    var keyboard: input.Keyboard = .{};
    const began: u64 = 12_345;
    clock.start(began);
    // Frames of uneven length: several shorter than a tick, one spanning many, one long stall.
    const frames = [_]u64{ 1, 0, 3, 1, 0, 0, 7, 2, 500, 1, 4, 0, 1 };
    var steps: u32 = 0;
    var now = began;
    for (frames) |frame| {
        now += frame;
        clock.advanceTo(now);
        steps += clock.runTicks(&keyboard);
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
    var keyboard: input.Keyboard = .{};
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
            steps += clock.runTicks(&keyboard);
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
    var keyboard: input.Keyboard = .{};
    clock.start(0);
    // Four frames inside one hundredth: no tick falls in them, so the simulation stands still.
    for (0..4) |_| {
        clock.advanceTo(0);
        try std.testing.expectEqual(0, clock.runTicks(&keyboard));
        clock.frameBegin();
        try std.testing.expectEqual(0, clock.frame_duration);
    }
    // One frame that took a quarter of a second catches up all 25 ticks at once.
    clock.advanceTo(25);
    try std.testing.expectEqual(6, clock.runTicks(&keyboard));
    clock.frameBegin();
    try std.testing.expectEqual(25, clock.frame_duration);
}
