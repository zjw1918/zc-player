const sdl = @import("../ffi/sdl.zig").c;

pub const SdlRuntime = struct {
    initialized: bool = false,

    pub fn init(self: *SdlRuntime) !void {
        if (self.initialized) {
            return;
        }

        if (!sdl.SDL_Init(sdl.SDL_INIT_EVENTS | sdl.SDL_INIT_AUDIO)) {
            return error.SdlInitFailed;
        }

        self.initialized = true;
    }

    pub fn deinit(self: *SdlRuntime) void {
        if (!self.initialized) {
            return;
        }

        sdl.SDL_Quit();
        self.initialized = false;
    }
};
