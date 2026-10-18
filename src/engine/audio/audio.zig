const std = @import("std");
const sdl = @import("sdl3");

pub const AudioEngine = struct {
    stream: ?*sdl.SDL_AudioStream = null,
    sample_rate: c_int = 44100,
    channels: c_int = 1,
    initialized: bool = false,

    pub fn init() AudioEngine {
        var engine = AudioEngine{};
        if (!sdl.SDL_InitSubSystem(sdl.SDL_INIT_AUDIO)) {
            std.log.warn("SDL3 Audio subsystem initialization failed or audio unavailable", .{});
            return engine;
        }

        const spec = sdl.SDL_AudioSpec{
            .format = @as(u32, @bitCast(sdl.SDL_AUDIO_F32)),
            .channels = 1,
            .freq = 44100,
        };

        const stream = sdl.SDL_OpenAudioDeviceStream(
            sdl.SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK,
            &spec,
            null,
            null,
        );

        if (stream) |s| {
            _ = sdl.SDL_ResumeAudioStreamDevice(s);
            engine.stream = s;
            engine.initialized = true;
            std.log.info("SDL3 AudioEngine initialized successfully (44100 Hz, Float32 Mono)", .{});
        } else {
            std.log.warn("Failed to open SDL3 audio device stream", .{});
        }

        return engine;
    }

    pub fn deinit(self: *AudioEngine) void {
        if (self.stream) |s| {
            sdl.SDL_DestroyAudioStream(s);
            self.stream = null;
        }
        self.initialized = false;
    }

    /// Synthesize and play a clean sine wave tone with linear envelope
    pub fn playTone(self: *AudioEngine, frequency: f32, duration_sec: f32, volume: f32) void {
        const stream = self.stream orelse return;
        if (duration_sec <= 0.0 or volume <= 0.0) return;
        const total_samples: usize = @intFromFloat(@as(f32, @floatFromInt(self.sample_rate)) * duration_sec);
        if (total_samples == 0) return;

        var buffer: [2048]f32 = undefined;
        var samples_generated: usize = 0;

        while (samples_generated < total_samples) {
            const remaining = total_samples - samples_generated;
            const chunk_size = @min(buffer.len, remaining);
            for (0..chunk_size) |i| {
                const sample_idx = samples_generated + i;
                const t = @as(f32, @floatFromInt(sample_idx)) / @as(f32, @floatFromInt(self.sample_rate));
                const progress = @as(f32, @floatFromInt(sample_idx)) / @as(f32, @floatFromInt(total_samples));
                // Linear decay envelope
                const envelope = (1.0 - progress) * volume;
                buffer[i] = @sin(t * frequency * 2.0 * std.math.pi) * envelope;
            }

            const chunk_c_int: c_int = @intCast(chunk_size);
            const num_bytes: c_int = chunk_c_int * 4;
            _ = sdl.SDL_PutAudioStreamData(stream, &buffer, num_bytes);
            samples_generated += chunk_size;
        }
    }

    /// Synthesize a deep physical impact sound with pitch drop and exponential decay
    pub fn playImpact(self: *AudioEngine, volume: f32) void {
        const stream = self.stream orelse return;
        const total_samples: usize = 4410; // ~0.10s
        var buffer: [4410]f32 = undefined;

        for (0..total_samples) |i| {
            const progress = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(total_samples));
            const t = @as(f32, @floatFromInt(i)) / 44100.0;
            const current_freq = 150.0 * (1.0 - progress * 0.75); // slides from 150Hz to ~37Hz
            const envelope = (1.0 - progress) * (1.0 - progress) * volume;
            buffer[i] = @sin(t * current_freq * 2.0 * std.math.pi) * envelope;
        }

        const bytes_len: c_int = @intCast(total_samples * @sizeOf(f32));
        _ = sdl.SDL_PutAudioStreamData(stream, &buffer, bytes_len);
    }

    /// Synthesize a cheerful dual-tone chime sound
    pub fn playChime(self: *AudioEngine, volume: f32) void {
        self.playTone(523.25, 0.08, volume * 0.6); // C5
        self.playTone(659.25, 0.12, volume * 0.8); // E5
    }
};
