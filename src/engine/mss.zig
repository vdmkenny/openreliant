//! The Miles Sound System (`MSS32.DLL`), as far as the game calls it: a digital driver that mixes
//! samples, 3D samples and streams of WAVE sounds. The port's own stand-in, in software: the
//! library is not the game's, and nothing of it is carried over but the calls' meanings. Each
//! function stands for the `AIL_` call it names; the game's code in
//! [`game/hog_snd.zig`](game/hog_snd.zig) makes them as it made Miles's.
//!
//! The platform plays what `Driver.mix` makes. It mixes on a thread of its own, so the driver holds
//! the platform's `Lock` through each call; `mix` expects its caller to hold it.
//!
//! Volumes and pans run from 0 to 127, a pan of 64 in the middle, as Miles's do. How Miles turned
//! them into gains is not known here: the port takes a volume's share of 127 as its gain, and a pan
//! as a balance that keeps the middle at full volume in both ears.

const std = @import("std");

pub const voice = @import("mss/voice.zig");
pub const positional = @import("mss/positional.zig");

pub const Status = voice.Status;
pub const Vector = positional.Vector;

/// A sample (`HSAMPLE`): a sound played as it is, with a volume and a pan.
pub const Sample = enum(u8) { _ };

/// A 3D sample (`H3DSAMPLE`): a sound placed around the listener.
pub const Sample3D = enum(u8) { _ };

/// A stream (`HSTREAM`): a long sound, such as a piece of music, that plays and loops as a sample
/// does, from a file of its own.
pub const Stream = enum(u8) { _ };

/// What keeps the platform's mixing thread out while the game changes the driver.
pub const Lock = struct {
    context: ?*anyopaque = null,
    acquire_fn: *const fn (?*anyopaque) void = noop,
    release_fn: *const fn (?*anyopaque) void = noop,

    /// For a driver nothing mixes from another thread, as in the tests.
    pub const none: Lock = .{};

    fn noop(_: ?*anyopaque) void {}

    pub fn acquire(lock: Lock) void {
        lock.acquire_fn(lock.context);
    }

    pub fn release(lock: Lock) void {
        lock.release_fn(lock.context);
    }
};

/// The one 3D provider the port offers.
pub const provider_name = "Miles Fast 2D Positional Audio";

/// `AIL_3D_provider_attribute`'s "Maximum supported samples" for it.
pub const max_3d_samples = 32;

pub const max_samples = 32;
pub const max_streams = 4;

/// The digital driver (`HDIGDRIVER`, `AIL_waveOutOpen`): the handles and their mix.
pub const Driver = struct {
    /// The output's frames a second.
    rate: u32,
    lock: Lock = .none,
    samples: [max_samples]Slot(SampleState) = @splat(.{}),
    samples_3d: [max_3d_samples]Slot(Sample3DState) = @splat(.{}),
    streams: [max_streams]Slot(StreamState) = @splat(.{}),

    fn Slot(comptime State: type) type {
        return struct {
            allocated: bool = false,
            state: State = .{},
        };
    }

    const SampleState = struct {
        playing: ?voice.Voice = null,
        volume: i32 = 127,
        pan: i32 = 64,
    };

    const Sample3DState = struct {
        playing: ?voice.Voice = null,
        volume: i32 = 127,
        placing: positional.Placing = .{},
    };

    const StreamState = struct {
        playing: ?voice.Voice = null,
        volume: i32 = 127,
        /// The frame it starts from.
        position: u32 = 0,
    };

    pub fn init(rate: u32) Driver {
        return .{ .rate = rate };
    }

    fn Handle(comptime State: type) type {
        return switch (State) {
            SampleState => Sample,
            Sample3DState => Sample3D,
            StreamState => Stream,
            else => unreachable,
        };
    }

    fn allocate(comptime State: type, slots: []Slot(State)) ?Handle(State) {
        for (slots, 0..) |*slot, index| {
            if (slot.allocated) continue;
            slot.* = .{ .allocated = true };
            return @enumFromInt(index);
        }
        return null;
    }

    fn statusOf(playing: ?voice.Voice) Status {
        return if (playing) |held| held.status else .done;
    }

    // --- Samples ---------------------------------------------------------------------------------

    /// `AIL_allocate_sample_handle`: a free sample, or null when all are taken.
    pub fn allocateSample(driver: *Driver) ?Sample {
        driver.lock.acquire();
        defer driver.lock.release();
        return allocate(SampleState, &driver.samples);
    }

    fn sample(driver: *Driver, handle: Sample) *SampleState {
        return &driver.samples[@intFromEnum(handle)].state;
    }

    /// `AIL_init_sample`: back to no sound, full volume and the middle.
    pub fn initSample(driver: *Driver, handle: Sample) void {
        driver.lock.acquire();
        defer driver.lock.release();
        driver.sample(handle).* = .{};
    }

    /// `AIL_set_sample_file`: the WAVE sound it is to play, which must outlive it. False for a
    /// file the driver cannot play, as Miles's null.
    pub fn setSampleFile(driver: *Driver, handle: Sample, file: []const u8) bool {
        driver.lock.acquire();
        defer driver.lock.release();
        driver.sample(handle).playing = voice.Voice.init(file) catch return false;
        return true;
    }

    pub fn setSampleVolume(driver: *Driver, handle: Sample, volume: i32) void {
        driver.lock.acquire();
        defer driver.lock.release();
        driver.sample(handle).volume = std.math.clamp(volume, 0, 127);
    }

    pub fn sampleVolume(driver: *Driver, handle: Sample) i32 {
        driver.lock.acquire();
        defer driver.lock.release();
        return driver.sample(handle).volume;
    }

    pub fn setSamplePan(driver: *Driver, handle: Sample, pan: i32) void {
        driver.lock.acquire();
        defer driver.lock.release();
        driver.sample(handle).pan = std.math.clamp(pan, 0, 127);
    }

    /// `AIL_set_sample_playback_rate`: frames a second.
    pub fn setSamplePlaybackRate(driver: *Driver, handle: Sample, rate: u32) void {
        driver.lock.acquire();
        defer driver.lock.release();
        if (driver.sample(handle).playing) |*held| held.rate = rate;
    }

    /// `AIL_set_sample_loop_count`: times to play it, 0 for ever.
    pub fn setSampleLoopCount(driver: *Driver, handle: Sample, count: u32) void {
        driver.lock.acquire();
        defer driver.lock.release();
        if (driver.sample(handle).playing) |*held| held.loop_count = count;
    }

    pub fn startSample(driver: *Driver, handle: Sample) void {
        driver.lock.acquire();
        defer driver.lock.release();
        if (driver.sample(handle).playing) |*held| held.start();
    }

    /// `AIL_stop_sample`: stops it where it is, to be resumed.
    pub fn stopSample(driver: *Driver, handle: Sample) void {
        driver.lock.acquire();
        defer driver.lock.release();
        if (driver.sample(handle).playing) |*held| if (held.status == .playing) {
            held.status = .stopped;
        };
    }

    pub fn resumeSample(driver: *Driver, handle: Sample) void {
        driver.lock.acquire();
        defer driver.lock.release();
        if (driver.sample(handle).playing) |*held| if (held.status == .stopped) {
            held.status = .playing;
        };
    }

    /// `AIL_end_sample`: stops it for good.
    pub fn endSample(driver: *Driver, handle: Sample) void {
        driver.lock.acquire();
        defer driver.lock.release();
        if (driver.sample(handle).playing) |*held| held.status = .done;
    }

    pub fn sampleStatus(driver: *Driver, handle: Sample) Status {
        driver.lock.acquire();
        defer driver.lock.release();
        return statusOf(driver.sample(handle).playing);
    }

    // --- 3D samples ------------------------------------------------------------------------------

    /// `AIL_allocate_3D_sample_handle`.
    pub fn allocate3DSample(driver: *Driver) ?Sample3D {
        driver.lock.acquire();
        defer driver.lock.release();
        return allocate(Sample3DState, &driver.samples_3d);
    }

    /// `AIL_release_3D_sample_handle`.
    pub fn release3DSample(driver: *Driver, handle: Sample3D) void {
        driver.lock.acquire();
        defer driver.lock.release();
        driver.samples_3d[@intFromEnum(handle)] = .{};
    }

    fn sample3D(driver: *Driver, handle: Sample3D) *Sample3DState {
        return &driver.samples_3d[@intFromEnum(handle)].state;
    }

    /// `AIL_set_3D_sample_file`: its sound, which must outlive it. Miles's 3D samples play PCM
    /// only, which is why the game decompresses its ADPCM first (`AIL_decompress_ADPCM`); the
    /// port's play either.
    pub fn set3DSampleFile(driver: *Driver, handle: Sample3D, file: []const u8) bool {
        driver.lock.acquire();
        defer driver.lock.release();
        const state = driver.sample3D(handle);
        state.playing = voice.Voice.init(file) catch return false;
        return true;
    }

    pub fn set3DSampleVolume(driver: *Driver, handle: Sample3D, volume: i32) void {
        driver.lock.acquire();
        defer driver.lock.release();
        driver.sample3D(handle).volume = std.math.clamp(volume, 0, 127);
    }

    pub fn set3DSamplePlaybackRate(driver: *Driver, handle: Sample3D, rate: u32) void {
        driver.lock.acquire();
        defer driver.lock.release();
        if (driver.sample3D(handle).playing) |*held| held.rate = rate;
    }

    pub fn set3DSampleLoopCount(driver: *Driver, handle: Sample3D, count: u32) void {
        driver.lock.acquire();
        defer driver.lock.release();
        if (driver.sample3D(handle).playing) |*held| held.loop_count = count;
    }

    /// `AIL_set_3D_position`, from the listener.
    pub fn set3DPosition(driver: *Driver, handle: Sample3D, position: Vector) void {
        driver.lock.acquire();
        defer driver.lock.release();
        driver.sample3D(handle).placing.position = position;
    }

    /// `AIL_set_3D_orientation`: which way it faces, and its up, which nothing here needs.
    pub fn set3DOrientation(driver: *Driver, handle: Sample3D, face: Vector, up: Vector) void {
        _ = up;
        driver.lock.acquire();
        defer driver.lock.release();
        driver.sample3D(handle).placing.face = face;
    }

    /// `AIL_set_3D_velocity_vector`: a millisecond's movement.
    pub fn set3DVelocity(driver: *Driver, handle: Sample3D, velocity: Vector) void {
        driver.lock.acquire();
        defer driver.lock.release();
        driver.sample3D(handle).placing.velocity = velocity;
    }

    /// `AIL_set_3D_sample_distances`: past `max` no quieter, within `min` no louder.
    pub fn set3DSampleDistances(driver: *Driver, handle: Sample3D, max: f32, min: f32) void {
        driver.lock.acquire();
        defer driver.lock.release();
        const placing = &driver.sample3D(handle).placing;
        placing.max_distance = max;
        placing.min_distance = min;
    }

    /// `AIL_set_3D_sample_cone`: the angles in degrees, and the volume outside the outer one.
    pub fn set3DSampleCone(driver: *Driver, handle: Sample3D, inner: f32, outer: f32, outer_volume: i32) void {
        driver.lock.acquire();
        defer driver.lock.release();
        const placing = &driver.sample3D(handle).placing;
        placing.inner_angle = inner;
        placing.outer_angle = outer;
        placing.outer_volume = @floatFromInt(std.math.clamp(outer_volume, 0, 127));
    }

    pub fn start3DSample(driver: *Driver, handle: Sample3D) void {
        driver.lock.acquire();
        defer driver.lock.release();
        if (driver.sample3D(handle).playing) |*held| held.start();
    }

    pub fn stop3DSample(driver: *Driver, handle: Sample3D) void {
        driver.lock.acquire();
        defer driver.lock.release();
        if (driver.sample3D(handle).playing) |*held| if (held.status == .playing) {
            held.status = .stopped;
        };
    }

    pub fn resume3DSample(driver: *Driver, handle: Sample3D) void {
        driver.lock.acquire();
        defer driver.lock.release();
        if (driver.sample3D(handle).playing) |*held| if (held.status == .stopped) {
            held.status = .playing;
        };
    }

    pub fn end3DSample(driver: *Driver, handle: Sample3D) void {
        driver.lock.acquire();
        defer driver.lock.release();
        if (driver.sample3D(handle).playing) |*held| held.status = .done;
    }

    pub fn sample3DStatus(driver: *Driver, handle: Sample3D) Status {
        driver.lock.acquire();
        defer driver.lock.release();
        return statusOf(driver.sample3D(handle).playing);
    }

    /// `AIL_3D_sample_length`: the bytes its sound would take as 16-bit PCM, which is what Miles
    /// held once the game had decompressed it.
    pub fn sample3DLength(driver: *Driver, handle: Sample3D) u32 {
        driver.lock.acquire();
        defer driver.lock.release();
        const held = driver.sample3D(handle).playing orelse return 0;
        return held.decoder.frames * held.decoder.wave.channels * 2;
    }

    // --- Streams ---------------------------------------------------------------------------------

    /// `AIL_open_stream`: a stream of `file`, a WAVE sound that must outlive it, not yet playing;
    /// null for a file the driver cannot play, or when all streams are taken.
    pub fn openStream(driver: *Driver, file: []const u8) ?Stream {
        driver.lock.acquire();
        defer driver.lock.release();
        const opened = voice.Voice.init(file) catch return null;
        const handle = allocate(StreamState, &driver.streams) orelse return null;
        driver.stream(handle).playing = opened;
        return handle;
    }

    fn stream(driver: *Driver, handle: Stream) *StreamState {
        return &driver.streams[@intFromEnum(handle)].state;
    }

    pub fn closeStream(driver: *Driver, handle: Stream) void {
        driver.lock.acquire();
        defer driver.lock.release();
        driver.streams[@intFromEnum(handle)] = .{};
    }

    pub fn startStream(driver: *Driver, handle: Stream) void {
        driver.lock.acquire();
        defer driver.lock.release();
        const state = driver.stream(handle);
        // It starts from wherever its position was set.
        if (state.playing) |*held| held.startFrom(state.position);
    }

    /// `AIL_pause_stream`: pauses it, or with `paused` false carries on.
    pub fn pauseStream(driver: *Driver, handle: Stream, paused: bool) void {
        driver.lock.acquire();
        defer driver.lock.release();
        if (driver.stream(handle).playing) |*held| {
            if (paused and held.status == .playing) held.status = .stopped;
            if (!paused and held.status == .stopped) held.status = .playing;
        }
    }

    pub fn streamStatus(driver: *Driver, handle: Stream) Status {
        driver.lock.acquire();
        defer driver.lock.release();
        return statusOf(driver.stream(handle).playing);
    }

    pub fn setStreamVolume(driver: *Driver, handle: Stream, volume: i32) void {
        driver.lock.acquire();
        defer driver.lock.release();
        driver.stream(handle).volume = std.math.clamp(volume, 0, 127);
    }

    pub fn setStreamLoopCount(driver: *Driver, handle: Stream, count: u32) void {
        driver.lock.acquire();
        defer driver.lock.release();
        if (driver.stream(handle).playing) |*held| held.loop_count = count;
    }

    /// `AIL_set_stream_loop_block`: where in the data a loop starts again and ends, in bytes; an
    /// end of -1 for the end of the sound.
    pub fn setStreamLoopBlock(driver: *Driver, handle: Stream, start: i32, end: i32) void {
        driver.lock.acquire();
        defer driver.lock.release();
        const held = &(driver.stream(handle).playing orelse return);
        held.loop_start = held.frameAt(@intCast(@max(start, 0)));
        held.loop_end = if (end < 0) held.decoder.frames else held.frameAt(@intCast(end));
    }

    /// `AIL_set_stream_position`: where it plays from, in bytes into the data. A negative offset
    /// changes nothing.
    pub fn setStreamPosition(driver: *Driver, handle: Stream, offset: i32) void {
        driver.lock.acquire();
        defer driver.lock.release();
        if (offset < 0) return;
        const state = driver.stream(handle);
        const held = state.playing orelse return;
        state.position = held.frameAt(@intCast(offset));
    }

    // --- The mix ---------------------------------------------------------------------------------

    /// Mixes `out.len` frames of everything playing into `out`, left and right from -1 to 1. The
    /// caller holds the lock.
    pub fn mix(driver: *Driver, out: [][2]f32) void {
        @memset(out, .{ 0, 0 });
        for (&driver.samples) |*slot| {
            if (!slot.allocated) continue;
            const state = &slot.state;
            const held = &(state.playing orelse continue);
            const gain = @as(f32, @floatFromInt(state.volume)) / 127;
            const pan = @as(f32, @floatFromInt(state.pan));
            const gains: [2]f32 = .{ gain * @min(1, (127 - pan) / 63), gain * @min(1, pan / 64) };
            held.mix(out, driver.rate, gains, 1);
        }
        for (&driver.samples_3d) |*slot| {
            if (!slot.allocated) continue;
            const state = &slot.state;
            const held = &(state.playing orelse continue);
            const heard = positional.hear(state.placing, @floatFromInt(state.volume));
            held.mix(out, driver.rate, heard.gains, heard.pitch);
        }
        for (&driver.streams) |*slot| {
            if (!slot.allocated) continue;
            const state = &slot.state;
            const held = &(state.playing orelse continue);
            const gain = @as(f32, @floatFromInt(state.volume)) / 127;
            held.mix(out, driver.rate, .{ gain, gain }, 1);
        }
        for (out) |*frame| {
            for (frame) |*channel| channel.* = std.math.clamp(channel.*, -1, 1);
        }
    }
};

test {
    std.testing.refAllDecls(@This());
}

test Driver {
    const file = comptime @import("../formats/wave.zig").testing.pcm(&std.mem.toBytes([4]i16{ 16384, 16384, 16384, 16384 }));
    var driver: Driver = .init(22050);
    const handle = driver.allocateSample().?;
    try std.testing.expectEqual(Status.done, driver.sampleStatus(handle));
    try std.testing.expect(driver.setSampleFile(handle, file));
    try std.testing.expect(!driver.setSampleFile(handle, "not a wave"));
    try std.testing.expect(driver.setSampleFile(handle, file));

    // Full left: the left ear only, at the volume's share.
    driver.setSamplePan(handle, 0);
    driver.setSampleVolume(handle, 127);
    driver.startSample(handle);
    try std.testing.expectEqual(Status.playing, driver.sampleStatus(handle));
    var out: [2][2]f32 = undefined;
    driver.mix(&out);
    try std.testing.expectEqual([2]f32{ 0.5, 0 }, out[0]);

    // Stopped, it holds its place and adds nothing; resumed, it goes on to the end.
    driver.stopSample(handle);
    try std.testing.expectEqual(Status.stopped, driver.sampleStatus(handle));
    driver.mix(&out);
    try std.testing.expectEqual([2]f32{ 0, 0 }, out[0]);
    driver.resumeSample(handle);
    var rest: [4][2]f32 = undefined;
    driver.mix(&rest);
    try std.testing.expectEqual(Status.done, driver.sampleStatus(handle));

    // In the middle, both ears at full volume.
    driver.setSamplePan(handle, 64);
    driver.startSample(handle);
    driver.mix(&out);
    try std.testing.expectEqual([2]f32{ 0.5, 0.5 }, out[0]);
}

test "Driver places 3D samples and plays streams" {
    const file = comptime @import("../formats/wave.zig").testing.pcm(&std.mem.toBytes([4]i16{ 16384, 16384, 16384, 16384 }));
    var driver: Driver = .init(22050);
    const placed = driver.allocate3DSample().?;
    try std.testing.expect(driver.set3DSampleFile(placed, file));
    driver.set3DPosition(placed, .{ 1, 0, 0 });
    driver.start3DSample(placed);
    try std.testing.expectEqual(8, driver.sample3DLength(placed));
    var out: [1][2]f32 = undefined;
    driver.mix(&out);
    try std.testing.expectApproxEqAbs(@as(f32, 0), out[0][0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), out[0][1], 1e-6);
    driver.release3DSample(placed);

    // A stream loops its block for ever once told to.
    const music = driver.openStream(file).?;
    driver.setStreamLoopCount(music, 0);
    driver.setStreamLoopBlock(music, 4, -1);
    driver.setStreamVolume(music, 127);
    driver.startStream(music);
    var long: [32][2]f32 = undefined;
    driver.mix(&long);
    try std.testing.expectEqual(Status.playing, driver.streamStatus(music));
    driver.pauseStream(music, true);
    try std.testing.expectEqual(Status.stopped, driver.streamStatus(music));
    driver.closeStream(music);
    try std.testing.expect(driver.openStream("not a wave") == null);
}
