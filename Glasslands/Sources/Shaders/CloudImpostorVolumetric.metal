//
//  CloudImpostorVolumetric.metal
//  Glasslands
//
//  Created by . . on 10/7/25.
//
//  Glasslands — binder-free impostor shader (no uCloudsGL)
//

#include <metal_stdlib>
using namespace metal;
#include <SceneKit/scn_metal>

struct VSIn {
    float3 position [[attribute(SCNVertexSemanticPosition)]];
};

struct VSOut {
    float4 position [[position]];
    float2 ndcXY;
};

vertex VSOut cloud_impostor_vertex(
    VSIn vin [[stage_in]],
    constant SCNSceneBuffer& frame [[buffer(0)]],
    constant float4x4& uModel       [[buffer(1)]]
){
    VSOut o;
    float4 world = uModel * float4(vin.position, 1.0);
    float4 view  = frame.viewTransform * world;
    float4 clip  = frame.projectionTransform * view;
    o.position = clip;
    o.ndcXY    = clip.xy / max(1e-6, clip.w);
    return o;
}

// ---- helpers (small, fast) ----
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
    p = p * 2.02 + 19.19; w *= 0.5;
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
    float v = 1.0 - clamp(worley2(x*s), 0.0, 1.0);
    a += v*w; s *= 2.03; w *= 0.55;
    v = 1.0 - clamp(worley2(x*s), 0.0, 1.0);
    a += v*w;
    return clamp(a, 0.0, 1.0);
}

inline float hProfile(float y, float b, float t){
    float h = clamp((y-b)/max(1.0,(t-b)), 0.0, 1.0);
    float up = smoothstep(0.03, 0.25, h);
    float dn = 1.0 - smoothstep(0.68, 1.00, h);
    return pow(clamp(up*dn, 0.0, 1.0), 0.80);
}

// Binder-free constants (tuned)
constant float kBaseY          = 400.0;
constant float kTopY           = 1400.0;
constant float kCoverage       = 0.44;
constant float kDensityMul     = 1.10;
constant float kStepMul        = 0.80;     // 0.35..1.25
constant float kDetailMul      = 0.90;
constant float kHorizonLift    = 0.10;
constant float kPuffScale      = 0.0046;
constant float kPuffStrength   = 0.68;
constant float kMacroScale     = 0.00040;
constant float kMacroThreshold = 0.58;
constant float2 kDomainOffset  = float2(0.0, 0.0);
constant float  kDomainRotate  = 0.0;

inline float densityAtAnchored(float3 wp, float2 anchorXZ)
{
    float2 xzRel = (wp.xz - anchorXZ) + kDomainOffset;
    float ca = cos(kDomainRotate), sa = sin(kDomainRotate);
    float2 xzr = float2(xzRel.x*ca - xzRel.y*sa,
                        xzRel.x*sa + xzRel.y*ca);

    float3 P0 = float3(xzr.x, wp.y, xzr.y) * 0.00110;
    float base = fbm2(P0 * float3(1.0, 0.35, 1.0));

    float yy = wp.y * 0.002 + 5.37;
    float puffs = puffFBM2(xzr * max(1e-4, kPuffScale) + float2(yy, -yy*0.7));

    float3 P1 = float3(xzr.x, wp.y*1.6, xzr.y) * 0.0040 + float3(2.7,0.0,-5.1);
    float erode = fbm2(P1);

    float shape = base + kPuffStrength*(puffs - 0.5) - (1.0 - erode) * (0.30 * kDetailMul);
    float coverInv = 1.0 - kCoverage;
    float thLo = clamp(coverInv - 0.20, 0.0, 1.0);
    float thHi = clamp(coverInv + 0.28, 0.0, 1.2);
    float t    = smoothstep(thLo, thHi, shape);

    float dens = pow(clamp(t, 0.0, 1.0), 0.85);
    float macro = 1.0 - clamp(worley2(xzr * max(1e-6, kMacroScale)), 0.0, 1.0);
    float macroMask = smoothstep(kMacroThreshold - 0.10, kMacroThreshold + 0.10, macro);
    dens *= macroMask;

    dens *= hProfile(wp.y + kHorizonLift*120.0, kBaseY, kTopY);
    return dens;
}

fragment half4 cloud_impostor_fragment(
    VSOut in [[stage_in]],
    constant SCNSceneBuffer& frame [[buffer(0)]],
    constant float4x4& uModel       [[buffer(1)]],
    constant float2& uHalfSize      [[buffer(2)]]
){
    // Camera → world ray
    float4 camW4 = frame.inverseViewTransform * float4(0,0,0,1);
    float3 camPos = camW4.xyz / max(1e-6, camW4.w);

    float4 ndc  = float4(in.ndcXY, 1.0, 1.0);
    float4 view = frame.inverseProjectionTransform * ndc;
    float3 Vvs  = normalize(view.xyz / max(1e-5, view.w));
    float3 V    = normalize((frame.inverseViewTransform * float4(Vvs, 0)).xyz);

    // Plane basis
    float3 ux   = normalize(uModel[0].xyz);
    float3 vy   = normalize(uModel[1].xyz);
    float3 nrm  = normalize(cross(ux, vy));
    float3 origin = (uModel * float4(0,0,0,1)).xyz;
    float2 anchorXZ = origin.xz;

    float denom = dot(V, nrm);
    if (denom < 0.0) { nrm = -nrm; denom = -denom; }
    if (denom < 1e-5) discard_fragment();

    float tPlane = dot(origin - camPos, nrm) / denom;
    if (tPlane < 0.0) discard_fragment();

    float worldHalfX = length(uModel[0].xyz) * max(1e-5, uHalfSize.x);
    float worldHalfY = length(uModel[1].xyz) * max(1e-5, uHalfSize.y);
    float slabHalf   = max(worldHalfX, worldHalfY) * 0.9;

    float tEnt = max(0.0, tPlane - slabHalf);
    float tExt = tPlane + slabHalf;
    float Lm   = tExt - tEnt;
    if (Lm <= 1e-5) discard_fragment();

    float distLOD  = clamp(Lm / 2500.0, 0.0, 1.2);
    int   baseSteps = int(round(mix(8.0, 16.0, 1.0 - distLOD*0.7)));
    int   numSteps  = clamp(int(round(float(baseSteps) * kStepMul)), 6, 20);
    float dt        = Lm / float(numSteps);

    float j = fract(sin(dot(in.ndcXY, float2(12.9898, 78.233))) * 43758.5453);
    float t = tEnt + (0.25 + 0.5*j) * dt;

    half T = half(1.0);
    const half rhoGate = half(0.0025);
    for (int i=0; i < numSteps && T > half(0.004); ++i)
    {
        float3 sp = camPos + V * t;

        float3 d = sp - origin;
        float lpX = dot(d, ux);
        float lpY = dot(d, vy);
        float er = length(float2(lpX/worldHalfX, lpY/worldHalfY));
        float edgeMask = smoothstep(1.0, 0.95, 1.0 - er);

        half rho = half(densityAtAnchored(sp, anchorXZ) * edgeMask);
        if (rho < rhoGate) { t += dt; continue; }

        half sigma = half(kDensityMul * 0.032);
        half aStep = half(1.0) - half(exp(-float(rho) * float(sigma) * dt));
        T *= (half(1.0) - aStep);
        t += dt;
    }

    half alpha = half(clamp(1.0 - float(T), 0.0, 1.0));
    half3 rgb  = half3(1.0) * alpha;
    return half4(rgb, alpha);
}
