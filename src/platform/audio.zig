//! The game's sound output, with SDL3: in place of the wave-out device Miles opened
//! (`AIL_waveOutOpen`). A stream on the default playback device pulls what the port's Miles
//! (`engine.mss.Driver`) mixes, on SDL's audio thread, at the device's own rate.

const std = @import("std");
const c = @import("sdl");
const mss = @import("openreliant").engine.mss;

pub const Error = error{Sdl};

fn fail(what: []const u8) Error {
    std.log.scoped(.sdl).err("{s}: {s}", .{ what, c.SDL_GetError() });
    return error.Sdl;
}

/// The frames the callback mixes at a time.
const chunk = 512;

pub const Output = struct {
    stream: *c.SDL_AudioStream,
    driver: *mss.Driver,

    /// Opens the default playback device and has it play what `driver` mixes, setting the
    /// driver's rate to the device's and its lock to the stream's. `driver` must stay where it is
    /// until the output is closed.
    pub fn open(driver: *mss.Driver) Error!Output {
        if (!c.SDL_InitSubSystem(c.SDL_INIT_AUDIO)) return fail("SDL_InitSubSystem");
        errdefer c.SDL_QuitSubSystem(c.SDL_INIT_AUDIO);
        var device: c.SDL_AudioSpec = undefined;
        var device_frames: c_int = 0;
        const rate: c_int = if (c.SDL_GetAudioDeviceFormat(c.SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, &device, &device_frames)) device.freq else 44100;
        const spec: c.SDL_AudioSpec = .{ .format = c.SDL_AUDIO_F32, .channels = 2, .freq = rate };
        const stream = c.SDL_OpenAudioDeviceStream(c.SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec, feed, driver) orelse return fail("SDL_OpenAudioDeviceStream");
        // The device starts paused, so nothing mixes before the driver is ready.
        driver.rate = @intCast(rate);
        driver.lock = lockOf(stream);
        if (!c.SDL_ResumeAudioStreamDevice(stream)) {
            driver.lock = .none;
            c.SDL_DestroyAudioStream(stream);
            return fail("SDL_ResumeAudioStreamDevice");
        }
        return .{ .stream = stream, .driver = driver };
    }

    pub fn close(output: *Output) void {
        c.SDL_DestroyAudioStream(output.stream);
        output.driver.lock = .none;
        c.SDL_QuitSubSystem(c.SDL_INIT_AUDIO);
    }
};

/// The stream's own lock, which SDL holds while it asks for more.
fn lockOf(stream: *c.SDL_AudioStream) mss.Lock {
    return .{ .context = stream, .acquire_fn = acquire, .release_fn = release };
}

fn acquire(context: ?*anyopaque) void {
    _ = c.SDL_LockAudioStream(@ptrCast(context));
}

fn release(context: ?*anyopaque) void {
    _ = c.SDL_UnlockAudioStream(@ptrCast(context));
}

/// SDL's call for `additional` more bytes: the driver's mix, a chunk at a time, up to a second's.
fn feed(userdata: ?*anyopaque, stream: ?*c.SDL_AudioStream, additional: c_int, total: c_int) callconv(.c) void {
    _ = total;
    const driver: *mss.Driver = @ptrCast(@alignCast(userdata));
    const bytes: usize = @intCast(@max(additional, 0));
    var frames: usize = @min(std.math.divCeil(usize, bytes, @sizeOf([2]f32)) catch 0, driver.rate);
    var buffer: [chunk][2]f32 = undefined;
    while (frames > 0) {
        const count: usize = @min(frames, chunk);
        driver.mix(buffer[0..count]);
        const size: c_int = @intCast(count * @sizeOf([2]f32));
        if (!c.SDL_PutAudioStreamData(stream, &buffer, size)) return;
        frames -= count;
    }
}

test feed {
    // A stream with no device behind it takes what the callback puts, as the device's would.
    const spec: c.SDL_AudioSpec = .{ .format = c.SDL_AUDIO_F32, .channels = 2, .freq = 22050 };
    const stream = c.SDL_CreateAudioStream(&spec, &spec) orelse return error.SkipZigTest;
    defer c.SDL_DestroyAudioStream(stream);

    const file = comptime @import("openreliant").wave.testing.pcm(&std.mem.toBytes([4]i16{ 16384, 16384, 16384, 16384 }));
    var driver: mss.Driver = .init(22050);
    driver.lock = lockOf(stream);
    const sample = driver.allocateSample().?;
    try std.testing.expect(driver.setSampleFile(sample, file));
    driver.startSample(sample);

    feed(&driver, stream, 3 * @sizeOf([2]f32), 0);
    try std.testing.expectEqual(3 * @sizeOf([2]f32), c.SDL_GetAudioStreamAvailable(stream));
    var got: [3][2]f32 = undefined;
    try std.testing.expectEqual(@sizeOf(@TypeOf(got)), c.SDL_GetAudioStreamData(stream, &got, @sizeOf(@TypeOf(got))));
    try std.testing.expectEqual([2]f32{ 0.5, 0.5 }, got[0]);
}
