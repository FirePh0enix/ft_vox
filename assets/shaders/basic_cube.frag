#version 450

layout(location = 0) in vec2 textureCoords;
layout(location = 1) in vec3 normal;

layout(location = 0) out vec4 outColor;

layout(binding = 0) uniform sampler2D image;
layout(binding = 1) uniform Light
{
    vec4 sun_direction;
    vec4 sun_color;
};

const float min_brightness = 0.1;

void main() {
    float brightness = clamp(dot(normalize(sun_direction.xyz), -normalize(normal)), min_brightness, 1.0);
    outColor = brightness * sun_color * texture(image, textureCoords);
}
