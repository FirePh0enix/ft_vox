#version 450

layout(location = 0) in vec2 textureCoords;

layout(location = 0) out vec4 outColor;

layout(binding = 0) uniform sampler2D image;

void main() {
    outColor = texture(image, textureCoords);
}
