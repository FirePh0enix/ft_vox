#version 450

layout (location=0) in vec3 inPos;
layout (location=1) in vec4 inColor;
layout (location=2) in vec2 inTexCoords;
layout (location=0) out vec2 outTexCoords;
layout (location=1) out vec4 outColor;

layout (push_constant) uniform PushConst{
	mat4 projection;
	
};

void main(){
	
	
	gl_Position = projection * vec4(inPos,1.0);
	
	outTexCoords = inTexCoords;
	outColor = inColor;
}