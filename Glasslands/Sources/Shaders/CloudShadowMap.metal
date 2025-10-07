//
//  CloudShadowMap.metal
//  Glasslands
//
//  Created by . . on 10/7/25.
//
//  Computes a top-down cloud shadow map for directional gobo projection.
//

#include <metal_stdlib>
using namespace metal;

static constant float kPI = 3.14159265358979323846f;
inline float clamp01(float x){ return clamp(x, 0.0f, 1.0f); }
inline float lerp1(float a,float b,float t){ return a + (b - a) * t; }
inline float frac(float x){ return x - floor(x); }

// ---- Noise identical to volumetric shader ----
inline float hash1(float n){ return frac(sin(n) * 43758.5453123f); }
inline float noise3(float3 x){
    float3 p = floor(x);
    float3 f = x - p; f = f * f * (3.0f - 2.0f * f);
    const float3 off = float3(1.0, 57.0, 113.0);
    float n = dot(p, off);
    float n000 = hash1(n + 0.0);
    float n100 = hash1(n + 1.0);
    float n010 = hash1(n + 57.0);
    float n110 = hash1(n + 58.0);
    float n001 = hash1(n + 113.0);
    float n101 = hash1(n + 114.0);
    float n011 = hash1(n + 170.0);
    float n111 = hash1(n + 171.0);
    float nx00 = mix(n000, n100, f.x);
    float nx10 = mix(n010, n110, f.x);
    float nx01 = mix(n001, n101, f.x);
    float nx11 = mix(n011, n111, f.x);
    float nxy0 = mix(nx00, nx10, f.y);
    float nxy1 = mix(nx01, nx11, f.y);
    return mix(nxy0, nxy1, f.z);
}
inline float fbm5(float3 p){
    float a = 0.0f, w = 0.5f;
    for (int i = 0; i < 5; ++i) {
        a += noise3(p) * w;
        p = p * 2.02f + 19.19f;
        w *= 0.5f;
    }
    return a;
}
inline float heightProfile(float y, float baseY, float topY){
    float h = clamp01((y - baseY) / max(1.0f, (topY - baseY)));
    float up = smoothstep(0.03f, 0.25f, h);
    float dn = 1.0f - smoothstep(0.68f, 1.00f, h);
    return pow(clamp(up * dn, 0.0f, 1.0f), 0.80f);
}

struct CloudUniforms {
    float4 sunDirWorld;
    float4 sunTint;
    float4 params0;
    float4 params1;
    float4 params2;
    float4 params3;
};

struct ShadowUniforms {
    float2 centerXZ;
    float  halfSize;
    float  pad0;
};

inline float densityAt(float3 wp, constant CloudUniforms& uClouds){
    const float  time      = uClouds.params0.x;
    const float2 wind      = float2(uClouds.params0.y, uClouds.params0.z);
    const float  baseY     = uClouds.params0.w;
    const float  topY      = uClouds.params1.x;
    const float  coverage  = uClouds.params1.y;
    const float  detailMul = max(0.0f, uClouds.params2.w);

    const float2 domOff = float2(uClouds.params3.x, uClouds.params3.y);
    const float  ang    = uClouds.params3.z;
    const float  ca = cos(ang), sa = sin(ang);

    float2 xz   = wp.xz + domOff;
    float2 xzr  = float2(xz.x*ca - xz.y*sa, xz.x*sa + xz.y*ca);

    float h01 = heightProfile(wp.y, baseY, topY);
    float adv = lerp1(0.5f, 1.5f, h01);
    float2 advXY = xzr + wind * adv * (time * 0.0035f);

    float3 P0 = float3(advXY.x, wp.y, advXY.y) * 0.00115f;
    float base = fbm5(P0 * float3(1.0, 0.35, 1.0));

    float3 P1 = float3(advXY.x, wp.y * 1.8f, advXY.y) * 0.0046f + float3(2.7f, 0.0f, -5.1f);
    float detail = fbm5(P1);

    float edge  = base + (detailMul * 0.55f) * (detail - 0.45f);
    float dens = clamp( (edge - (1.0f - coverage)) / max(1e-3f, coverage), 0.0f, 1.0f );
    dens *= heightProfile(wp.y + uClouds.params2.z * 120.0f, baseY, topY);
    return clamp(dens, 0.0f, 1.0f);
}

kernel void cloudShadowKernel(
    texture2d<float, access::write> outShadow [[texture(0)]],
    constant CloudUniforms& uClouds          [[buffer(0)]],
    constant ShadowUniforms& SU               [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= outShadow.get_width() || gid.y >= outShadow.get_height()) { return; }

    const float W = float(outShadow.get_width());
    const float H = float(outShadow.get_height());

    float u = (float(gid.x) + 0.5f) / W;
    float v = (float(gid.y) + 0.5f) / H;
    float x = SU.centerXZ.x + (u * 2.0f - 1.0f) * SU.halfSize;
    float z = SU.centerXZ.y + (v * 2.0f - 1.0f) * SU.halfSize;

    float3 sunW = normalize(uClouds.sunDirWorld.xyz);

    const float baseY = uClouds.params0.w;
    const float topY  = uClouds.params1.x;
    const float densMul = max(0.0f, uClouds.params1.z);

    const int   NL = 32;
    const float totalH = max(1.0f, (topY - baseY)) / max(1, NL);
    const float stepL  = totalH * (abs(sunW.y) > 1e-4f ? (1.0f / abs(sunW.y)) : 1.0f);

    float3 p = float3(x, topY, z);
    float3 d = -sunW * stepL;

    float tau = 0.0f;
    for (int i = 0; i < NL && tau < 8.0f; ++i) {
        float rho = densityAt(p, uClouds);
        tau += rho * densMul * (stepL * 0.020f);
        p += d;
    }

    float T = exp(-tau);
    float shadow = pow(T, 0.88f);

    outShadow.write(float4(shadow, shadow, shadow, 1.0), gid);
}
