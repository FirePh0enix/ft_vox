#version 450

layout(location = 0) in vec3 inPos;
layout(location = 1) in vec3 inNormal;
layout(location = 2) in vec2 inTexCoords;

layout (location = 0) out vec3 outTexCoords; 

layout(push_constant) uniform PushConst {
    mat4 viewMatrix;
};

void main(){
    outTexCoords = vec3(inTexCoords, 0.0);
    mat4 viewMat = mat4(mat3(viewMatrix));
    gl_Position = viewMatrix * vec4(inPos, 1.0);
}
