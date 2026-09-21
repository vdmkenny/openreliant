//! Sound playback state.

const std = @import("std");
const assert = std.debug.assert;

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
