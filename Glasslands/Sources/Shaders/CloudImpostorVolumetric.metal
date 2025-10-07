//
//  CloudImpostorVolumetric.metal
//  Glasslands
//
//  Created by . . on 10/7/25.
//
//  Volumetric billboard impostor (pure vapour; no 2D sprite sampling).
//  Anchors the vapour domain to the impostor’s model origin so the cloud
//  moves as a whole when the camera moves/turns.
//

#include <metal_stdlib>
using namespace metal;
#include <SceneKit/scn_metal>

static constant float kPI = 3.14159265358979323846f;

// Must match Swift GLCloudUniforms (VolCloudUniformsStore).
struct GLCloudUniforms {
    float4 sunDirWorld;
    float4 sunTint;
    float4 params0; // x=time, y=wind.x, z=wind.y, w=baseY
    float4 params1; // x=topY, y=coverage, z=densityMul, w=stepMul
    float4 params2; // x=mieG, y=powderK, z=horizonLift, w=detailMul
    float4 params3; // x=domainOffX, y=domainOffY, z=domainRotate, w=puffScale
    float4 params4; // x=puffStrength, y=quality(0.35…1.15), z=macroScale, w=macroThreshold
};

struct VSIn {
    float3 position [[attribute(SCNVertexSemanticPosition)]];
};

struct VSOut {
    float4 position [[position]];
    float2 ndcXY; // clip.xy / clip.w
};

vertex VSOut cloud_impostor_vertex(
    VSIn vin [[stage_in]],
    constant SCNSceneBuffer& frame [[buffer(0)]],
    constant float4x4& uModel [[buffer(1)]])
{
    VSOut o;
    float4 world = uModel * float4(vin.position, 1.0);
    float4 view  = frame.viewTransform * world;
    float4 clip  = frame.projectionTransform * view;
    o.position = clip;
    o.ndcXY    = clip.xy / max(1e-6, clip.w);
    return o;
}

// ---- noise helpers ----
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

inline float phaseHG(float mu, float g){
    float g2 = g*g;
    return (1.0 - g2) / max(1e-4, 4.0*kPI*pow(1.0 + g2 - 2.0*g*mu, 1.5));
}

// Density anchored to the impostor’s model origin in XZ.
inline float densityAtAnchored(float3 wp,
                              float2 anchorXZ,
                              constant GLCloudUniforms& U)
{
    float time = U.params0.x;
    float2 wind = float2(U.params0.y, U.params0.z);
    float baseY = U.params0.w;
    float topY  = U.params1.x;
    float coverage   = clamp(U.params1.y, 0.05, 0.98);
    float detailMul  = U.params2.w;
    float horizonLift= U.params2.z;

    float2 domOff = float2(U.params3.x, U.params3.y);
    float domRot  = U.params3.z;
    float puffScale = max(1e-4, U.params3.w);

    float puffStrength= clamp(U.params4.x, 0.0, 1.5);
    float macroScale  = max(1e-6, U.params4.z);
    float macroThresh = clamp(U.params4.w, 0.0, 1.0);

    float h01 = hProfile(wp.y, baseY, topY);

    // XZ anchored to the plane’s origin
    float2 xzRel = (wp.xz - anchorXZ) + domOff;

    float ca = cos(domRot), sa = sin(domRot);
    float2 xzr = float2(xzRel.x*ca - xzRel.y*sa,
                        xzRel.x*sa + xzRel.y*ca);

    float adv = mix(0.55, 1.55, h01);
    float2 advXY = xzr + wind * adv * (time * 0.0035);

    float macro = 1.0 - clamp(worley2(advXY * macroScale), 0.0, 1.0);
    float macroMask = smoothstep(macroThresh - 0.10, macroThresh + 0.10, macro);

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
    float t    = smoothstep(thLo, thHi, shape);

    float dens = pow(clamp(t, 0.0, 1.0), 0.85);
    dens *= macroMask;

    // Vertical shaping in world-space.
    dens *= hProfile(wp.y + horizonLift*120.0, baseY, topY);
    return dens;
}

fragment half4 cloud_impostor_fragment(
    VSOut in [[stage_in]],
    constant SCNSceneBuffer& frame [[buffer(0)]],
    constant float4x4& uModel     [[buffer(1)]],
    constant GLCloudUniforms& U   [[buffer(2)]],
    constant float2& uHalfSize    [[buffer(3)]])
{
    // Camera → view ray
    float4 camW4 = frame.inverseViewTransform * float4(0,0,0,1);
    float3 camPos = camW4.xyz / max(1e-6, camW4.w);

    float4 ndc  = float4(in.ndcXY, 1.0, 1.0);
    float4 view = frame.inverseProjectionTransform * ndc;
    float3 Vvs  = normalize(view.xyz / max(1e-5, view.w));
    float3 V    = normalize((frame.inverseViewTransform * float4(Vvs, 0)).xyz);

    // Plane basis from model matrix (columns).
    float3 ux   = normalize(uModel[0].xyz);
    float3 vy   = normalize(uModel[1].xyz);
    float3 nrm  = normalize(cross(ux, vy));
    float3 origin = (uModel * float4(0,0,0,1)).xyz;
    float2 anchorXZ = origin.xz;

    // Ray/plane intersection — robust to normal flips.
    float denom = dot(V, nrm);
    if (denom < 0.0) { nrm = -nrm; denom = -denom; }
    if (denom < 1e-5) discard_fragment();

    float tPlane = dot(origin - camPos, nrm) / denom;
    if (tPlane < 0.0) discard_fragment();

    // Slab thickness & local half extents in world units
    float worldHalfX = length(uModel[0].xyz) * max(1e-5, uHalfSize.x);
    float worldHalfY = length(uModel[1].xyz) * max(1e-5, uHalfSize.y);
    float slabHalf   = max(worldHalfX, worldHalfY) * 0.9;

    float tEnt = max(0.0, tPlane - slabHalf);
    float tExt = tPlane + slabHalf;
    float Lm   = tExt - tEnt;
    if (Lm <= 1e-5) discard_fragment();

    // Steps (LOD + external multipliers)
    float distLOD  = clamp(Lm / 2500.0, 0.0, 1.2);
    float stepMul  = clamp(U.params1.w, 0.50, 1.35);
    float quality  = clamp(U.params4.y, 0.35, 1.15);   // lower = faster
    int   baseSteps = int(round(mix(8.0, 16.0, 1.0 - distLOD*0.7)));
    int   numSteps  = clamp(int(round(float(baseSteps) * stepMul * quality)), 6, 20);
    float dt        = Lm / float(numSteps);

    // Jitter
    float j = fract(sin(dot(in.ndcXY, float2(12.9898, 78.233))) * 43758.5453);
    float t = tEnt + (0.25 + 0.5*j) * dt;

    half3 S = half3(normalize(U.sunDirWorld.xyz));
    half mu = half(clamp(dot(V, float3(S)), -1.0, 1.0));
    half g  = half(clamp(U.params2.x, 0.0, 0.95));

    half T = half(1.0);
    const half rhoGate   = half(0.0025);
    const int  refineMax = 1;
    const half refineMul = half(0.50);

    for (int i=0; i < numSteps && T > half(0.004); ++i)
    {
        float3 sp = camPos + V * t;

        // Local (in-plane) coordinates for edge falloff
        float3 d = sp - origin;
        float lpX = dot(d, ux);
        float lpY = dot(d, vy);

        float2 hn = float2(max(worldHalfX, 1e-4), max(worldHalfY, 1e-4));
        float er = length(float2(lpX, lpY) / hn); // 0 centre … 1 at edge
        float edgeMask = smoothstep(1.0, 0.95, 1.0 - er);

        half rho = half(densityAtAnchored(sp, anchorXZ, U)) * half(edgeMask);
        if (rho < rhoGate) { t += dt; continue; }

        // One-tap sun probe
        {
            float baseY = U.params0.w;
            float topY  = U.params1.x;
            float dL    = (topY - baseY) * 0.20;
            float3 lpSun = sp + float3(S) * dL;
            half occ  = half(densityAtAnchored(lpSun, anchorXZ, U));
            half sigmaSun = half(max(0.0f, U.params1.z) * 0.010);
            half aL = half(1.0) - half(exp(-float(occ) * float(sigmaSun) * dL));
            rho = half(min(1.0f, float(rho) * (1.0f - 0.55f * float(aL))));
        }

        // Short refinement
        half td = half(dt) * refineMul;
        for (int k=0; k < refineMax && T > half(0.004); ++k) {
            float3 sp2 = sp + V * (float(td) * float(k));
            half rho2 = half(densityAtAnchored(sp2, anchorXZ, U));
            half sigma = half(max(0.0f, U.params1.z) * 0.032);
            half aStep = half(1.0) - half(exp(-float(rho2) * float(sigma) * float(td)));
            half ph = half(phaseHG(float(mu), float(g)));
            half gain = half(clamp(0.90 + 0.22 * float(ph), 0.0, 1.3));
            T *= (half(1.0) - aStep * gain);
            if (T <= half(0.004)) break;
        }

        t += dt;
    }

    half alpha = half(clamp(1.0 - float(T), 0.0, 1.0));
    half3 rgb  = half3(1.0) * alpha; // premultiplied white
    return half4(rgb, alpha);
}
