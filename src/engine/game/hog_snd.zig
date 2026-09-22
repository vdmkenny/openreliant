//! `C:\lancer\game\hog_SND.CPP`: sound playback. `sound_play` (`0x00481F80`) and `sound_start`
//! (`0x004826A0`) play the banks' sounds on the voices of `sound_voices`. **Unverified:** both lie
//! outside this file's known code, on either side of it.

const std = @import("std");
const assert = std.debug.assert;

const Clock = @import("main.zig").Clock;

/// One voice of `sound_voices`: a Miles sample and what is playing on it.
pub const Voice = extern struct {
    /// The Miles `HSAMPLE`.
    sample: u32,
    /// **Unknown.** `sound_play` takes a voice over only while this is zero.
    _unknown_04: u32,
    /// The playing sound's priority, from its bank entry. A new sound takes over the voice with
    /// the lowest one, if that is below its own.
    priority: i32,
    _unknown_0c: [5]u32,

    comptime {
        assert(@offsetOf(Voice, "priority") == 0x08);
        assert(@sizeOf(Voice) == 0x20);
    }
};

test {
    std.testing.refAllDecls(@This());
}

/// What `tick_timer` (`0x004827C0`) does to the mission's clocks, 100 times a second. Its other
/// half, which keeps the Miles streams and the sound voices going, isn't ported yet (#49).
/// **Unverified:** it lies after this file's known code, before `hud.cpp`'s.
pub fn tickTimer(clock: *Clock) void {
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
