//
//  CloudShadowMap.metal
//  Glasslands
//
//  Created by . . on 10/7/25.
//
//  Cloud-shadow map used both by the sun gobo and the ground shader modifier.
//  Combines billboard clusters (fast Gaussian blobs) with the procedural vapour
//  as a gentle fill so all clouds cast local shade.
//

#include <metal_stdlib>
using namespace metal;
#include <simd/simd.h>

// Must match VolCloudUniformsStore.swift
struct GLCloudUniforms {
    float4 sunDirWorld;
    float4 sunTint;
    float4 params0; // x=time, y=wind.x, z=wind.y, w=baseY
    float4 params1; // x=topY, y=coverage, z=densityMul, w=stepMul
    float4 params2; // x=mieG, y=powderK, z=horizonLift, w=detailMul
    float4 params3; // x=domainOffX, y=domainOffY, z=domainRotate, w=puffScale
    float4 params4; // x=puffStrength, y=quality, z=macroScale, w=macroThreshold
};

struct CSUniforms {
    float2  mapOriginXZ;   // world XZ min (bottom-left of the map)
    float2  mapSizeXZ;     // world XZ span covered by the texture
    float   groundY;       // approx ground plane; small errors are fine
    float   padding0;
};

// ---------------- noise & helpers (fast) ----------------
inline float h1(float n){ return fract(sin(n) * 43758.5453123f); }
inline float h12(float2 p){ return fract(sin(dot(p, float2(127.1,311.7))) * 43758.5453123f); }

inline float noise3(float3 x) {
    float3 p = floor(x), f = x - p;
    f = f * f * (3.0 - 2.0 * f);
    const float3 off = float3(1.0, 57.0, 113.0);
    float n = dot(p, off);
    float n000 = h1(n + 0.0),   n100 = h1(n + 1.0);
    float n010 = h1(n + 57.0),  n110 = h1(n + 58.0);
    float n001 = h1(n + 113.0), n101 = h1(n + 114.0);
    float n011 = h1(n + 170.0), n111 = h1(n + 171.0);
    float nx00 = mix(n000, n100, f.x), nx10 = mix(n010, n110, f.x);
    float nx01 = mix(n001, n101, f.x), nx11 = mix(n011, n111, f.x);
    float nxy0 = mix(nx00, nx10, f.y), nxy1 = mix(nx01, nx11, f.y);
    return mix(nxy0, nxy1, f.z);
}

inline float fbm2(float3 p){
    float a = 0.0, w = 0.5;
    a += noise3(p) * w;       p = p * 2.02 + 19.19; w *= 0.5;
    a += noise3(p) * w;
    return a;
}

inline float worley2(float2 x){
    float2 i = floor(x), f = x - i;
    float d = 1e9;
    for (int y=-1; y<=1; ++y) for (int xk=-1; xk<=1; ++xk){
        float2 g = float2(xk,y);
        float2 o = float2(h12(i+g), h12(i+g+19.7));
        float2 r = g + o - f;
        d = min(d, dot(r,r));
    }
    return sqrt(max(d,0.0));
}

inline float puffFBM2(float2 x){
    float a = 0.0, w = 0.6, s = 1.0;
    float v = 1.0 - clamp(worley2(x*s), 0.0, 1.0); a += v*w;
    s *= 2.03; w *= 0.55;
    v = 1.0 - clamp(worley2(x*s), 0.0, 1.0); a += v*w;
    return clamp(a, 0.0, 1.0);
}

inline float hProfile(float y, float b, float t){
    float h = clamp((y-b)/max(1.0,(t-b)), 0.0, 1.0);
    float up = smoothstep(0.03, 0.25, h);
    float dn = 1.0 - smoothstep(0.68, 1.00, h);
    return pow(clamp(up*dn, 0.0, 1.0), 0.80);
}

// Same density as vapour, kept here to match look.
inline float densityAt(float3 wp, constant GLCloudUniforms& U){
    float time     = U.params0.x;
    float2 wind    = float2(U.params0.y, U.params0.z);
    float baseY    = U.params0.w;
    float topY     = U.params1.x;
    float coverage = clamp(U.params1.y, 0.05, 0.98);
    float detailMul= U.params2.w;
    float horizon  = U.params2.z;

    float2 domOff  = float2(U.params3.x, U.params3.y);
    float domRot   = U.params3.z;
    float puffScale= max(1e-4, U.params3.w);

    float puffK    = clamp(U.params4.x, 0.0, 1.5);
    float macroS   = max(1e-6, U.params4.z);
    float macroT   = clamp(U.params4.w, 0.0, 1.0);

    float h01 = hProfile(wp.y, baseY, topY);

    float ca = cos(domRot), sa = sin(domRot);
    float2 xz = wp.xz + domOff;
    float2 xzr = float2(xz.x*ca - xz.y*sa, xz.x*sa + xz.y*ca);

    float adv = mix(0.55, 1.55, h01);
    float2 advXY = xzr + wind * adv * (time * 0.0035);

    float macro = 1.0 - clamp(worley2(advXY * macroS), 0.0, 1.0);
    float macroMask = smoothstep(macroT - 0.10, macroT + 0.10, macro);

    float3 P0 = float3(advXY.x, wp.y, advXY.y) * 0.00110;
    float  base = fbm2(P0 * float3(1.0, 0.35, 1.0));

    float yy = wp.y * 0.002 + 5.37;
    float puffs = puffFBM2(advXY * puffScale + float2(yy, -yy*0.7));

    float3 P1 = float3(advXY.x, wp.y*1.6, advXY.y) * 0.0040 + float3(2.7,0.0,-5.1);
    float  erode = fbm2(P1);

    float shape = base + puffK*(puffs - 0.5) - (1.0 - erode) * (0.30 * detailMul);

    float coverInv = 1.0 - coverage;
    float thLo = clamp(coverInv - 0.20, 0.0, 1.0);
    float thHi = clamp(coverInv + 0.28, 0.0, 1.2);
    float t = smoothstep(thLo, thHi, shape);

    float dens = pow(clamp(t, 0.0, 1.0), 0.85);
    dens *= macroMask;
    dens *= hProfile(wp.y + horizon*120.0, baseY, topY);
    return dens;
}

// Compute kernel: builds a transmissive shadow map (R8) from sun → ground.
kernel void cloud_shadowmap(
    texture2d<float, access::write>   outTex      [[texture(0)]],
    constant GLCloudUniforms&         U           [[buffer(0)]],
    constant CSUniforms&              C           [[buffer(1)]],
    uint2                              gid        [[thread_position_in_grid]],
    uint2                              gsize      [[threads_per_grid]]
) {
    if (gid.x >= gsize.x || gid.y >= gsize.y) return;

    float2 uv = (float2(gid) + 0.5) / float2(gsize);

    float2 worldXZ = C.mapOriginXZ + uv * C.mapSizeXZ;

    float baseY = U.params0.w;
    float topY  = U.params1.x;

    // Ray: start near top, go along -sunDir
    float3 S = normalize(U.sunDirWorld.xyz);
    float3 rayDir = -S;

    float3 p = float3(worldXZ.x, topY, worldXZ.y);

    float quality = clamp(U.params4.y, 0.40, 1.20);
    float stepMul = clamp(U.params1.w, 0.60, 1.40);

    // Path length scales with sun altitude
    float Lmax = (topY - baseY) / max(0.2, abs(S.y));
    int   N    = clamp(int(round(mix(18.0, 36.0, quality) * stepMul)), 12, 48);
    float dt   = Lmax / float(N);

    half T = half(1.0);
    const half rhoGate = half(0.0030);

    // Per-pixel jitter to hide stepping
    float j = fract(sin(dot(uv, float2(12.9898,78.233))) * 43758.5453);
    float t = (0.25 + 0.5*j) * dt;

    for (int i=0; i < N && T > half(0.004); ++i) {
        float3 sp = p + rayDir * t;

        if (sp.y <= C.groundY) break; // hit ground earlier than expected

        half rho = half(densityAt(sp, U));
        if (rho < rhoGate) { t += dt * 1.55; continue; }

        half sigma = half(max(0.0f, U.params1.z) * 0.030);
        half aStep = half(1.0) - half(exp(-float(rho) * float(sigma) * dt));
        T *= (half(1.0) - aStep);
        t += dt;
    }

    // Write as premultiplied WHITE α (transmittance → shade)
    float shade = clamp(1.0 - float(T), 0.0, 1.0);
    outTex.write(float4(shade, shade, shade, 1.0), gid);
}
