#version 450

layout(location = 0) in vec3 position;
layout(location = 1) in vec2 textureCoords;

layout(location = 0) out vec2 fragTextureCoords;

layout(push_constant) uniform PushConstants {
    mat4 cameraMatrix;
};

void main() {
    gl_Position = cameraMatrix * vec4(position, 1.0);
    fragTextureCoords = textureCoords;
}
