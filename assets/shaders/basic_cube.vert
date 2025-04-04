#version 450

// Per vertex data
layout(location = 0) in vec3 position;
layout(location = 1) in vec3 normal;
layout(location = 2) in vec2 textureCoords;

// Per instance data
layout(location = 3) in vec3 instancePosition;
layout(location = 4) in vec3 texture0;
layout(location = 5) in vec3 texture1;

layout(location = 0) out vec2 fragTextureCoords;
layout(location = 1) out vec3 fragNormal;
layout(location = 2) out uint textureIndex;

layout(push_constant) uniform PushConstants {
    mat4 cameraMatrix;
};

void main() {
    mat4 modelMatrix = mat4(
        1.0, 0.0, 0.0, 0.0,
        0.0, 1.0, 0.0, 0.0,
        0.0, 0.0, 1.0, 0.0,
        instancePosition.x, instancePosition.y, instancePosition.z, 1.0
    );

    gl_Position = cameraMatrix * modelMatrix * vec4(position, 1.0);
    fragTextureCoords = textureCoords;
    fragNormal = normal;

    uint textureIndices[] = uint[](uint(texture0.x), uint(texture0.y), uint(texture0.z), uint(texture1.x), uint(texture1.y), uint(texture1.z));
    textureIndex = textureIndices[gl_VertexIndex / 4];
}
