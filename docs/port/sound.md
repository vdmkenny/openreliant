# Sound System Architecture

The original StarLancer audio engine relied on the Miles Sound System (`MSS32.DLL`). In OpenReliant, sound calls route through an abstract audio interface (`mss.Driver` in [`engine/mss.zig`](../../src/engine/mss.zig)).

OpenReliant provides two backend implementations:
1. **OpenAL Soft** (default): High-performance 3D spatial audio with HRTF headphone virtualization, environmental reverb, and surround sound.
2. **Software Mixer**: A lightweight, sample-accurate stereo fallback matching the original Miles mixer behavior (used when `--original` is enabled).

Final mixed audio streams to modern output devices via SDL3 audio streams.

---

## Architecture Overview

| Module | Replaces | Responsibility |
|---|---|---|
| [`formats/wave.zig`](../../src/formats/wave.zig) | Miles WAVE reader | Decodes 8-bit/16-bit PCM and 4-bit IMA ADPCM wave audio streams. |
| [`engine/mss.zig`](../../src/engine/mss.zig) | `MSS32.DLL` | Digital sound driver API, sample handles, 3D sample handles, and software fallback mixer. |
| [`engine/mss/voice.zig`](../../src/engine/mss/voice.zig) | Miles voice mixer | Per-voice playback state, sample rate conversion, and looping logic. |
| [`engine/mss/positional.zig`](../../src/engine/mss/positional.zig) | Miles 3D providers | Pure software 3D panning and distance attenuation fallback. |
| [`engine/mss/master.zig`](../../src/engine/mss/master.zig) | *(New)* | Master bus dynamic range compressor and peak lookahead limiter. |
| [`platform/openal.zig`](../../src/platform/openal.zig) | Miles 3D / EAX / A3D | OpenAL Soft backend: hardware spatialization, Doppler shift, HRTF, and reverb. |
| [`platform/audio.zig`](../../src/platform/audio.zig) | `AIL_waveOutOpen` | SDL3 audio device management, format negotiation, and output buffer streaming. |

---

## Driver Interface (`mss.Driver`)

The driver provides functional equivalents for Miles `AIL_*` calls:
- **Standard Samples**: Short, one-shot sound effects loaded into memory.
- **3D Positional Samples**: Spatial audio positioned in 3D world space with distance roll-off models.
- **Audio Streams**: Streaming music and background audio decoded block-by-block from ADPCM files.

### Distance Attenuation
3D audio sources calculate volume roll-off using an inverse distance clamped model matching DirectSound3D:
- Full volume within the source's minimum distance (`min_dist`).
- Attenuation falls off inversely proportional to distance between `min_dist` and `max_dist`.
- Velocity-based Doppler pitch shifting operates along the listener vector, clamped to 0.5x the speed of sound (343 m/s) to prevent audio distortion.

---

## OpenAL Soft Integration

OpenAL Soft is statically linked and compiled from source with embedded HRTF data. It operates through an in-memory loopback device from which SDL3 pulls rendered audio.

### Spatial Audio Enhancements
- **High-Order Sinc Resampling**: Audio sources are resampled using OpenAL Soft's 23rd-order band-limited sinc resampler, preventing aliasing distortion.
- **Dynamic HRTF Detection**: When headphones are detected (via OS device properties or Bluetooth flags), OpenAL Soft enables Head-Related Transfer Function (HRTF) processing for binaural 3D audio. On stereo speakers, it falls back to standard stereo panning or Ambisonic UHJ encoding.
- **Moving Listener Doppler**: Listener velocity matches the player ship's instantaneous velocity, ensuring Doppler effects reflect relative closing speeds without pitch-shifting the player's own engine sounds.
- **Volumetric Sound Sources (`AL_SOURCE_RADIUS`)**: Audio attached to capital ships scales by the ship's bounding radius. When flying close to a massive carrier, the sound surrounds the player rather than emanating from an arbitrary center point.
- **High-Frequency Air Absorption**: Distant sounds experience atmospheric high-frequency roll-off (`AL_AIR_ABSORPTION_FACTOR`).
- **Cockpit Reverb Filtering**: Voice warnings and cockpit alarms route through a dedicated, tight cockpit acoustic space, while external combat sounds use open space reverb parameters.

---

## Master Bus Processing

All rendered audio passes through a master bus module ([`engine/mss/master.zig`](../../src/engine/mss/master.zig)) before hardware output:

- **Soft-Knee Compressor**: Features a -18 dBFS threshold, 2:1 ratio, 6 dB soft knee, 10 ms attack, and 200 ms release with 2 dB make-up gain. This maintains clear dialogue and prevents combat audio from becoming fatiguing.
- **Peak Limiter**: A 3 ms lookahead limiter clamps peaks at -0.3 dBFS, eliminating digital clipping during heavy explosive combat.

*(Use `--no-compressor` to bypass dynamic range compression while keeping the limiter, or `--original` to bypass the entire master bus).*

---

## Hardware Output & Window Management

Audio outputs at 32-bit floating point at the device's native sample rate.

When the game window loses focus, OpenReliant automatically pauses music playback and game audio. When returning to the window, audio resumes seamlessly without buffer desynchronization.

---

## Pending Work

- Radio speech streaming buffer decompression.
- Audio CD redbook playback support.
