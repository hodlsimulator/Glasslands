//
//  SkyVolumetricClouds.metal
//  Glasslands
//
//  Created by . . on 10/5/25.
//
//  Volumetric cloud raymarch (single scattering) lit by the sun.
//  – HG phase + powder effect + compact light march for self-occlusion.
//

#include <metal_stdlib>
using namespace metal;
#include <SceneKit/scn_metal>

static constant float kPI = 3.14159265358979323846f;
inline float clamp01(float x) { return clamp(x, 0.0f, 1.0f); }
inline float2 clamp01(float2 v){ return clamp(v, float2(0), float2(1)); }
inline float3 clamp01(float3 v){ return clamp(v, float3(0), float3(1)); }
inline float lerp1(float a,float b,float t){ return a + (b - a) * t; }
inline float3 lerp3(float3 a,float3 b,float t){ return a + (b - a) * t; }
inline float frac(float x){ return x - floor(x); }

// --- Noise ---
inline float hash1(float n) { return frac(sin(n) * 43758.5453123f); }
inline float noise3(float3 x){
    float3 p = floor(x);
    float3 f = x - p;
    f = f * f * (3.0f - 2.0f * f);

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
inline float2 curl2(float2 xz){
    const float e = 0.02f;
    float n1 = noise3(float3(xz.x + e, 0.0, xz.y)) - noise3(float3(xz.x - e, 0.0, xz.y));
    float n2 = noise3(float3(xz.x, 0.0, xz.y + e)) - noise3(float3(xz.x, 0.0, xz.y - e));
    float2 v = float2(n2, -n1);
    float len = max(length(v), 1e-5f);
    return v / len;
}

// --- Uniforms ---
struct CloudUniforms {
    float4 sunDirWorld;   // xyz dir
    float4 sunTint;       // rgb
    float4 params0;       // x=time, y=wind.x, z=wind.y, w=baseY
    float4 params1;       // x=topY, y=coverage, z=densityMul, w=stepMul
    float4 params2;       // x=mieG, y=powderK, z=horizonLift, w=detailMul
    float4 params3;       // x=domainOffX, y=domainOffY, z=domainRotate, w=0
};

struct VSIn {
    float3 position [[attribute(SCNVertexSemanticPosition)]];
};

struct VSOut {
    float4 position [[position]];
    float3 worldPos;
};

vertex VSOut clouds_vertex(
    VSIn vin [[stage_in]],
    constant SCNSceneBuffer& scn_frame [[buffer(0)]])
{
    VSOut o;
    const float4 world = float4(vin.position, 1.0);
    const float4 view  = scn_frame.viewTransform * world;
    o.position = scn_frame.projectionTransform * view;
    o.worldPos = world.xyz;
    return o;
}

inline float heightProfile(float y, float baseY, float topY){
    float h = clamp01((y - baseY) / max(1.0f, (topY - baseY)));
    float up = smoothstep(0.03f, 0.25f, h);
    float dn = 1.0f - smoothstep(0.68f, 1.00f, h);
    return pow(clamp(up * dn, 0.0f, 1.0f), 0.80f);
}

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

    float2 curl = curl2(advXY * 0.0022f);
    float edge  = base + (detailMul * 0.55f) * (detail - 0.45f) + 0.10f * curl.x;

    float dens = clamp( (edge - (1.0f - coverage)) / max(1e-3f, coverage), 0.0f, 1.0f );
    dens *= heightProfile(wp.y + uClouds.params2.z * 120.0f, baseY, topY);

    return clamp(dens, 0.0f, 1.0f);
}

inline float phaseHG(float cosTheta, float g){
    float g2 = g * g;
    float denom = pow(1.0f + g2 - 2.0f * g * cosTheta, 1.5f);
    return (1.0f - g2) / max(1e-4f, 4.0f * kPI * denom);
}

inline float powderTerm(float occult, float k) {
    return exp(-k * clamp01(occult));
}

struct FragOut { half4 color; };

fragment FragOut clouds_fragment(
    VSOut in                              [[stage_in]],
    constant SCNSceneBuffer& scn_frame    [[buffer(0)]],
    constant CloudUniforms& uClouds       [[buffer(1)]])
{
    FragOut out;
    const float3 skyZenith  = float3(0.10, 0.28, 0.65);
    const float3 skyHorizon = float3(0.55, 0.72, 0.94);

    float4 camW4 = scn_frame.inverseViewTransform * float4(0,0,0,1);
    float3 camPos = camW4.xyz / camW4.w;

    float3 pos   = in.worldPos;
    float3 viewDir = normalize(pos - camPos);

    const float baseY    = uClouds.params0.w;
    const float topY     = uClouds.params1.x;
    const float densMul  = max(0.0f, uClouds.params1.z);
    const float stepMul  = clamp(uClouds.params1.w, 0.25f, 1.5f);

    float tEnter = 0.0f, tExit = 0.0f;
    {
        float vdY = viewDir.y;
        float t0 = (baseY - camPos.y) / max(1e-5f, vdY);
        float t1 = (topY  - camPos.y) / max(1e-5f, vdY);
        tEnter = min(t0, t1);
        tExit  = max(t0, t1);
        tEnter = max(tEnter, 0.0f);
        tExit = min(tExit, tEnter + 6000.0f);
    }

    float3 sunW = normalize(uClouds.sunDirWorld.xyz);
    float sunDotV = clamp(dot(viewDir, sunW), -1.0f, 1.0f);
    float gHG     = clamp(uClouds.params2.x, -0.99f, 0.99f);
    float powderK = max(0.0f, uClouds.params2.y);

    float up = clamp01((viewDir.y * 0.5f) + 0.5f);
    float3 skyCol = mix(skyHorizon, skyZenith, up);

    float  T = 1.0f;
    float3 C = float3(0);

    const float marchLen = max(1e-3f, tExit - tEnter);
    const int   Nbase    = 48;
    const int   Nsteps   = clamp(int(round((float)Nbase * stepMul)), 16, 84);
    const float dt       = marchLen / (float)Nsteps;

    float t = tEnter + 0.5f * dt;
    for (int i = 0; i < Nsteps && T > 0.0035f; ++i, t += dt) {
        float3 sp = camPos + viewDir * t;

        float rho = densityAt(sp, uClouds);
        if (rho <= 1e-4f) continue;

        float lightT = 1.0f;
        {
            const int NL = 6;
            const float dL = ((topY - baseY) / max(1, NL)) * 0.9f;
            float3 lp = sp;
            for (int j = 0; j < NL && lightT > 0.01f; ++j) {
                lp += sunW * dL;
                float occ = densityAt(lp, uClouds);
                float aL  = 1.0f - exp(-occ * densMul * dL * 0.012f);
                lightT *= (1.0f - aL);
            }
        }

        float sigma = densMul * 0.022f;
        float a = 1.0f - exp(-rho * sigma * dt);
        float ph = phaseHG(sunDotV, gHG);
        float pd = powderTerm(1.0f - rho, powderK);
        float3 sunRGB = uClouds.sunTint.rgb;

        float3 S = sunRGB * lightT * ph * pd;
        C += T * a * S;
        T *= (1.0f - a);
    }

    float3 col = C + skyCol * T;
    out.color = half4(half3(clamp01(col)), half(1.0));
    return out;
}
