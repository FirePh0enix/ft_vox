#version 450

layout(location = 0) in vec3 position;
layout(location = 1) in vec2 textureCoords;
layout(location = 2) in vec3 modelPosition;

layout(location = 0) out vec2 fragTextureCoords;

layout(push_constant) uniform PushConstants {
    mat4 cameraMatrix;
};

void main() {
    mat4 modelMatrix = mat4(
        1.0, 0.0, 0.0, 0.0,
        0.0, 1.0, 0.0, 0.0,
        0.0, 0.0, 1.0, 0.0,
        modelPosition.x, modelPosition.y, modelPosition.z, 1.0
    );

    gl_Position = cameraMatrix * modelMatrix * vec4(position, 1.0);
    fragTextureCoords = textureCoords;
}
