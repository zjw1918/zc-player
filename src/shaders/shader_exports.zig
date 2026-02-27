const std = @import("std");

const video_vert_spv = @embedFile("video.vert.spv");
const video_frag_spv = @embedFile("video.frag.spv");

pub export fn zc_shader_video_vert_spv_ptr() [*]const u8 {
    return video_vert_spv.ptr;
}

pub export fn zc_shader_video_vert_spv_len() usize {
    return video_vert_spv.len;
}

pub export fn zc_shader_video_frag_spv_ptr() [*]const u8 {
    return video_frag_spv.ptr;
}

pub export fn zc_shader_video_frag_spv_len() usize {
    return video_frag_spv.len;
}

test "embedded shaders are non-empty and word-aligned sized" {
    try std.testing.expect(video_vert_spv.len > 0);
    try std.testing.expect(video_frag_spv.len > 0);
    try std.testing.expect(video_vert_spv.len % 4 == 0);
    try std.testing.expect(video_frag_spv.len % 4 == 0);
}
