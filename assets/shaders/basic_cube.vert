#version 450

layout(location = 0) in vec3 position;
layout(location = 1) in vec2 textureCoords;

layout(location = 0) out vec3 color;

layout(push_constant) uniform PushConstants {
    mat4 cameraMatrix;
};

// layout(binding = 2, location = 0) uniform sampler2D texture;

void main() {
    gl_Position = cameraMatrix * vec4(position, 1.0);
    color = vec3(1.0, 0.0, 0.0);
}
