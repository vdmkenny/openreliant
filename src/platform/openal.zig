//! The Miles Sound System's calls ([`engine/mss.zig`](../engine/mss.zig)'s `Driver`), played by
//! OpenAL Soft in place of the 3D providers the game chose between: Miles's own, DirectSound3D, EAX,
//! A3D. OpenAL renders into memory through its loopback device, which the platform's audio stream
//! pulls from, so none of its own device backends are used.
//!
//! What the game asked of its provider maps across as it is: each 3D sample's distances, as the
//! inverse distance clamped model DirectSound3D had; its cone; its velocity's Doppler shift; its
//! pitch and volume. Samples play by their pan from ahead, streams stereo straight to the
//! speakers. **Improvements:** OpenAL's band-limited sinc resampler and its smoothing of every
//! change; UHJ stereo, or HRTF for headphones, where Miles panned left and right; as many speakers as
//! the device has; high frequencies fading with distance; and a reverb on the 3D sounds, of the
//! generic room the game asks EAX for with its effect volume at nothing.

const std = @import("std");
const Allocator = std.mem.Allocator;

const c = @import("al");
const openreliant = @import("openreliant");
const mss = openreliant.engine.mss;
const wave = openreliant.wave;

const log = std.log.scoped(.openal);

pub const Settings = struct {
    /// Head-related transfer functions, for headphones, on a stereo device; UHJ otherwise.
    hrtf: bool = false,
    /// The reverb on the 3D sounds, and how much of it is heard.
    reverb: bool = true,
    reverb_level: f32 = 0.35,
    /// High frequencies fading with distance.
    air_absorption: bool = true,
};

pub const Error = error{OpenAl} || Allocator.Error;

/// 3D samples: as many as the game takes of a provider, twice the software mixer's. The game picks
/// the same row of voice classes for either and leaves the rest to any sound.
pub const max_3d_samples = 64;

/// The resampler it asks for by name, the best OpenAL Soft has.
const resampler_name = "23rd order Sinc";

/// Miles's units are metres; its velocities are a millisecond's, OpenAL's a second's.
const velocity_scale: f32 = 1000;
const speed_of_sound: f32 = 343.3;

/// A sound decoded into an OpenAL buffer.
const Buffer = struct {
    name: c.ALuint,
    rate: u32,
    frames: u32,
    channels: u16,
};

/// A sample or 3D sample: an OpenAL source and what the game asked of it.
const Voice = struct {
    allocated: bool = false,
    source: c.ALuint = 0,
    buffer: ?Buffer = null,
    volume: i32 = 127,
    pan: i32 = 64,
    loops: u32 = 1,
    rate: u32 = 0,
    /// A 3D sample's position and velocity, in Miles's frame.
    position: mss.Vector = @splat(0),
    velocity: mss.Vector = @splat(0),
};

/// A stream: its source, and its sound, whole in a buffer of its own.
const Stream = struct {
    source: c.ALuint = 0,
    open: ?struct {
        buffer: Buffer,
        wave: wave.Wave,
        loops: u32 = 1,
        loop_start: u32 = 0,
        loop_end: ?u32 = null,
        position: u32 = 0,
    } = null,
};

pub const Renderer = struct {
    gpa: Allocator,
    device: *c.ALCdevice,
    context: *c.ALCcontext,
    rate: u32,
    channels: u8,
    settings: Settings,
    resampler: ?c.ALint = null,
    effect: c.ALuint = 0,
    slot: c.ALuint = 0,
    samples: [mss.max_samples]Voice = @splat(.{}),
    samples_3d: [max_3d_samples]Voice = @splat(.{}),
    streams: [mss.max_streams]Stream = @splat(.{}),
    /// The banks' sounds, decoded once each, by a hash of their files.
    buffers: std.AutoHashMapUnmanaged(u64, Buffer) = .empty,

    /// A renderer at `rate`, into `channels` interleaved float channels: 2, 4, 6 for 5.1 or 8 for
    /// 7.1; any other count renders stereo.
    pub fn create(gpa: Allocator, rate: u32, channels: u8, settings: Settings) Error!*Renderer {
        const layout: struct { c.ALCint, u8 } = switch (channels) {
            4 => .{ c.ALC_QUAD_SOFT, 4 },
            6 => .{ c.ALC_5POINT1_SOFT, 6 },
            8 => .{ c.ALC_7POINT1_SOFT, 8 },
            else => .{ c.ALC_STEREO_SOFT, 2 },
        };
        const device = c.alcLoopbackOpenDeviceSOFT(null) orelse return fail("alcLoopbackOpenDeviceSOFT");
        errdefer _ = c.alcCloseDevice(device);
        const stereo_mode: c.ALCint = if (settings.hrtf) c.ALC_STEREO_HRTF_SOFT else c.ALC_STEREO_UHJ_SOFT;
        const attributes = [_]c.ALCint{
            c.ALC_FORMAT_CHANNELS_SOFT, layout[0],
            c.ALC_FORMAT_TYPE_SOFT,     c.ALC_FLOAT_SOFT,
            c.ALC_FREQUENCY,            @intCast(rate),
            // The platform's master bus limits the mix; OpenAL's own limiter would come first.
            c.ALC_OUTPUT_LIMITER_SOFT,  c.ALC_FALSE,
            c.ALC_HRTF_SOFT,            if (settings.hrtf) c.ALC_TRUE else c.ALC_FALSE,
            c.ALC_OUTPUT_MODE_SOFT,     if (layout[1] == 2) stereo_mode else c.ALC_ANY_SOFT,
            c.ALC_MONO_SOURCES,         128,
            c.ALC_STEREO_SOURCES,       16,
            c.ALC_MAX_AUXILIARY_SENDS,  1,
            0,
        };
        const context = c.alcCreateContext(device, &attributes) orelse return fail("alcCreateContext");
        errdefer c.alcDestroyContext(context);
        if (c.alcMakeContextCurrent(context) == c.ALC_FALSE) return fail("alcMakeContextCurrent");

        const renderer = try gpa.create(Renderer);
        errdefer gpa.destroy(renderer);
        renderer.* = .{ .gpa = gpa, .device = device, .context = context, .rate = rate, .channels = layout[1], .settings = settings };

        // The listener stands still at the origin, looking ahead: the game places every sound
        // from the camera.
        c.alDistanceModel(c.AL_INVERSE_DISTANCE_CLAMPED);
        c.alDopplerFactor(1);
        c.alSpeedOfSound(speed_of_sound);
        c.alListener3f(c.AL_POSITION, 0, 0, 0);
        c.alListener3f(c.AL_VELOCITY, 0, 0, 0);
        const orientation = [6]c.ALfloat{ 0, 0, -1, 0, 1, 0 };
        c.alListenerfv(c.AL_ORIENTATION, &orientation);
        c.alListenerf(c.AL_METERS_PER_UNIT, 1);
        renderer.resampler = findResampler();
        if (settings.reverb) renderer.createReverb();

        for (&renderer.samples) |*voice| c.alGenSources(1, &voice.source);
        for (&renderer.samples_3d) |*voice| c.alGenSources(1, &voice.source);
        for (&renderer.streams) |*slot| c.alGenSources(1, &slot.source);
        // The context takes its sources with it.
        if (c.alGetError() != c.AL_NO_ERROR) return fail("alGenSources");
        return renderer;
    }

    pub fn destroy(renderer: *Renderer) void {
        for (&renderer.samples) |*voice| deleteSource(voice.source);
        for (&renderer.samples_3d) |*voice| deleteSource(voice.source);
        for (&renderer.streams) |*slot| {
            releaseStream(slot);
            deleteSource(slot.source);
        }
        var buffers = renderer.buffers.valueIterator();
        while (buffers.next()) |buffer| c.alDeleteBuffers(1, &buffer.name);
        renderer.buffers.deinit(renderer.gpa);
        if (renderer.slot != 0) c.alDeleteAuxiliaryEffectSlots(1, &renderer.slot);
        if (renderer.effect != 0) c.alDeleteEffects(1, &renderer.effect);
        _ = c.alcMakeContextCurrent(null);
        c.alcDestroyContext(renderer.context);
        _ = c.alcCloseDevice(renderer.device);
        renderer.gpa.destroy(renderer);
    }

    /// How it renders to stereo: UHJ, HRTF or plain panning.
    pub fn outputMode(renderer: *const Renderer) c.ALCint {
        var mode: c.ALCint = 0;
        c.alcGetIntegerv(renderer.device, c.ALC_OUTPUT_MODE_SOFT, 1, &mode);
        return mode;
    }

    pub fn driver(renderer: *Renderer) mss.Driver {
        return .of(Renderer, renderer);
    }

    /// Renders `samples.len / channels` frames, interleaved.
    pub fn render(renderer: *Renderer, samples: []f32) void {
        const frames = samples.len / renderer.channels;
        if (frames > 0) c.alcRenderSamplesSOFT(renderer.device, samples.ptr, @intCast(frames));
    }

    /// The reverb the game's EAX provider was asked for: the generic room (`EAX_ENVIRONMENT_GENERIC`,
    /// room type 0), as EFX's preset has it.
    fn createReverb(renderer: *Renderer) void {
        c.alGenEffects(1, &renderer.effect);
        c.alEffecti(renderer.effect, c.AL_EFFECT_TYPE, c.AL_EFFECT_EAXREVERB);
        const generic = [_]struct { c.ALenum, f32 }{
            .{ c.AL_EAXREVERB_DENSITY, 1 },
            .{ c.AL_EAXREVERB_DIFFUSION, 1 },
            .{ c.AL_EAXREVERB_GAIN, 0.3162 },
            .{ c.AL_EAXREVERB_GAINHF, 0.8913 },
            .{ c.AL_EAXREVERB_GAINLF, 1 },
            .{ c.AL_EAXREVERB_DECAY_TIME, 1.49 },
            .{ c.AL_EAXREVERB_DECAY_HFRATIO, 0.83 },
            .{ c.AL_EAXREVERB_DECAY_LFRATIO, 1 },
            .{ c.AL_EAXREVERB_REFLECTIONS_GAIN, 0.05 },
            .{ c.AL_EAXREVERB_REFLECTIONS_DELAY, 0.007 },
            .{ c.AL_EAXREVERB_LATE_REVERB_GAIN, 1.2589 },
            .{ c.AL_EAXREVERB_LATE_REVERB_DELAY, 0.011 },
            .{ c.AL_EAXREVERB_ECHO_TIME, 0.25 },
            .{ c.AL_EAXREVERB_ECHO_DEPTH, 0 },
            .{ c.AL_EAXREVERB_MODULATION_TIME, 0.25 },
            .{ c.AL_EAXREVERB_MODULATION_DEPTH, 0 },
            .{ c.AL_EAXREVERB_AIR_ABSORPTION_GAINHF, 0.9943 },
            .{ c.AL_EAXREVERB_HFREFERENCE, 5000 },
            .{ c.AL_EAXREVERB_LFREFERENCE, 250 },
            .{ c.AL_EAXREVERB_ROOM_ROLLOFF_FACTOR, 0 },
        };
        for (generic) |parameter| c.alEffectf(renderer.effect, parameter[0], parameter[1]);
        c.alGenAuxiliaryEffectSlots(1, &renderer.slot);
        c.alAuxiliaryEffectSloti(renderer.slot, c.AL_EFFECTSLOT_EFFECT, @intCast(renderer.effect));
        c.alAuxiliaryEffectSlotf(renderer.slot, c.AL_EFFECTSLOT_GAIN, renderer.settings.reverb_level);
        if (c.alGetError() != c.AL_NO_ERROR) {
            log.warn("no reverb: EFX refused it", .{});
            if (renderer.slot != 0) c.alDeleteAuxiliaryEffectSlots(1, &renderer.slot);
            if (renderer.effect != 0) c.alDeleteEffects(1, &renderer.effect);
            renderer.slot = 0;
            renderer.effect = 0;
        }
    }

    // --- Buffers ---------------------------------------------------------------------------------

    /// A bank's sound as a buffer, decoded the first time it is asked for.
    fn bufferOf(renderer: *Renderer, file: []const u8) ?Buffer {
        const key = std.hash.Wyhash.hash(0, file);
        if (renderer.buffers.get(key)) |buffer| return buffer;
        const buffer = decode(renderer.gpa, file) orelse return null;
        renderer.buffers.put(renderer.gpa, key, buffer) catch {
            c.alDeleteBuffers(1, &buffer.name);
            return null;
        };
        return buffer;
    }

    // --- Samples ---------------------------------------------------------------------------------

    fn sample(renderer: *Renderer, handle: mss.Sample) *Voice {
        return &renderer.samples[@intFromEnum(handle)];
    }

    pub fn allocateSample(renderer: *Renderer) ?mss.Sample {
        for (&renderer.samples, 0..) |*voice, index| {
            if (voice.allocated) continue;
            voice.* = .{ .allocated = true, .source = voice.source };
            renderer.setUpFlat(voice);
            return @enumFromInt(index);
        }
        return null;
    }

    pub fn initSample(renderer: *Renderer, handle: mss.Sample) void {
        const voice = renderer.sample(handle);
        stopVoice(voice);
        voice.* = .{ .allocated = true, .source = voice.source };
        renderer.setUpFlat(voice);
    }

    pub fn setSampleFile(renderer: *Renderer, handle: mss.Sample, file: []const u8) bool {
        const voice = renderer.sample(handle);
        stopVoice(voice);
        voice.buffer = renderer.bufferOf(file) orelse return false;
        voice.rate = voice.buffer.?.rate;
        renderer.setUpFlat(voice);
        return true;
    }

    pub fn setSampleVolume(renderer: *Renderer, handle: mss.Sample, volume: i32) void {
        const voice = renderer.sample(handle);
        voice.volume = std.math.clamp(volume, 0, 127);
        c.alSourcef(voice.source, c.AL_GAIN, gain(voice.volume));
    }

    pub fn sampleVolume(renderer: *Renderer, handle: mss.Sample) i32 {
        return renderer.sample(handle).volume;
    }

    pub fn setSamplePan(renderer: *Renderer, handle: mss.Sample, pan: i32) void {
        const voice = renderer.sample(handle);
        voice.pan = std.math.clamp(pan, 0, 127);
        renderer.placeFlat(voice);
    }

    pub fn setSamplePlaybackRate(renderer: *Renderer, handle: mss.Sample, rate: u32) void {
        const voice = renderer.sample(handle);
        voice.rate = rate;
        setPitch(voice);
    }

    pub fn setSampleLoopCount(renderer: *Renderer, handle: mss.Sample, count: u32) void {
        renderer.sample(handle).loops = count;
    }

    pub fn startSample(renderer: *Renderer, handle: mss.Sample) void {
        startVoice(renderer.sample(handle));
    }

    pub fn stopSample(renderer: *Renderer, handle: mss.Sample) void {
        pauseSource(renderer.sample(handle).source);
    }

    pub fn resumeSample(renderer: *Renderer, handle: mss.Sample) void {
        resumeSource(renderer.sample(handle).source);
    }

    pub fn endSample(renderer: *Renderer, handle: mss.Sample) void {
        c.alSourceStop(renderer.sample(handle).source);
    }

    pub fn sampleStatus(renderer: *Renderer, handle: mss.Sample) mss.Status {
        return statusOf(renderer.sample(handle).source);
    }

    /// A sample plays from ahead, turned by its pan, with no distance; a stereo one straight to the
    /// speakers.
    fn setUpFlat(renderer: *Renderer, voice: *Voice) void {
        const source = voice.source;
        c.alSourcei(source, c.AL_SOURCE_RELATIVE, c.AL_TRUE);
        c.alSourcef(source, c.AL_ROLLOFF_FACTOR, 0);
        c.alSource3i(source, c.AL_AUXILIARY_SEND_FILTER, c.AL_EFFECTSLOT_NULL, 0, c.AL_FILTER_NULL);
        const stereo = if (voice.buffer) |buffer| buffer.channels == 2 else false;
        c.alSourcei(source, c.AL_DIRECT_CHANNELS_SOFT, if (stereo) c.AL_REMIX_UNMATCHED_SOFT else c.AL_FALSE);
        renderer.useResampler(source);
        c.alSourcef(source, c.AL_GAIN, gain(voice.volume));
        setPitch(voice);
        renderer.placeFlat(voice);
    }

    fn placeFlat(renderer: *Renderer, voice: *Voice) void {
        _ = renderer;
        const side = std.math.clamp(@as(f32, @floatFromInt(voice.pan - 64)) / 64, -1, 1);
        const angle = side * std.math.pi / 2;
        c.alSource3f(voice.source, c.AL_POSITION, @sin(angle), 0, -@cos(angle));
    }

    // --- 3D samples ------------------------------------------------------------------------------

    fn sample3D(renderer: *Renderer, handle: mss.Sample3D) *Voice {
        return &renderer.samples_3d[@intFromEnum(handle)];
    }

    pub fn allocate3DSample(renderer: *Renderer) ?mss.Sample3D {
        for (&renderer.samples_3d, 0..) |*voice, index| {
            if (voice.allocated) continue;
            voice.* = .{ .allocated = true, .source = voice.source };
            renderer.setUp3D(voice);
            return @enumFromInt(index);
        }
        return null;
    }

    pub fn release3DSample(renderer: *Renderer, handle: mss.Sample3D) void {
        const voice = renderer.sample3D(handle);
        stopVoice(voice);
        voice.* = .{ .source = voice.source };
    }

    pub fn set3DSampleFile(renderer: *Renderer, handle: mss.Sample3D, file: []const u8) bool {
        const voice = renderer.sample3D(handle);
        stopVoice(voice);
        voice.buffer = renderer.bufferOf(file) orelse return false;
        voice.rate = voice.buffer.?.rate;
        setPitch(voice);
        return true;
    }

    pub fn set3DSampleVolume(renderer: *Renderer, handle: mss.Sample3D, volume: i32) void {
        const voice = renderer.sample3D(handle);
        voice.volume = std.math.clamp(volume, 0, 127);
        c.alSourcef(voice.source, c.AL_GAIN, gain(voice.volume));
    }

    pub fn set3DSamplePlaybackRate(renderer: *Renderer, handle: mss.Sample3D, rate: u32) void {
        const voice = renderer.sample3D(handle);
        voice.rate = rate;
        setPitch(voice);
    }

    pub fn set3DSampleLoopCount(renderer: *Renderer, handle: mss.Sample3D, count: u32) void {
        renderer.sample3D(handle).loops = count;
    }

    pub fn set3DPosition(renderer: *Renderer, handle: mss.Sample3D, position: mss.Vector) void {
        const voice = renderer.sample3D(handle);
        voice.position = position;
        const at = openAl(position);
        c.alSource3f(voice.source, c.AL_POSITION, at[0], at[1], at[2]);
        setVelocity(voice);
    }

    pub fn set3DOrientation(renderer: *Renderer, handle: mss.Sample3D, face: mss.Vector, up: mss.Vector) void {
        _ = up;
        const toward = openAl(face);
        c.alSource3f(renderer.sample3D(handle).source, c.AL_DIRECTION, toward[0], toward[1], toward[2]);
    }

    pub fn set3DVelocity(renderer: *Renderer, handle: mss.Sample3D, velocity: mss.Vector) void {
        const voice = renderer.sample3D(handle);
        voice.velocity = velocity;
        setVelocity(voice);
    }

    pub fn set3DSampleDistances(renderer: *Renderer, handle: mss.Sample3D, max: f32, min: f32) void {
        const source = renderer.sample3D(handle).source;
        c.alSourcef(source, c.AL_REFERENCE_DISTANCE, @max(min, 0.001));
        c.alSourcef(source, c.AL_MAX_DISTANCE, @max(max, min));
    }

    pub fn set3DSampleCone(renderer: *Renderer, handle: mss.Sample3D, inner: f32, outer: f32, outer_volume: i32) void {
        const source = renderer.sample3D(handle).source;
        c.alSourcef(source, c.AL_CONE_INNER_ANGLE, inner);
        c.alSourcef(source, c.AL_CONE_OUTER_ANGLE, outer);
        c.alSourcef(source, c.AL_CONE_OUTER_GAIN, gain(std.math.clamp(outer_volume, 0, 127)));
    }

    pub fn start3DSample(renderer: *Renderer, handle: mss.Sample3D) void {
        startVoice(renderer.sample3D(handle));
    }

    pub fn stop3DSample(renderer: *Renderer, handle: mss.Sample3D) void {
        pauseSource(renderer.sample3D(handle).source);
    }

    pub fn resume3DSample(renderer: *Renderer, handle: mss.Sample3D) void {
        resumeSource(renderer.sample3D(handle).source);
    }

    pub fn end3DSample(renderer: *Renderer, handle: mss.Sample3D) void {
        c.alSourceStop(renderer.sample3D(handle).source);
    }

    pub fn sample3DStatus(renderer: *Renderer, handle: mss.Sample3D) mss.Status {
        return statusOf(renderer.sample3D(handle).source);
    }

    pub fn sample3DLength(renderer: *Renderer, handle: mss.Sample3D) u32 {
        const buffer = renderer.sample3D(handle).buffer orelse return 0;
        return buffer.frames * buffer.channels * 2;
    }

    /// A 3D sample is placed from the listener, falls off with distance, and sends to the
    /// reverb, which falls off as it does; a stereo one is spatialized all the same.
    fn setUp3D(renderer: *Renderer, voice: *Voice) void {
        const source = voice.source;
        c.alSourcei(source, c.AL_SOURCE_RELATIVE, c.AL_TRUE);
        c.alSourcef(source, c.AL_ROLLOFF_FACTOR, 1);
        c.alSourcef(source, c.AL_ROOM_ROLLOFF_FACTOR, 1);
        c.alSourcef(source, c.AL_CONE_INNER_ANGLE, 360);
        c.alSourcef(source, c.AL_CONE_OUTER_ANGLE, 360);
        c.alSourcei(source, c.AL_SOURCE_SPATIALIZE_SOFT, c.AL_TRUE);
        c.alSourcef(source, c.AL_AIR_ABSORPTION_FACTOR, if (renderer.settings.air_absorption) 1 else 0);
        c.alSource3i(source, c.AL_AUXILIARY_SEND_FILTER, if (renderer.slot != 0) @intCast(renderer.slot) else c.AL_EFFECTSLOT_NULL, 0, c.AL_FILTER_NULL);
        renderer.useResampler(source);
        c.alSourcef(source, c.AL_GAIN, gain(voice.volume));
    }

    // --- Streams ---------------------------------------------------------------------------------

    fn stream(renderer: *Renderer, handle: mss.Stream) *Stream {
        return &renderer.streams[@intFromEnum(handle)];
    }

    pub fn openStream(renderer: *Renderer, file: []const u8) ?mss.Stream {
        for (&renderer.streams, 0..) |*slot, index| {
            if (slot.open != null) continue;
            const sound = wave.Wave.parse(file) catch return null;
            const buffer = decode(renderer.gpa, file) orelse return null;
            slot.open = .{ .buffer = buffer, .wave = sound };
            const source = slot.source;
            c.alSourcei(source, c.AL_SOURCE_RELATIVE, c.AL_TRUE);
            c.alSourcef(source, c.AL_ROLLOFF_FACTOR, 0);
            c.alSource3f(source, c.AL_POSITION, 0, 0, 0);
            c.alSourcei(source, c.AL_DIRECT_CHANNELS_SOFT, c.AL_REMIX_UNMATCHED_SOFT);
            c.alSource3i(source, c.AL_AUXILIARY_SEND_FILTER, c.AL_EFFECTSLOT_NULL, 0, c.AL_FILTER_NULL);
            renderer.useResampler(source);
            c.alSourcef(source, c.AL_GAIN, 1);
            return @enumFromInt(index);
        }
        return null;
    }

    pub fn closeStream(renderer: *Renderer, handle: mss.Stream) void {
        releaseStream(renderer.stream(handle));
    }

    /// Plays it from its position. Its loop block is the buffer's loop points
    /// (`AL_SOFT_loop_points`), and a loop count other than once loops it for ever.
    pub fn startStream(renderer: *Renderer, handle: mss.Stream) void {
        const slot = renderer.stream(handle);
        const held = &(slot.open orelse return);
        const frames = held.buffer.frames;
        c.alSourceStop(slot.source);
        c.alSourcei(slot.source, c.AL_BUFFER, 0);
        const end = held.loop_end orelse frames;
        const points = [2]c.ALint{ @intCast(@min(held.loop_start, end -| 1)), @intCast(end) };
        c.alBufferiv(held.buffer.name, c.AL_LOOP_POINTS_SOFT, &points);
        c.alSourcei(slot.source, c.AL_BUFFER, @intCast(held.buffer.name));
        c.alSourcei(slot.source, c.AL_LOOPING, if (held.loops == 1) c.AL_FALSE else c.AL_TRUE);
        c.alSourcei(slot.source, c.AL_SAMPLE_OFFSET, @intCast(@min(held.position, frames)));
        c.alSourcePlay(slot.source);
    }

    pub fn pauseStream(renderer: *Renderer, handle: mss.Stream, paused: bool) void {
        const source = renderer.stream(handle).source;
        if (paused) pauseSource(source) else resumeSource(source);
    }

    pub fn streamStatus(renderer: *Renderer, handle: mss.Stream) mss.Status {
        return statusOf(renderer.stream(handle).source);
    }

    pub fn setStreamVolume(renderer: *Renderer, handle: mss.Stream, volume: i32) void {
        c.alSourcef(renderer.stream(handle).source, c.AL_GAIN, gain(std.math.clamp(volume, 0, 127)));
    }

    pub fn setStreamLoopCount(renderer: *Renderer, handle: mss.Stream, count: u32) void {
        const held = &(renderer.stream(handle).open orelse return);
        held.loops = count;
    }

    pub fn setStreamLoopBlock(renderer: *Renderer, handle: mss.Stream, start: i32, end: i32) void {
        const held = &(renderer.stream(handle).open orelse return);
        held.loop_start = held.wave.frameAt(@intCast(@max(start, 0)));
        held.loop_end = if (end < 0) null else held.wave.frameAt(@intCast(end));
    }

    pub fn setStreamPosition(renderer: *Renderer, handle: mss.Stream, offset: i32) void {
        if (offset < 0) return;
        const held = &(renderer.stream(handle).open orelse return);
        held.position = held.wave.frameAt(@intCast(offset));
    }

    fn useResampler(renderer: *Renderer, source: c.ALuint) void {
        if (renderer.resampler) |index| c.alSourcei(source, c.AL_SOURCE_RESAMPLER_SOFT, index);
    }
};

fn fail(what: []const u8) Error {
    log.err("{s} failed", .{what});
    return error.OpenAl;
}

/// The resampler of `resampler_name`, if OpenAL Soft has it.
fn findResampler() ?c.ALint {
    const count = c.alGetInteger(c.AL_NUM_RESAMPLERS_SOFT);
    var index: c.ALint = 0;
    while (index < count) : (index += 1) {
        const name: ?[*:0]const u8 = c.alGetStringiSOFT(c.AL_RESAMPLER_NAME_SOFT, index);
        const found = name orelse continue;
        if (std.mem.eql(u8, std.mem.span(found), resampler_name)) return index;
    }
    return null;
}

/// A WAVE sound decoded into 16-bit samples in a new buffer.
fn decode(gpa: Allocator, file: []const u8) ?Buffer {
    const header = wave.Wave.parse(file) catch return null;
    var decoder = wave.Decoder.init(header) catch return null;
    const channels: usize = if (header.channels == 2) 2 else 1;
    const samples = gpa.alloc(i16, decoder.frames * channels) catch return null;
    defer gpa.free(samples);
    var at: usize = 0;
    while (decoder.next()) |frame| : (at += channels) @memcpy(samples[at..][0..channels], frame[0..channels]);
    var name: c.ALuint = 0;
    c.alGenBuffers(1, &name);
    const format: c.ALenum = if (channels == 2) c.AL_FORMAT_STEREO16 else c.AL_FORMAT_MONO16;
    c.alBufferData(name, format, samples.ptr, @intCast(samples.len * @sizeOf(i16)), @intCast(header.rate));
    if (c.alGetError() != c.AL_NO_ERROR) {
        c.alDeleteBuffers(1, &name);
        return null;
    }
    return .{ .name = name, .rate = header.rate, .frames = decoder.frames, .channels = @intCast(channels) };
}

fn gain(volume: i32) f32 {
    return @as(f32, @floatFromInt(volume)) / 127;
}

/// A vector in Miles's frame, `+z` ahead, in OpenAL's, `-z` ahead.
fn openAl(v: mss.Vector) mss.Vector {
    return .{ v[0], v[1], -v[2] };
}

/// A 3D sample's velocity, held along the line to the listener as the software mixer holds it.
fn setVelocity(voice: *Voice) void {
    const held = mss.positional.dopplerVelocity(voice.position, voice.velocity);
    const moving = openAl(held) * @as(mss.Vector, @splat(velocity_scale));
    c.alSource3f(voice.source, c.AL_VELOCITY, moving[0], moving[1], moving[2]);
}

fn setPitch(voice: *Voice) void {
    const buffer = voice.buffer orelse return;
    if (buffer.rate == 0) return;
    const pitch = @as(f32, @floatFromInt(voice.rate)) / @as(f32, @floatFromInt(buffer.rate));
    c.alSourcef(voice.source, c.AL_PITCH, @max(pitch, 0.001));
}

fn releaseStream(slot: *Stream) void {
    c.alSourceStop(slot.source);
    c.alSourcei(slot.source, c.AL_BUFFER, 0);
    if (slot.open) |held| c.alDeleteBuffers(1, &held.buffer.name);
    slot.open = null;
}

fn deleteSource(source: c.ALuint) void {
    c.alSourceStop(source);
    c.alDeleteSources(1, &source);
}

fn stopVoice(voice: *Voice) void {
    c.alSourceStop(voice.source);
    c.alSourcei(voice.source, c.AL_BUFFER, 0);
}

/// Plays the voice's sound from the start, as many times as its loop count says: for ever, once,
/// or queued that many times.
fn startVoice(voice: *Voice) void {
    const buffer = voice.buffer orelse return;
    stopVoice(voice);
    switch (voice.loops) {
        0, 1 => {
            c.alSourcei(voice.source, c.AL_BUFFER, @intCast(buffer.name));
            c.alSourcei(voice.source, c.AL_LOOPING, if (voice.loops == 0) c.AL_TRUE else c.AL_FALSE);
        },
        else => {
            c.alSourcei(voice.source, c.AL_LOOPING, c.AL_FALSE);
            const names: [64]c.ALuint = @splat(buffer.name);
            c.alSourceQueueBuffers(voice.source, @intCast(@min(voice.loops, names.len)), &names);
        },
    }
    c.alSourcePlay(voice.source);
}

fn pauseSource(source: c.ALuint) void {
    if (sourceState(source) == c.AL_PLAYING) c.alSourcePause(source);
}

fn resumeSource(source: c.ALuint) void {
    if (sourceState(source) == c.AL_PAUSED) c.alSourcePlay(source);
}

fn sourceState(source: c.ALuint) c.ALint {
    var state: c.ALint = 0;
    c.alGetSourcei(source, c.AL_SOURCE_STATE, &state);
    return state;
}

/// Miles's status for a source's state: paused is stopped part of the way, and a source that has
/// never played or has finished is done.
fn statusOf(source: c.ALuint) mss.Status {
    return switch (sourceState(source)) {
        c.AL_PLAYING => .playing,
        c.AL_PAUSED => .stopped,
        else => .done,
    };
}

test Renderer {
    const gpa = std.testing.allocator;
    const renderer = Renderer.create(gpa, 22050, 2, .{}) catch return error.SkipZigTest;
    defer renderer.destroy();
    const driver = renderer.driver();
    try std.testing.expect(renderer.resampler != null);
    try std.testing.expect(renderer.slot != 0);
    try std.testing.expectEqual(c.ALC_STEREO_UHJ_SOFT, renderer.outputMode());

    // A 3D sample to the right, heard in the right ear more than the left.
    const file = comptime openreliant.wave.testing.pcm(&std.mem.toBytes([_]i16{16384} ** 2048));
    const placed = driver.allocate3DSample().?;
    try std.testing.expect(driver.set3DSampleFile(placed, file));
    try std.testing.expectEqual(4096, driver.sample3DLength(placed));
    driver.set3DPosition(placed, .{ 1, 0, 0 });
    driver.set3DSampleDistances(placed, 100, 1);
    try std.testing.expectEqual(mss.Status.done, driver.sample3DStatus(placed));
    driver.start3DSample(placed);
    try std.testing.expectEqual(mss.Status.playing, driver.sample3DStatus(placed));
    var out: [2 * 1024]f32 = undefined;
    renderer.render(&out);
    var left: f32 = 0;
    var right: f32 = 0;
    for (0..1024) |frame| {
        left += @abs(out[2 * frame]);
        right += @abs(out[2 * frame + 1]);
    }
    try std.testing.expect(right > left);

    // Paused, it is stopped part of the way; ended, done.
    driver.stop3DSample(placed);
    try std.testing.expectEqual(mss.Status.stopped, driver.sample3DStatus(placed));
    driver.end3DSample(placed);
    try std.testing.expectEqual(mss.Status.done, driver.sample3DStatus(placed));

    // A stream with a loop block plays for ever from its loop point.
    const music = driver.openStream(file).?;
    driver.setStreamLoopCount(music, 0);
    driver.setStreamLoopBlock(music, 1024, -1);
    driver.startStream(music);
    try std.testing.expectEqual(mss.Status.playing, driver.streamStatus(music));
    driver.closeStream(music);
}

test "HRTF" {
    const renderer = Renderer.create(std.testing.allocator, 44100, 2, .{ .hrtf = true }) catch return error.SkipZigTest;
    defer renderer.destroy();
    try std.testing.expectEqual(c.ALC_STEREO_HRTF_SOFT, renderer.outputMode());
}
