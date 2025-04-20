#version 450

layout(location = 0) in vec4 position;
layout(location = 1) in vec2 textureCoords;
layout(location = 2) in vec3 normal;
layout(location = 3) in vec4 posLightSpace;
layout(location = 4) flat in uint textureIndex;

layout(location = 0) out vec4 outColor;

layout(binding = 0) uniform sampler2DArray images;
layout(binding = 1) uniform sampler2D shadowMap;
layout(binding = 2) uniform Light {
    vec3 dir;
} light;

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

void main() {
    vec2 textureCoords2 = textureCoords;
    textureCoords2.y = 1.0 - textureCoords2.y;
    
    vec3 color = texture(images, vec3(textureCoords2, float(textureIndex))).rgb;
    float shadow = filterPCF(posLightSpace / posLightSpace.w);

    vec3 lightDir = vec3(-1.0, 1.0, 0.0);

    vec3 N = normalize(normal);
    vec3 L = normalize(lightDir);
    vec3 V = normalize(position.xyz);
    vec3 R = normalize(-reflect(L, N));
    vec3 diffuse = max(dot(N, L), ambient) * color;

    outColor = vec4(diffuse, 1.0);
}
