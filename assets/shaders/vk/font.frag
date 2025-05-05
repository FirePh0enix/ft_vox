#version 450

layout(location = 0) in vec2 inTextCoords;

layout(location = 0) out vec4 outFragColor;

layout(binding = 0) uniform sampler2D text;
layout(binding = 1) uniform FontFragment{
    vec4 color;
};

void main(){
    vec2 uv2 = inTextCoords;
    // uv2.y = 1.0 - uv2.y;

    // vec4 sampled = vec4(1.0, 1.0, 1.0, texture(text, uv2).r);
    vec4 sampled = vec4(texture(text, uv2).r, 0.0, 0.0, 1.0);
    outFragColor = color * sampled;
}
