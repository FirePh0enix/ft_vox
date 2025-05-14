#version 450

layout(location = 0) in vec3 inTexCoords;

layout(location = 0) out vec4 outFragColor;

layout(binding = 0) uniform sampler2DArray cubemap;

void main(){
    outFragColor = texture(cubemap, inTexCoords);
    gl_FragDepth = 1.0;
}
