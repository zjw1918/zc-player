const c = @import("../ffi/cplayer.zig").c;
const Player = @import("../media/Player.zig").Player;

pub const AudioOutput = struct {
    handle: c.AudioOutput = undefined,
    initialized: bool = false,

    pub fn init(self: *AudioOutput, player: *Player) !void {
        if (c.audio_output_init(&self.handle, player.raw()) != 0) {
            return error.InitFailed;
        }
        self.initialized = true;
    }

    pub fn start(self: *AudioOutput) !void {
        if (!self.initialized) {
            return error.NotInitialized;
        }
        if (c.audio_output_start(&self.handle) != 0) {
            return error.StartFailed;
        }
    }

    pub fn destroy(self: *AudioOutput) void {
        if (!self.initialized) {
            return;
        }
        c.audio_output_destroy(&self.handle);
        self.initialized = false;
    }

    pub fn reset(self: *AudioOutput) void {
        if (!self.initialized) {
            return;
        }
        c.audio_output_reset(&self.handle);
    }

    pub fn setPaused(self: *AudioOutput, paused: bool) void {
        if (!self.initialized) {
            return;
        }
        c.audio_output_set_paused(&self.handle, if (paused) 1 else 0);
    }

    pub fn setVolume(self: *AudioOutput, volume: f64) void {
        if (!self.initialized) {
            return;
        }
        c.audio_output_set_volume(&self.handle, volume);
    }

    pub fn setSpeed(self: *AudioOutput, speed: f64) void {
        if (!self.initialized) {
            return;
        }
        c.audio_output_set_playback_speed(&self.handle, speed);
    }

    pub fn masterClock(self: *AudioOutput) ?f64 {
        if (!self.initialized) {
            return null;
        }

        var clock: f64 = -1.0;
        if (c.audio_output_get_master_clock(&self.handle, &clock) != 0) {
            return null;
        }
        return clock;
    }
};
