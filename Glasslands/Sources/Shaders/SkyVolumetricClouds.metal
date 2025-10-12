//
//  SkyVolumetricClouds.metal
//  Glasslands
//
//  Created by . . on 10/5/25.
//
//  True volumetric vapour with zenith-aware quality and coarse empty-space skipping.
//  RGB is premultiplied pure white; alpha carries sun-only shading.
//

#include <metal_stdlib>
using namespace metal;
#include <SceneKit/scn_metal>

static constant float kPI = 3.14159265358979323846f;

struct GLCloudUniforms {
    float4 sunDirWorld;
    float4 sunTint;
    float4 params0; // x=time, y=wind.x, z=wind.y, w=baseY
    float4 params1; // x=topY, y=coverage, z=densityMul, w=stepMul
    float4 params2; // x=mieG, y=powderK, z=horizonLift, w=detailMul
    float4 params3; // x=domainOffX, y=domainOffY, z=domainRotate, w=puffScale
    float4 params4; // x=puffStrength, y=quality(legacy), z=macroScale, w=macroThreshold
};

struct GLVSIn {
    float3 position [[ attribute(SCNVertexSemanticPosition) ]];
};

struct GLVSOut {
    float4 position [[position]];
    float3 worldPos;
};

vertex GLVSOut gl_vapour_vertex(GLVSIn vin [[stage_in]],
                                constant SCNSceneBuffer& scn_frame [[buffer(0)]])
{
    GLVSOut o;
    float4 world = float4(vin.position, 1.0);
    float4 view  = scn_frame.viewTransform * world;
    o.position   = scn_frame.projectionTransform * view;
    o.worldPos   = world.xyz;
    return o;
}

// -------- small helpers --------

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
    a += noise3(p) * w;
    p  = p * 2.02 + 19.19;
    w *= 0.5;
    a += noise3(p) * w;
    return a;
}

inline float worley2(float2 x){
    float2 i = floor(x), f = x - i;
    float d = 1e9;
    for (int y=-1; y<=1; ++y)
    for (int xk=-1; xk<=1; ++xk){
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
    float h  = clamp((y-b)/max(1.0,(t-b)), 0.0, 1.0);
    float up = smoothstep(0.03, 0.25, h);
    float dn = 1.0 - smoothstep(0.68, 1.00, h);
    return pow(clamp(up*dn, 0.0, 1.0), 0.80);
}

inline float phaseHG(float mu, float g){
    float g2 = g*g;
    return (1.0 - g2) / max(1e-4, 4.0*kPI*pow(1.0 + g2 - 2.0*g*mu, 1.5));
}

// -------- coarse macro gate (cheap empty-space skip) --------
// Uses a single low-frequency value-noise layer to reject obvious empty space
// before running the expensive FBM/Worley evaluator. Tuned to match macro islands.
inline float coarseMacroMask(float2 advXY,
                             constant GLCloudUniforms& U)
{
    // Domain transform
    float macroScale = max(1e-6, U.params4.z);
    float2 domOff    = float2(U.params3.x, U.params3.y);
    float  domRot    = U.params3.z;
    float  time      = U.params0.x;
    float2 wind      = float2(U.params0.y, U.params0.z);

    float ca = cos(domRot), sa = sin(domRot);
    float2 xz = advXY + domOff;
    float2 xzr = float2(xz.x*ca - xz.y*sa, xz.x*sa + xz.y*ca);

    // Slow advection; very cheap
    float2 adv = xzr + wind * (time * 0.0018);

    // One octave value noise is enough for a conservative gate
    float n = noise3(float3(adv * macroScale * 0.6, 3.1));
    float thr = clamp(U.params4.w, 0.0, 1.0);

    // Wider transitions reduce popping when skipping steps
    return smoothstep(thr - 0.18, thr + 0.18, n);
}

// -------- full density (keeps your shape/look) --------
inline float densityAt(float3 wp, constant GLCloudUniforms& U)
{
    float time       = U.params0.x;
    float2 wind      = float2(U.params0.y, U.params0.z);
    float baseY      = U.params0.w;
    float topY       = U.params1.x;
    float coverage   = clamp(U.params1.y, 0.05, 0.98);
    float detailMul  = U.params2.w;
    float horizonLift= U.params2.z;
    float2 domOff    = float2(U.params3.x, U.params3.y);
    float  domRot    = U.params3.z;
    float  puffScale = max(1e-4, U.params3.w);
    float  puffStrength = clamp(U.params4.x, 0.0, 1.5);
    float  macroScale   = max(1e-6, U.params4.z);
    float  macroThresh  = clamp(U.params4.w, 0.0, 1.0);

    float h01 = hProfile(wp.y, baseY, topY);

    float ca = cos(domRot), sa = sin(domRot);
    float2 xz = wp.xz + domOff;
    float2 xzr = float2(xz.x*ca - xz.y*sa, xz.x*sa + xz.y*ca);
    float  adv = mix(0.55, 1.55, h01);
    float2 advXY = xzr + wind * adv * (time * 0.0035);

    // Macro islands
    float macro = 1.0 - clamp(worley2(advXY * macroScale), 0.0, 1.0);
    float macroMask = smoothstep(macroThresh - 0.10, macroThresh + 0.10, macro);

    // Base + micro puffs + erosion
    float3 P0 = float3(advXY.x, wp.y, advXY.y) * 0.00110;
    float base = fbm2(P0 * float3(1.0, 0.35, 1.0));

    float yy = wp.y * 0.002 + 5.37;
    float puffs = puffFBM2(advXY * puffScale + float2(yy, -yy*0.7));

    float3 P1 = float3(advXY.x, wp.y*1.6, advXY.y) * 0.0040 + float3(2.7,0.0,-5.1);
    float erode = fbm2(P1);

    float shape = base + puffStrength*(puffs - 0.5) - (1.0 - erode) * (0.30 * detailMul);

    float coverInv = 1.0 - coverage;
    float thLo = clamp(coverInv - 0.20, 0.0, 1.0);
    float thHi = clamp(coverInv + 0.28, 0.0, 1.2);
    float t = smoothstep(thLo, thHi, shape);

    float dens = pow(clamp(t, 0.0, 1.0), 0.85);
    dens *= macroMask;
    dens *= hProfile(wp.y + horizonLift*120.0, baseY, topY);
    return dens;
}

// -------- fragment (sun-only, premultiplied white) --------

fragment half4 gl_vapour_fragment(GLVSOut in                [[stage_in]],
                                  constant SCNSceneBuffer& scn_frame [[buffer(0)]],
                                  constant GLCloudUniforms& U        [[buffer(1)]])
{
    // Camera & ray
    float4 camW4 = scn_frame.inverseViewTransform * float4(0,0,0,1);
    float3 camPos = camW4.xyz / camW4.w;
    float3 V = normalize(in.worldPos - camPos);

    float baseY = U.params0.w;
    float topY  = U.params1.x;

    float vdY = V.y;
    float t0  = (baseY - camPos.y) / max(1e-5, vdY);
    float t1  = (topY  - camPos.y) / max(1e-5, vdY);
    float tEnt = max(0.0, min(t0, t1));
    float tExt = min(tEnt + 5000.0, max(t0, t1));
    if (tExt <= tEnt + 1e-5) discard_fragment();

    float Lm = tExt - tEnt;

    // Distance LOD + external stepMul
    float distLOD = clamp(Lm / 4000.0, 0.0, 1.4);
    float stepMul = clamp(U.params1.w, 0.60, 1.40);
    int   Nbase   = int(round(mix(10.0, 18.0, 1.0 - distLOD*0.6)));

    // ---- Zenith-aware ramp (key to kill freezes when looking up) ----
    // vUp=0 at vdY<=0.25 (near horizon / down), vUp->1 as we look straight up.
    float vUp = clamp((abs(vdY) - 0.25) / 0.65, 0.0, 1.0);
    float qualMul   = mix(1.0, 0.34, vUp);    // shrink step count up to ~66%
    bool  doSunVis  = (vUp < 0.60);           // skip sun-occlusion march near zenith
    int   refineMax = (vUp < 0.30 ? 1 : 0);   // drop refine samples near zenith

    int   N  = clamp(int(round(float(Nbase) * stepMul * qualMul)), 6, 18);
    float dt = Lm / float(N);

    // Per-pixel jitter
    float2 st = float2(in.position.x, in.position.y);
    float  j  = fract(sin(dot(st, float2(12.9898, 78.233))) * 43758.5453);
    float  t  = tEnt + (0.25 + 0.5*j) * dt;

    half3 S   = half3(normalize(U.sunDirWorld.xyz));
    half mu   = half(clamp(dot(V, float3(S)), -1.0, 1.0));
    half g    = half(clamp(U.params2.x, 0.0, 0.95));
    half T    = half(1.0);

    // Tuned gates for speed (slightly looser near zenith)
    half rhoGate  = half(mix(0.0032, 0.0060, vUp));
    half skipMul  = half(mix(1.55, 1.90, vUp));
    half refineMul= half(0.40);

    // Precompute a cheap coarse macro mask at the entry,
    // then reuse it while marching to short-circuit obvious empty spans.
    // We evaluate on the slab’s xz; it’s conservative and stable.
    float2 advXY0 = (camPos + V * tEnt).xz;
    float coarse0 = coarseMacroMask(advXY0, U);

    for (int i=0; i < N && T > half(0.004); ++i)
    {
        float3 sp = camPos + V * t;

        // Cheap coarse rejection first (fast path)
        float coarse = coarse0;
        // Slightly decorrelate along the ray without extra noise calls
        coarse = mix(coarse, coarseMacroMask(sp.xz, U), 0.35);
        if (coarse < 0.10) {
            t += dt * float(skipMul);
            continue;
        }

        // Full density at sample
        half rho = half(densityAt(sp, U));
        if (rho < rhoGate) {
            t += dt * float(skipMul);
            continue;
        }

        // Optional one-tap sun visibility (skipped near zenith to save a density call)
        if (doSunVis) {
            float dL = (topY - baseY) * 0.22;
            float3 lp = sp + float3(S) * dL;
            half occ = half(densityAt(lp, U));
            half aL  = half(1.0) - half(exp(-float(occ) * max(0.0f, U.params1.z) * dL * 0.010));
            rho = half(min(1.0f, float(rho) * (1.0f - 0.6f * float(aL))));
        }

        // Optional micro-refine (disabled near zenith)
        half td = half(dt) * refineMul;
        for (int k=0; k < refineMax && T > half(0.004); ++k){
            float3 sp2 = sp + V * (float(td) * float(k));
            half rho2  = half(densityAt(sp2, U));

            half sigma = half(max(0.0f, U.params1.z) * 0.028);
            half aStep = half(1.0) - half(exp(-float(rho2) * float(sigma) * float(td)));
            half ph    = half(phaseHG(float(mu), float(g)));
            half gain  = half(clamp(1.85 * float(ph), 0.0, 2.0));

            T *= (half(1.0) - aStep * gain);
            if (T <= half(0.004)) break;
        }

        t += dt;
    }

    half alpha = half(clamp(1.0 - float(T), 0.0, 1.0));
    half3 rgb  = half3(1.0) * alpha; // premultiplied WHITE
    return half4(rgb, alpha);
}
