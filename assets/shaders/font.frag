#version 450

layout(location = 0) in vec2 inTextCoords;

layout(location = 0) out vec4 outFragColor;

layout(binding = 0) uniform sampler2D text;
layout(binding = 1) uniform FontFragment{
    vec4 color;
};

void main(){
    outFragColor = color * vec4(1.0, 1.0, 1.0, texture(text, inTextCoords).r);
}
