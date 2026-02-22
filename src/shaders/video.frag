#version 450

layout(location = 0) in vec2 fragTexCoord;
layout(binding = 0) uniform sampler2D video_texture_rgba;
layout(binding = 1) uniform sampler2D video_texture_y;
layout(binding = 2) uniform sampler2D video_texture_uv_or_u;
layout(binding = 3) uniform sampler2D video_texture_v;

layout(push_constant) uniform VideoPushConstants {
    int mode;
} video_pc;

layout(location = 0) out vec4 outColor;

vec3 yuv_to_rgb(float y, float u, float v) {
    float y_lin = max(y - (16.0 / 255.0), 0.0) * (255.0 / 219.0);
    float u_centered = u - 0.5;
    float v_centered = v - 0.5;

    return vec3(
        y_lin + 1.5748 * v_centered,
        y_lin - 0.1873 * u_centered - 0.4681 * v_centered,
        y_lin + 1.8556 * u_centered);
}

void main() {
    vec2 uv = vec2(fragTexCoord.x, 1.0 - fragTexCoord.y);

    if (video_pc.mode == 1) {
        float y = texture(video_texture_y, uv).r;
        vec2 uv_sample = texture(video_texture_uv_or_u, uv).rg;
        outColor = vec4(yuv_to_rgb(y, uv_sample.r, uv_sample.g), 1.0);
    } else if (video_pc.mode == 2) {
        float y = texture(video_texture_y, uv).r;
        float u = texture(video_texture_uv_or_u, uv).r;
        float v = texture(video_texture_v, uv).r;
        outColor = vec4(yuv_to_rgb(y, u, v), 1.0);
    } else {
        outColor = texture(video_texture_rgba, uv);
    }
}
