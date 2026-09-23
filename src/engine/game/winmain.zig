//! `C:\lancer\game\winmain.cpp`: the game's entry, `WinMain` (`0x004A8B10`), and its message pump.
//! **Unverified:** the pump (`0x004AAB20`) lies after the last of the file's code that its
//! assertions place; by what it does it is this file's.
//!
//! Ported so far: what the pump does as the game's window goes inactive and active again, as far
//! as the sound and the clock go. `openreliant`'s own frame loop stands in for the rest.

const std = @import("std");

const Clock = @import("main.zig").Clock;
const hog_snd = @import("hog_snd.zig");
const Sound = hog_snd.Sound;
const sound3d = @import("sound3d.zig");

/// The window's activation, as the pump follows it.
pub const App = struct {
    /// `app_active` (`0x005D6CAC`): whether the game's window is the active one, as
    /// `WM_ACTIVATEAPP` last said.
    active: bool = true,
    /// `app_inactive_paused` (`0x005D6CAD`): whether the pump has paused the game for the window
    /// going inactive.
    paused: bool = false,
};

/// `message_pump` (`0x004AAB20`), the part that follows the window's activation. Going inactive,
/// the music, the 3D voices and the voices pause, and so does the mission (`game_pause`), and the
/// pump waits on the window's messages until it is active again; then the sound goes on. The
/// textures, which DirectDraw loses with the window, need nothing in the port.
///
/// **Not ported:** the pause menu `game_pause` opens, which the original leaves the mission in once
/// the window is active again; the port lets the mission go on.
pub fn followActivation(app: *App, sound: *Sound, clock: *Clock) void {
    if (app.active and app.paused) {
        sound.pauseMusic(false);
        sound3d.pause(sound, false);
        sound.resumeAll();
        clock.paused = false;
        app.paused = false;
    } else if (!app.active and !app.paused) {
        sound.pauseMusic(true);
        sound3d.pause(sound, true);
        sound.pauseAll();
        clock.paused = true;
        app.paused = true;
    }
}

test followActivation {
    const mss = @import("../mss.zig");
    const fat = @import("../../formats/fat.zig");
    var mixer: mss.Mixer = .init(22050);
    const driver = mixer.driver();
    var sound: Sound = undefined;
    sound.init(driver, 2, null);
    const bytes = comptime hog_snd.testing.bank(2);
    const v = sound.play(try fat.Bank.parse(&bytes), 1, 127, 0, 64, 0).?;
    var app: App = .{};
    var clock: Clock = .{};

    // Active, nothing changes.
    followActivation(&app, &sound, &clock);
    try std.testing.expectEqual(mss.Status.playing, driver.sampleStatus(sound.voices[v].sample));

    // Inactive, the sound and the clock stop, once.
    app.active = false;
    followActivation(&app, &sound, &clock);
    followActivation(&app, &sound, &clock);
    try std.testing.expect(clock.paused and app.paused);
    try std.testing.expectEqual(mss.Status.stopped, driver.sampleStatus(sound.voices[v].sample));

    // Active again, they go on.
    app.active = true;
    followActivation(&app, &sound, &clock);
    try std.testing.expect(!clock.paused and !app.paused);
    try std.testing.expectEqual(mss.Status.playing, driver.sampleStatus(sound.voices[v].sample));
}
