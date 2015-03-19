﻿Shader "Custom/Fill Volume" {
Properties {
	_DisplacementTexture("Displaced sphere", Cube) = "white" {}
	_RampTexture("Ramp Texture", 2D) = "" {}
}
SubShader {
	Pass{
	Cull Off ZWrite Off ZTest Off
	CGPROGRAM
	#pragma target 5.0
	#pragma exclude_renderers flash
	#pragma enable_d3d11_debug_symbols
	#pragma vertex vert_img		
	//#pragma vertex vert
	#pragma fragment frag
	#define NUM_VOXELS 32

	#include "UnityCG.cginc"

	// If filling the metavoxels via DrawMeshNow, we'll need to use a standard VS instead of the built-in vert_img
	// Note: DrawMeshNow doesn't work with multiple UAV writes. Hence going with Graphics.Blit in the main script
	//struct vs_input {
	//	float4 vertex : POSITION;
	//};

	//struct v2f {
	//	float4 pos : SV_POSITION;
	//};
		
	//v2f vert(vs_input i) {
	//	v2f o;
	//	o.pos = i.vertex;
	//	return o;
	//}

	// particle
	struct Particle {
		float4x4 mWorldToLocal;
		float3	mWorldPos;
		float	mRadius;
		float	mLifetimeOpacity; // [0.0, 1.0]
	};

	struct Voxel {
		float density; // affects opacity
		float ao; // affects color
	};
		
	// UAVs
	RWTexture3D<float4> volumeTex; // out
	RWTexture2D<float> lightPropogationTex; // in-out

	// Particles covering the current metavoxel
	StructuredBuffer<Particle> _Particles; // in

	// Textures
	samplerCUBE _DisplacementTexture;
	sampler2D _RampTexture;
	sampler2D _LightDepthMap;
		
	// Current metavoxel's constants
CBUFFER_START(MetavoxelConstants)
	float4x4 _MetavoxelToWorld;	
	float3 _MetavoxelIndex;
	int _NumParticles;		
CBUFFER_END
		
	// Uniforms over entire fill pass
	// -- light stuff
CBUFFER_START(LightConstants)
	float4x4 _WorldToLight;		
	float4x4 _LightProjection;
	float3 _LightForward; // worldspace
	float3 _LightColor;			
	float3 _AmbientColor;
	float _InitLightIntensity;
	float _NearZ, _FarZ;	
CBUFFER_END

	// -- metavoxel stuff
CBUFFER_START(VolumeConstants)
	float3 _MetavoxelGridDim;		
	float _NumVoxels; // (nv) each metavoxel is made up of nv * nv * nv voxels
	int _MetavoxelBorderSize;
	float _MetavoxelScaleZ;
CBUFFER_END
	
	// -- particle stuff
CBUFFER_START(ParticleConstants)
	float _OpacityFactor;
	int _FadeOutParticles;
	float _DisplacementScale;
CBUFFER_END	

	// helper methods
	float4 
	get_voxel_world_pos(float2 svPos, float zSlice)
	{
		// svPos goes from [0, numVoxels]. transform to a [-0.5, 0.5] range w.r.t metavoxel centered at origin
		// the metavoxel grid follows the light space -- i.e, x0, y0, z0 is left-bot-front (and closest to the light)
		// see VolumetricParticleRenderer::UpdateMetavoxelPositions()
		float3 voxelPos = float3(svPos, zSlice);
		float4 normPos = float4((svPos - _NumVoxels/2) / _NumVoxels, (zSlice - _NumVoxels/2) / _NumVoxels, 1.0);

		// with all dimensions in normalizaed unit cube (metavoxel) space, transform to world space
		return mul(_MetavoxelToWorld, normPos);
	}


	void 
	compute_voxel_color(float3 psVoxelPos	/*voxel position in particle space*/, 
						float opacity,		/*particle opacity -- particle fades away as it dies*/
						out Voxel v)
	{
		// sample the displacement noise texture for the particle
		float rawDisplacement = texCUBE(_DisplacementTexture,  2*psVoxelPos).x; // [todo] -- is the texcoord correct for cube sampling??

		// the scale factor can be used to weigh the above calculated noise displacement. 
		float netDisplacement = _DisplacementScale * rawDisplacement + (1.0 - _DisplacementScale); // disp. from center in the range [0, 1]

		float voxelParticleDistSq = dot(2 * psVoxelPos,  2 * psVoxelPos); // make it [0, 1]

		// how dense is this particle at the current voxel? (density falls quickly as we move to the outer surface of the particle)
		// voxelParticleDistSq < 0.7 * netDisplacement ==> baseDensity = 1, voxelParticleDistSq > netDisplacement ==> baseDensity = 0
		// 0.7 * netDisplacement < voxelParticleDistSq < netDisplacement ==> baseDensity ==> linear drop
		float baseDensity = smoothstep(netDisplacement, 0.7 * netDisplacement, voxelParticleDistSq); // [0.0, 1.0]
		float density = baseDensity *  _OpacityFactor; 
			
		// factor in the particle's lifetime opacity & opacity factor
		if (_FadeOutParticles == 1)
			density *= opacity;

		v.density = density;
		v.ao = netDisplacement;
	}


	// Fragment shader fills a "voxel column" of the metavoxel's volume texture
	// For each voxel in the voxel column of our metavoxel, we iterate through all the displaced particles covered by the metavoxel and test for coverage. 
	// If a displaced particle covers the voxel's center, we calculate its contribution to "density" and "ao". 
	float4 
	frag(v2f_img i) : COLOR
	//frag(v2f i) : COLOR
	{
		int slice, pp; // loop counters  			
		Voxel voxelColumn[NUM_VOXELS]; // temporary storage for the voxel column associated with the current fragment

		// Iterate through the voxel column with the first particle, clearing the voxel if it isn't covered
		// (This saves us a conditional check for every other particle)
		float oneVoxelSize = _MetavoxelScaleZ / _NumVoxels; // assuming scale is same in X and Y below (this scale includes the border)
		float3 voxel0WorldPos = get_voxel_world_pos(i.pos.xy, 0);
		float3 voxelWorldPos = voxel0WorldPos;

		for (slice = 0; slice < _NumVoxels; slice++)
		{
			Particle p = _Particles[0];
				
			// get world pos for the current voxel accounting for the "scaled" metavoxel			
			float3 psVoxelPos = mul( p.mWorldToLocal, float4(voxelWorldPos, 1.0) ); // voxel position in particle space
			float dist2 = dot(psVoxelPos, psVoxelPos);
				
			if (dist2 <= 0.25) // 0.5 * 0.5 -- if the voxel center is within the particle it'd be less than 0.5 units away from the particle center in particle space
			{
				compute_voxel_color(psVoxelPos, p.mLifetimeOpacity, voxelColumn[slice]);				
			}
			else 
			{
				// particle doesn't cover voxel. clear it.
				voxelColumn[slice].density = 0.0;
				voxelColumn[slice].ao      = 0.0;
			}				

			voxelWorldPos += _LightForward * oneVoxelSize;
		}

		voxelWorldPos = voxel0WorldPos; // reset
		// Iterate through all the remaining particles for every voxel in the voxel column
		for (slice = 0; slice < _NumVoxels; slice++)
		{
			for (pp = 1; pp < _NumParticles; pp++)
			{
				Particle p = _Particles[pp];

				float3 psVoxelPos = mul( p.mWorldToLocal, float4(voxelWorldPos, 1.0) ); // voxel position in particle space
				float dist2 = dot(psVoxelPos, psVoxelPos);
				Voxel v;

				if (dist2 <= 0.25) // 0.5 * 0.5 -- if the voxel center is within the particle it'd be less than 0.5 units away from the particle center in particle space
				{
					compute_voxel_color(psVoxelPos, p.mLifetimeOpacity, v);

					voxelColumn[slice].density += v.density;
					voxelColumn[slice].ao		= max(voxelColumn[slice].ao, v.ao);
				}
			} // per particle

			voxelWorldPos += _LightForward * oneVoxelSize;
		} // per slice
			
		// Account for occlusion of the voxel column by objects in the scene
		float4 lsVoxel0 =  mul(_WorldToLight, get_voxel_world_pos(i.pos.xy, 0));							
			
		float2 lsTexCoord = (i.pos.xy + _MetavoxelIndex.xy * _NumVoxels) / (_MetavoxelGridDim.xy * _NumVoxels);
		// don't need to invert the y component of UV (even though Unity renders to the depth texture with Y inverted).
		float d = tex2D(_LightDepthMap, lsTexCoord); // [0,1]						
		float a = rcp(_FarZ - _NearZ), b = -_NearZ * a;			
		float bias = 0.1;
		float lsSceneDepth = (d - b) * rcp(a);
	
		float lightTransmittedByVoxelColumn;

		if (lsSceneDepth < lsVoxel0.z) 
		{
			lightTransmittedByVoxelColumn = 0.0;

			// all voxels in this column are behind an object, and hence shadowed (i.e., no direct lighting)
			for (slice = 0; slice < _NumVoxels; slice++)
			{
				float4 voxelColor;
						
				if (voxelColumn[slice].density == 0)
					voxelColor = float4(0,0,0,0);
				else
					voxelColor = float4(voxelColumn[slice].ao * _AmbientColor, 
										voxelColumn[slice].density);
				
				volumeTex[int3(i.pos.xy, slice)]	=	voxelColor;			
			}				
		} // voxel column completely occluded
		else 
		{
			float lightIncidentOnVoxel;			
			lightIncidentOnVoxel = _InitLightIntensity;

			if (_MetavoxelIndex.z != 0) // if metavoxel isn't nearest to light, look up how much light was transmitted by the voxel columns in front of it (wrt the light)
				lightIncidentOnVoxel *= lightPropogationTex[int2(i.pos.xy + _MetavoxelIndex.xy * _NumVoxels)];

			float diffuseCoeff = 1.0;
			float lsVoxelDepth = lsVoxel0.z; 
			int borderVoxelIndex = _NumVoxels;// - _MetavoxelBorderSize;

			for (slice = 0; slice < borderVoxelIndex; slice++)
			{
				float4 voxelColor;
						
				if (voxelColumn[slice].density == 0)
					voxelColor = float4(0,0,0,0);
				else
					voxelColor = float4(lightIncidentOnVoxel * _LightColor * diffuseCoeff  /* direct lighting */ +   
										voxelColumn[slice].ao * _AmbientColor /* ambient component */, 
										voxelColumn[slice].density);
				
				volumeTex[int3(i.pos.xy, slice)]	=	voxelColor;
				
				if (lsVoxelDepth < lsSceneDepth) 			
				{
					// not in shadow. light incident on the next voxel depends on current voxel's density			
					lightIncidentOnVoxel *= rcp(1.0 + voxelColumn[slice].density);
				}
				else 
				{
					// voxel is occluded
					lightTransmittedByVoxelColumn = lightIncidentOnVoxel;
					lightIncidentOnVoxel = 0.0;
				}

				lsVoxelDepth += oneVoxelSize; 
			} // per voxel in column	


			// go over border voxels in the "far" end of the voxel column (this can be simplified if border is restricted to 0 or 1)
			// light transmitted by the "far border voxels" isn't written to the light propagation texture to ensure correct light transmittance to
			// the "near border voxels" of the voxel column behind this one 
			for(slice = borderVoxelIndex; slice < _NumVoxels; slice++) 
			{
				float4 voxelColor;
						
				if (voxelColumn[slice].density == 0)
					voxelColor = float4(0,0,0,0);
				else
					voxelColor = float4(lightIncidentOnVoxel * _LightColor * diffuseCoeff  /* direct lighting */ +   
										voxelColumn[slice].ao * _AmbientColor /* ambient component */, 
										voxelColumn[slice].density);
				
				volumeTex[int3(i.pos.xy, slice)]	=	voxelColor;
				
				if (lsVoxelDepth < lsSceneDepth) 			
				{
					// not in shadow. light incident on the next voxel depends on current voxel's density			
					lightIncidentOnVoxel *= rcp(1.0 + voxelColumn[slice].density);
				}
				else 
				{
					// voxel is occluded
					lightIncidentOnVoxel = 0.0;
				}

				lsVoxelDepth += oneVoxelSize; 
			}						
		} // voxel column not completely occluded
				
		lightPropogationTex[int2(i.pos.xy + _MetavoxelIndex.xy * _NumVoxels)] = lightTransmittedByVoxelColumn; // exclude the exit border voxel to prevent inconsistencies in next metavoxel		

		/* this fragment shader does NOT return anything. it's merely used for filling a voxel column while propagating light through it*/
		discard;
		return float4(d,  lsVoxel0.z, lsSceneDepth, 1.0f);	// return statement is required by the compiler					
	}

	ENDCG
	}
}FallBack Off
}



			