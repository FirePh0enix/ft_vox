#version 450

layout(location = 0) in vec3 inPos;
layout(location = 0) out vec3 texCoords;

layout(push_constant) uniform PushConst {
    mat4 viewProj;
};

void main() {
    texCoords = inPos;
    vec4 pos = viewProj * vec4(inPos, 1.0);
    gl_Position = pos;
    gl_Position.z = gl_Position.w; 
}
