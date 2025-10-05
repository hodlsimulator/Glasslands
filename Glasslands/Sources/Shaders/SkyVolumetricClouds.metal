//
//  SkyVolumetricClouds.metal
//  Glasslands
//
//  Created by . . on 10/5/25.
//
//  Volumetric cumulus via fast ray‑march (single scattering + light‑march
//  self‑shadowing, HG phase, powder effect, horizon lift). Drawn on an inside‑out
//  sphere using SceneKit’s SCNProgram pipeline.
//

#include <metal_stdlib>
using namespace metal;
#include <simd/simd.h>
#include <SceneKit/scn_metal>

// -----------------------------------------------------------------------------
// Constants / small helpers
// -----------------------------------------------------------------------------

static constant float kPI = 3.14159265358979323846f;

inline float deg2rad(float degrees) {
    return degrees * (kPI / 180.0f);
}

// ------------------------------- POD uniforms -------------------------------

struct CloudUniforms {
    float4 sunDirWorld;             // xyz = world-space sun dir (normalised)
    float4 sunTint;                 // xyz = sunlight tint (sRGB space-ish)

    // Packed for 16-byte alignment:
    float4 params0;                 // x=time, y=wind.x, z=wind.y, w=baseY
    float4 params1;                 // x=topY, y=coverage, z=densityMul, w=stepMul
    float4 params2;                 // x=mieG, y=powderK, z=horizonLift, w=detailMul
};

// ------------------------------ VS I/O structs ------------------------------

struct VSIn {
    float3 position [[attribute(SCNVertexSemanticPosition)]];
};

struct VSOut {
    float4 position [[position]];
    float3 worldPos;
};

// --------------------------------- Vertex -----------------------------------

vertex VSOut clouds_vertex(
    VSIn vin [[stage_in]],
    constant SCNSceneBuffer& scn_frame [[buffer(0)]]
){
    VSOut o;
    const float4 world = float4(vin.position, 1.0);
    const float4 view  = scn_frame.viewTransform * world;
    o.position = scn_frame.projectionTransform * view;
    o.worldPos = world.xyz;
    return o;
}

// --------------------------------- Helpers ----------------------------------

inline float  saturate1(float x)           { return clamp(x, 0.0f, 1.0f); }
inline float3 saturate3(float3 v)          { return clamp(v, float3(0.0), float3(1.0)); }
inline float  frac1(float x)               { return x - floor(x); }
inline float  lerp1(float a,float b,float t){ return a + (b - a) * t; }
inline float3 lerp3(float3 a,float3 b,float t){ return a + (b - a) * t; }

// Value noise
inline float hash1(float n) {
    return frac1(sin(n) * 43758.5453123f);
}

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

    float nx00 = lerp1(n000, n100, f.x);
    float nx10 = lerp1(n010, n110, f.x);
    float nx01 = lerp1(n001, n101, f.x);
    float nx11 = lerp1(n011, n111, f.x);

    float nxy0 = lerp1(nx00, nx10, f.y);
    float nxy1 = lerp1(nx01, nx11, f.y);

    return lerp1(nxy0, nxy1, f.z);
}

inline float fbm(float3 p){
    float a = 0.0f, w = 0.5f;
    for (int i = 0; i < 5; ++i) {
        a += noise3(p) * w;
        p = p * 2.02f + 19.19f;
        w *= 0.5f;
    }
    return a;
}

// Tiny 2D curl
inline float2 curl2(float2 xz){
    const float e = 0.02f;
    float n1 = noise3(float3(xz.x + e, 0.0, xz.y)) - noise3(float3(xz.x - e, 0.0, xz.y));
    float n2 = noise3(float3(xz.x, 0.0, xz.y + e)) - noise3(float3(xz.x, 0.0, xz.y - e));
    float2 v = float2(n2, -n1);
    float len = max(length(v), 1e-5f);
    return v / len;
}

inline float heightProfile(float y, float baseY, float topY){
    float h = saturate1((y - baseY) / max(1.0f, (topY - baseY)));
    float up = smoothstep(0.03f, 0.25f, h);
    float dn = 1.0f - smoothstep(0.68f, 1.00f, h);
    return pow(up * dn, 0.80f);
}

// Core density field (0…1)
inline float densityAt(float3 wp, constant CloudUniforms& U){
    const float time   = U.params0.x;
    const float2 wind  = float2(U.params0.y, U.params0.z);
    const float baseY  = U.params0.w;
    const float topY   = U.params1.x;
    const float cov    = U.params1.y;
    const float detailMul = max(0.0f, U.params2.w);

    float3 q = wp * 0.00115f;

    float2 flow = wind * 0.0012f + 1.12f * curl2(q.xz + time * 0.07f);
    q.xz += flow * time;

    float3 warp = float3(fbm(q * 1.6f + 31.0f),
                         fbm(q * 1.7f + 57.0f),
                         fbm(q * 1.8f + 83.0f));
    q += (warp - 0.5f) * 0.42f;

    float shape  = fbm(q * 0.85f);
    float detail = fbm(q * 2.75f) * 0.60f * detailMul;

    float prof = heightProfile(wp.y, baseY, topY);

    float thr = lerp1(0.64f, 0.42f, saturate1(cov));
    float d = (shape * 0.95f + detail) * prof - thr + 0.10f;

    return smoothstep(0.0f, 0.70f, d);
}

inline float3 sunGlow(float3 rd, float3 sunW, float3 sunTint){
    float ct = clamp(dot(rd, sunW), -1.0f, 1.0f);
    float ang = acos(ct);
    const float rad = deg2rad(0.95f);
    float core  = 1.0f - smoothstep(rad * 0.75f, rad, ang);
    float halo1 = 1.0f - smoothstep(rad * 1.25f, rad * 3.50f, ang);
    float halo2 = 1.0f - smoothstep(rad * 3.50f, rad * 7.50f, ang);
    float edr  = core * 5.0f + halo1 * 0.90f + halo2 * 0.25f;
    return sunTint * edr;
}

inline float phaseHG(float cosTheta, float g){
    float gg = g * g;
    float denom = 1.0f + gg - 2.0f * g * cosTheta;
    return (1.0f - gg) / (4.0f * kPI * pow(denom, 1.5f));
}

// Short shadow-march along the sun ray
inline float lightTransmittance(float3 p, float3 sunW, constant CloudUniforms& U){
    const int   LSTEPS   = 6;
    const float LSTEP    = 140.0f;
    const float SIGMA    = 0.090f;

    float tau = 0.0f;
    float3 q = p;
    for (int i = 0; i < LSTEPS; ++i){
        q += sunW * LSTEP;
        float d = densityAt(q, U);
        tau += d * SIGMA;
    }
    return exp(-tau);
}

// -------------------------------- Fragment ----------------------------------

fragment float4 clouds_fragment(
    VSOut in [[stage_in]],
    constant SCNSceneBuffer& scn_frame [[buffer(0)]],
    constant CloudUniforms& U [[buffer(2)]]
){
    const float3 ro = (scn_frame.inverseViewTransform * float4(0, 0, 0, 1)).xyz;
    const float3 rd = normalize(in.worldPos - ro);

    const float3 SKY_TOP = float3(0.30, 0.56, 0.96);
    const float3 SKY_BOT = float3(0.88, 0.93, 0.99);
    float tSky = saturate1(rd.y * 0.60f + 0.40f);
    float3 base = lerp3(SKY_BOT, SKY_TOP, tSky);

    const float3 sunW   = normalize(U.sunDirWorld.xyz);
    base += sunGlow(rd, sunW, U.sunTint.xyz);

    const float baseY = U.params0.w;
    const float topY  = U.params1.x;
    float denom = rd.y;
    float tb = 0.0f, tt = -1.0f;
    bool hits = fabs(denom) >= 1e-4f;
    if (hits){
        tb = (baseY - ro.y) / denom;
        tt = (topY  - ro.y) / denom;
    }
    float t0 = hits ? max(min(tb, tt), 0.0f) : 1e9f;
    float t1 = hits ? max(tb, tt)             : -1e9f;

    float3 acc = float3(0.0);
    float trans = 1.0f;

    if (hits && t1 > 0.0f){
        const int   MAX_STEPS = 32;
        const float BASE_STEP = 180.0f;

        float grazing = clamp(1.0f - fabs(rd.y), 0.0f, 1.0f);
        float worldStep = BASE_STEP * lerp1(1.0f, 2.0f, grazing) * U.params1.w;

        float horizonK = U.params2.z * smoothstep(0.0f, 0.15f, grazing);

        float jitter = frac1(dot(in.worldPos, float3(1.0, 57.0, 113.0))) * worldStep;
        float t = t0 + jitter;

        float g     = clamp(U.params2.x, -0.85f, 0.85f);
        float powK  = max(0.0f, U.params2.y);
        float densM = max(0.0f, U.params1.z);

        for (int i = 0; i < MAX_STEPS; ++i){
            if (t > t1) break;

            float3 p = ro + rd * t;
            float d  = densityAt(p, U) * densM;

            if (d > 1e-3f){
                float lt   = lightTransmittance(p, sunW, U);
                float mu   = clamp(dot(rd, sunW), -1.0f, 1.0f);
                float phase = phaseHG(mu, g);

                float powder = 1.0f - exp(-powK * d);

                float3 localCol = (0.70f + 0.30f * lt + horizonK) * phase * U.sunTint.xyz;

                float a = 1.0f - exp(-d * (worldStep * 0.0125f));

                acc   += trans * (localCol * powder * a);
                trans *= (1.0f - a);

                if (trans < 0.03f) break;
            }

            t += worldStep;
        }
    }

    float3 outRGB = base * trans + acc;
    return float4(outRGB, 1.0);
}
