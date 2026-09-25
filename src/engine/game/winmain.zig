//! `C:\lancer\game\winmain.cpp`: the game's entry, `WinMain` (`0x004A8B10`), and its message pump.
//! **Unverified:** the pump (`0x004AAB20`) lies after the last of the file's code that its
//! assertions place; by what it does it is this file's.
//!
//! Ported so far: what the pump does as the game's window goes inactive and active again, as far
//! as the sound and the pause go. `openreliant`'s own frame loop stands in for the rest.

const std = @import("std");

const main = @import("main.zig");
const Clock = main.Clock;
const input = @import("../input.zig");
const camera = @import("camera.zig");
const hog_snd = @import("hog_snd.zig");
const hudoptions = @import("hudoptions.zig");
const Sound = hog_snd.Sound;

/// The window's activation, as the pump follows it.
pub const App = struct {
    /// Whether the game's window is the active one. The pump goes by `window_suspended`
    /// (`0x005DDD28`), which `0x004A8260` sets as it puts the window away and `input_init`
    /// clears, while the renderer runs (`app_active`, `0x005D6CAC`). **Unverified:** what puts the
    /// window away.
    active: bool = true,
    /// `app_inactive_paused` (`0x005D6CAD`): whether the pump has paused the game for the window
    /// going inactive.
    paused: bool = false,
};

/// `message_pump` (`0x004AAB20`), the part that follows the window's activation. Going inactive,
/// the music, the 3D voices and the voices pause, and the pump waits on the window's messages
/// until it is active again; then the sound goes on. Only in a multiplayer session does it pause
/// the mission as well (`game_pause`), which it then leaves in its pause menu. The textures, which
/// DirectDraw loses with the window, need nothing in the port.
///
/// **Improvement.** The port pauses the mission into its menu in single player too, where the game
/// pauses only the sound and the timer's ticks pile up while the window is away. Active again, the
/// music goes on; the rest waits for the menu's CONTINUE.
pub fn followActivation(app: *App, pausing: main.Pausing) !void {
    if (app.active and app.paused) {
        pausing.sound.pauseMusic(false);
        app.paused = false;
    } else if (!app.active and !app.paused) {
        pausing.sound.pauseMusic(true);
        try main.pause(pausing, true);
        app.paused = true;
    }
}

test followActivation {
    const mss = @import("../mss.zig");
    const fat = @import("../../formats/fat.zig");
    const gpa = std.testing.allocator;
    var mixer: mss.Mixer = .init(22050);
    const driver = mixer.driver();
    var sound: Sound = undefined;
    sound.init(driver, 2, null);
    const bytes = comptime hog_snd.testing.bank(2);
    const v = sound.play(try fat.Bank.parse(&bytes), 1, hog_snd.loudest, hog_snd.forever, hog_snd.centre, hog_snd.own_pitch).?;
    var archive = try hudoptions.testing.fontArchive(gpa);
    defer archive.close(gpa);
    var app: App = .{};
    var clock: Clock = .{};
    var view: camera.Camera = .{};
    const setting: camera.CockpitSetting = .cockpit;
    const player: u16 = 0;
    var menu: hudoptions.PauseMenu = .{};
    defer menu.close();
    const pausing: main.Pausing = .{
        .gpa = gpa,
        .clock = &clock,
        .sound = &sound,
        .menu = &menu,
        .archive = archive.hog,
        .view_setting = &setting,
        .camera = &view,
        .player = &player,
    };

    // Active, nothing changes.
    try followActivation(&app, pausing);
    try std.testing.expectEqual(mss.Status.playing, driver.sampleStatus(sound.voices[v].sample));

    // Inactive, the sound and the clock stop, once, and the menu opens.
    app.active = false;
    try followActivation(&app, pausing);
    try followActivation(&app, pausing);
    try std.testing.expect(clock.paused and app.paused and menu.isOpen());
    try std.testing.expectEqual(mss.Status.stopped, driver.sampleStatus(sound.voices[v].sample));

    // Active again, the mission waits in the menu; continuing, the voices go on.
    app.active = true;
    try followActivation(&app, pausing);
    try std.testing.expect(clock.paused and !app.paused);
    try main.pause(pausing, false);
    try std.testing.expect(!clock.paused and !menu.isOpen());
    try std.testing.expectEqual(mss.Status.playing, driver.sampleStatus(sound.voices[v].sample));
}

/// What `WinMain` does before each single-player mission (`0x004A99CC`): puts back the pilot's
/// kills as the last mission the pilot came through kept them (`gameflow.endMission`). **Not
/// ported:** the rank, the medals and the other tallies it puts back with them, which no screen
/// of the port shows.
pub fn startMission(player: *input.Player) void {
    player.kills.count = player.kills.kept;
}

test startMission {
    var player: input.Player = .{ .kills = .{ .count = 9, .kept = 4 } };
    startMission(&player);
    try std.testing.expectEqual(4, player.kills.count);
}
