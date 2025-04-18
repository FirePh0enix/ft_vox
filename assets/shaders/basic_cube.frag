#version 450

layout(location = 0) in vec2 textureCoords;
layout(location = 1) in vec3 normal;
layout(location = 2) flat in uint textureIndex;

layout(location = 0) out vec4 outColor;

layout(binding = 0) uniform sampler2DArray images;
// layout(binding = 1) uniform sampler2D shadowTexture;

void main() {
    vec2 textureCoords2 = textureCoords;
    textureCoords2.y = 1.0 - textureCoords2.y;
    outColor = texture(images, vec3(textureCoords2, float(textureIndex)));
}
