#version 450

layout(location = 0) out vec2 fragTexCoord;

void main() {
    vec2 positions[6] = vec2[](
        vec2(-1.0, -1.0),
        vec2( 1.0, -1.0),
        vec2(-1.0,  1.0),
        vec2( 1.0, -1.0),
        vec2( 1.0,  1.0),
        vec2(-1.0,  1.0)
    );
    vec2 texcoords[6] = vec2[](
        vec2(0.0, 1.0),
        vec2(1.0, 1.0),
        vec2(0.0, 0.0),
        vec2(1.0, 1.0),
        vec2(1.0, 0.0),
        vec2(0.0, 0.0)
    );
    gl_Position = vec4(positions[gl_VertexIndex], 0.0, 1.0);
    fragTexCoord = texcoords[gl_VertexIndex];
}
