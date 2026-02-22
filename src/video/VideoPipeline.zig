const c = @import("../ffi/cplayer.zig").c;
const Player = @import("../media/Player.zig").Player;

pub const VideoPipeline = struct {
    pub const FrameFormat = enum(c_int) {
        rgba = c.VIDEO_FRAME_FORMAT_RGBA,
        yuv420p = c.VIDEO_FRAME_FORMAT_YUV420P,
        nv12 = c.VIDEO_FRAME_FORMAT_NV12,
    };

    pub const VideoFrame = struct {
        data: [*c]u8,
        width: c_int,
        height: c_int,
        linesize: c_int,
        format: FrameFormat,
    };

    handle: c.VideoPipeline = undefined,
    initialized: bool = false,

    pub fn init(self: *VideoPipeline, player: *Player) !void {
        if (c.video_pipeline_init(&self.handle, player.raw()) != 0) {
            return error.InitFailed;
        }
        self.initialized = true;
    }

    pub fn start(self: *VideoPipeline) !void {
        if (!self.initialized) {
            return error.NotInitialized;
        }
        if (c.video_pipeline_start(&self.handle) != 0) {
            return error.StartFailed;
        }
    }

    pub fn destroy(self: *VideoPipeline) void {
        if (!self.initialized) {
            return;
        }
        c.video_pipeline_destroy(&self.handle);
        self.initialized = false;
    }

    pub fn reset(self: *VideoPipeline) void {
        if (!self.initialized) {
            return;
        }
        c.video_pipeline_reset(&self.handle);
    }

    pub fn getFrameForRender(self: *VideoPipeline, master_clock: f64) ?VideoFrame {
        if (!self.initialized) {
            return null;
        }

        var data: [*c]u8 = null;
        var width: c_int = 0;
        var height: c_int = 0;
        var linesize: c_int = 0;

        const ret = c.video_pipeline_get_frame_for_render(
            &self.handle,
            master_clock,
            &data,
            &width,
            &height,
            &linesize,
        );

        if (ret <= 0) {
            return null;
        }

        return VideoFrame{
            .data = data,
            .width = width,
            .height = height,
            .linesize = linesize,
            .format = .rgba,
        };
    }
};
