#version 450

layout(location = 0) in vec3 inPos;
layout(location = 1) in vec3 inNormal;
layout(location = 2) in vec2 inTexCoords;

layout(location = 3) in vec2 inBounds;
layout(location = 4) in vec3 inCharPos;
layout(location = 5) in vec2 inScale;

layout(location = 0) out vec2 outTexCoords;
layout(location = 1) out vec4 outColor;

layout(push_constant) uniform PushConst {
    mat4 projection;
};

void main(){
    vec2 uv[4] = vec2[](
        vec2(inBounds.x, 0.0),
        vec2(inBounds.y, 0.0),
        vec2(inBounds.y, 1.0),
        vec2(inBounds.x, 1.0)
    );

    mat4 translationMatrix = mat4(
        1.0, 0.0, 0.0, 0.0,
        0.0, 1.0, 0.0, 0.0,
        0.0, 0.0, 1.0, 0.0,
        inCharPos.x, inCharPos.y, inCharPos.z, 1.0
    );

    mat4 scaleMatrix = mat4(
        inScale.x, 0.0, 0.0, 0.0,
        0.0, inScale.y, 0.0, 0.0,
        0.0, 0.0, 1.0, 0.0,
        0.0, 0.0, 0.0, 1.0
    );

    mat4 modelMatrix = translationMatrix * scaleMatrix;

    gl_Position = projection * modelMatrix * vec4(inPos, 1.0);

    outTexCoords = uv[gl_VertexIndex];
}