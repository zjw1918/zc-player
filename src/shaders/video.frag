#version 450

layout(location = 0) in vec2 fragTexCoord;
layout(binding = 0) uniform sampler2D video_texture;

layout(location = 0) out vec4 outColor;

void main() {
    outColor = texture(video_texture, vec2(fragTexCoord.x, 1.0 - fragTexCoord.y));
}
