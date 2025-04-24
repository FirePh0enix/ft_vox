#version 450

layout(location = 0) in vec4 position;
layout(location = 1) in vec2 uv;
layout(location = 2) in vec3 normal;
layout(location = 3) in vec3 lightVec;
layout(location = 4) in vec4 shadowCoords;
layout(location = 5) flat in uint textureIndex;
layout(location = 6) flat in uint gradient;
layout(location = 7) flat in uint gradientType;

layout(location = 0) out vec4 outColor;

layout(binding = 0) uniform sampler2DArray images;
layout(binding = 1) uniform sampler2D shadowMap;

// https://github.com/SaschaWillems/Vulkan/blob/master/examples/shadowmapping/shadowmapping.cpp

#define ambient 0.1

float textureProj(vec4 shadowCoord, vec2 off)
{
    float shadow = 1.0;
    if ( shadowCoord.z > -1.0 && shadowCoord.z < 1.0 ) 
    {
        float dist = texture( shadowMap, shadowCoord.st + off ).r;
        if ( shadowCoord.w > 0.0 && dist < shadowCoord.z ) 
        {
            shadow = ambient;
        }
    }
    return shadow;
}

float filterPCF(vec4 sc)
{
    ivec2 texDim = textureSize(shadowMap, 0);
    float scale = 1.5;
    float dx = scale * 1.0 / float(texDim.x);
    float dy = scale * 1.0 / float(texDim.y);

    float shadowFactor = 0.0;
    int count = 0;
    int range = 1;

    for (int x = -range; x <= range; x++)
    {
        for (int y = -range; y <= range; y++)
        {
            shadowFactor += textureProj(sc, vec2(dx*x, dy*y));
            count++;
        }
    }
    return shadowFactor / count;
}

bool isGrayscale(vec4 color) {
    return color.r == color.g && color.g == color.b;
}

void main() {
    vec2 uv2 = uv;
    uv2.y = 1.0 - uv2.y;
    
    vec4 color = texture(images, vec3(uv2, float(textureIndex)));

    if (isGrayscale(color) && gradientType > 0) {
        color *= vec4(9.0 / 255.0, 128.0 / 255.0, 43.0 / 255.0, 1.0);
    }

    float shadow = textureProj(shadowCoords / shadowCoords.w, vec2(0.0)); // filterPCF(shadowCoords / shadowCoords.w);

    vec3 N = normalize(normal);
    vec3 L = normalize(lightVec);
    vec3 V = normalize(position.xyz);
    vec3 R = normalize(-reflect(L, N));
    vec3 diffuse = max(dot(N, -L), ambient) * color.rgb;

    // outColor = vec4(shadow * diffuse, 1.0);
    outColor = vec4(diffuse, color.a);
    // outColor = color;
}
