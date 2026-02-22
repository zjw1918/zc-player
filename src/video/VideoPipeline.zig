const c = @import("../ffi/cplayer.zig").c;
const Player = @import("../media/Player.zig").Player;

pub const VideoPipeline = struct {
    pub const FrameFormat = enum(c_int) {
        rgba = c.VIDEO_FRAME_FORMAT_RGBA,
        yuv420p = c.VIDEO_FRAME_FORMAT_YUV420P,
        nv12 = c.VIDEO_FRAME_FORMAT_NV12,
    };

    pub const VideoFrame = struct {
        planes: [3][*c]u8,
        linesizes: [3]c_int,
        plane_count: c_int,
        width: c_int,
        height: c_int,
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

        var planes: [3][*c]u8 = .{ null, null, null };
        var width: c_int = 0;
        var height: c_int = 0;
        var linesizes: [3]c_int = .{ 0, 0, 0 };
        var plane_count: c_int = 0;
        var format: c_int = c.VIDEO_FRAME_FORMAT_RGBA;

        const ret = c.video_pipeline_get_frame_for_render(
            &self.handle,
            master_clock,
            &planes,
            &width,
            &height,
            &linesizes,
            &plane_count,
            &format,
        );

        if (ret <= 0) {
            return null;
        }

        return VideoFrame{
            .planes = planes,
            .linesizes = linesizes,
            .plane_count = plane_count,
            .width = width,
            .height = height,
            .format = switch (format) {
                c.VIDEO_FRAME_FORMAT_NV12 => .nv12,
                c.VIDEO_FRAME_FORMAT_YUV420P => .yuv420p,
                else => .rgba,
            },
        };
    }
};
