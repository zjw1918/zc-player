comptime {
    _ = @import("../media/demuxer_exports.zig");
    _ = @import("../media/player_exports.zig");
    _ = @import("../video/video_pipeline_exports.zig");
    _ = @import("../audio/audio_output_exports.zig");
    _ = @import("../video/video_decoder_exports.zig");
    _ = @import("../audio/audio_decoder_exports.zig");
    _ = @import("../shaders/shader_exports.zig");
}

pub const c = @cImport({
    @cInclude("player/player.h");
    @cInclude("audio/audio_output.h");
    @cInclude("video/video_pipeline.h");
});
