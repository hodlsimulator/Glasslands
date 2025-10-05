//
//  SkyVolumetricClouds.metal
//  Glasslands
//
//  Created by . . on 10/5/25.
//
//  Volumetric cumulus via fast ray-march (single scattering, powder effect).
//  Works as a SceneKit SCNProgram (Metal). No SceneKit shader-modifier macros.
//

#include <metal_stdlib>
using namespace metal;            // must precede scn_metal
#include <SceneKit/scn_metal>

struct CloudUniforms {
    float4 sunDirWorld;
    float4 sunTint;
    float  time;
    float2 wind;
    float  baseY;
    float  topY;
    float  coverage;
    float  densityMul;
    float  stepMul;
    float  horizonLift;
    float  _pad;
};

struct VSIn {
    float3 position [[attribute(SCNVertexSemanticPosition)]];
};

struct VSOut {
    float4 position [[position]];
    float3 worldPos;
};

// buffer(0) = SCNSceneBuffer (SceneKit)
// buffer(2) = CloudUniforms   (bound from Swift as "uniforms")
vertex VSOut clouds_vertex(VSIn vin [[stage_in]],
                           constant SCNSceneBuffer& scn_frame [[buffer(0)]])
{
    VSOut o;
    // Identity model transform by design: keep the cloud sphere at world origin.
    float4 world = float4(vin.position, 1.0);
    float4 view  = scn_frame.viewTransform * world;
    o.position   = scn_frame.projectionTransform * view;
    o.worldPos   = world.xyz;
    return o;
}

// ---------- helpers ----------
inline float  saturate1(float x)            { return clamp(x, 0.0f, 1.0f); }
inline float3 saturate3(float3 v)           { return clamp(v, float3(0.0), float3(1.0)); }
inline float  frac1(float x)                { return x - floor(x); }
inline float  lerp1(float a,float b,float t){ return a + (b - a) * t; }
inline float  hash1(float n)                { return frac1(sin(n) * 43758.5453123f); }

inline float noise3(float3 x) {
    float3 p = floor(x);
    float3 f = x - p;
    f = f*f*(3.0f - 2.0f*f);

    float n = dot(p, float3(1.0, 57.0, 113.0));
    float n000 = hash1(n +   0.0);
    float n100 = hash1(n +   1.0);
    float n010 = hash1(n +  57.0);
    float n110 = hash1(n +  58.0);
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

inline float fbm(float3 p) {
    float a = 0.0f;
    float w = 0.5f;
    // fewer octaves for speed
    for (int i = 0; i < 4; i++) {
        a += noise3(p) * w;
        p = p * 2.01f + 19.0f;
        w *= 0.5f;
    }
    return a;
}

inline float2 curl2(float2 xz) {
    const float e = 0.02f; // slightly larger epsilon → fewer ALU ops overall
    float n1 = noise3(float3(xz.x + e, 0.0, xz.y)) - noise3(float3(xz.x - e, 0.0, xz.y));
    float n2 = noise3(float3(xz.x, 0.0, xz.y + e)) - noise3(float3(xz.x, 0.0, xz.y - e));
    float2 v = float2(n2, -n1);
    float len = max(length(v), 1e-5f);
    return v / len;
}

inline float heightProfile(float y, float baseY, float topY) {
    float h  = saturate1((y - baseY) / max(1.0f, (topY - baseY)));
    float up = smoothstep(0.02f, 0.25f, h);
    float dn = 1.0f - smoothstep(0.68f, 1.00f, h);
    return pow(up * dn, 0.78f);
}

inline float densityAt(float3 wp, constant CloudUniforms& U) {
    float3 q = wp * 0.0011f;

    float2 flow = U.wind * 0.0012f + 1.1f * curl2(q.xz + U.time * 0.07f);
    q.xz += flow * U.time;

    float3 warp = float3(fbm(q*1.6f + 31.0f), fbm(q*1.7f + 57.0f), fbm(q*1.8f + 83.0f));
    q += (warp - 0.5f) * 0.44f;

    float shape  = fbm(q * 0.8f);
    float detail = fbm(q * 2.4f) * 0.50f;
    float prof   = heightProfile(wp.y, U.baseY, U.topY);

    float thr = lerp1(0.65f, 0.45f, saturate1(U.coverage));
    float d = (shape * 0.95f + detail * 0.65f) * prof - thr + 0.08f;
    return smoothstep(0.0f, 0.70f, d);
}

fragment float4 clouds_fragment(VSOut                         in        [[stage_in]],
                                constant SCNSceneBuffer&     scn_frame [[buffer(0)]],
                                constant CloudUniforms&      U         [[buffer(2)]])
{
    // Ray setup
    float3 ro = (scn_frame.inverseViewTransform * float4(0,0,0,1)).xyz;
    float3 rd = normalize(in.worldPos - ro);

    // Always compute a base sky gradient so there's never a black sky.
    // Same palette as the Swift background gradient.
    float tSky = saturate1(rd.y * 0.6f + 0.4f);
    float3 zenith  = float3(0.30f, 0.56f, 0.96f);
    float3 horizon = float3(0.88f, 0.93f, 0.99f);
    float3 baseCol = mix(horizon, zenith, tSky);

    // Intersect slab [baseY, topY]
    float denom = rd.y;
    if (fabs(denom) < 1e-4f) {
        // No intersection; just sky.
        return float4(baseCol, 1.0);
    }

    float tb = (U.baseY - ro.y) / denom;
    float tt = (U.topY  - ro.y) / denom;
    float t0 = min(tb, tt);
    float t1 = max(tb, tt);
    if (t1 <= 0.0f) {
        return float4(baseCol, 1.0);
    }
    t0 = max(t0, 0.0f);

    // Faster march: fewer steps, bigger stride, stronger grazing boost.
    const int   MAX_STEPS = 20;
    float baseStep   = 220.0f * U.stepMul;
    float grazing    = clamp(1.0f - fabs(rd.y), 0.0f, 1.0f);
    float worldStep  = baseStep * lerp1(1.0f, 2.2f, grazing);

    float3 sunW = normalize(U.sunDirWorld.xyz);
    float3 acc  = float3(0.0);
    float  trans = 1.0f;

    float horizonBoost = U.horizonLift * smoothstep(0.0f, 0.15f, grazing);
    float jitter = frac1(dot(in.worldPos, float3(1.0, 57.0, 113.0))) * worldStep;

    float t = t0 + jitter;
    for (int i = 0; i < MAX_STEPS; ++i) {
        float3 p = ro + rd * t;
        if (t > t1) break;

        float d = densityAt(p, U) * U.densityMul;
        if (d > 1e-3f) {
            float3 ps = p + sunW * 300.0f;
            float dl  = densityAt(ps, U);
            float shade = 0.55f + 0.45f * smoothstep(0.15f, 0.95f, 1.0f - dl);

            float powder = 1.0f - exp(-2.2f * d);

            float3 localCol = float3(1.0) * (0.70f + 0.30f * shade + horizonBoost);
            localCol = saturate3(localCol);

            float a = saturate1(d * (worldStep / 220.0f));
            float3 add = localCol * (powder * a);

            acc += trans * add;
            trans *= (1.0f - a);
            if (trans < 0.03f) break; // earlier exit to kill hitch
        }

        t += worldStep;
    }

    // Composite clouds over our sky gradient using remaining transmittance.
    float3 outRGB = baseCol * trans + acc + U.sunTint.xyz * acc * 0.08f;
    return float4(outRGB, 1.0);
}
