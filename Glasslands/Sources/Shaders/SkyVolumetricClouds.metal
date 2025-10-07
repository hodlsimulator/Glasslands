//
//  SkyVolumetricClouds.metal
//  Glasslands
//
//  Created by . . on 10/5/25.
//
//  Volumetric vapour with adaptive two-phase raymarch and quality control.
//  Premultiplied pure white; sun/self-shadowing lives in alpha.
//

#include <metal_stdlib>
using namespace metal;
#include <SceneKit/scn_metal>

static constant float kPI = 3.14159265358979323846f;

struct GLCloudUniforms {
    float4 sunDirWorld;
    float4 sunTint;
    float4 params0;   // x=time, y=wind.x, z=wind.y, w=baseY
    float4 params1;   // x=topY, y=coverage, z=densityMul, w=stepMul
    float4 params2;   // x=mieG, y=powderK, z=horizonLift, w=detailMul
    float4 params3;   // x=domainOffX, y=domainOffY, z=domainRotate, w=puffScale
    float4 params4;   // x=puffStrength, y=quality(0.3..1), z/w unused
};

struct GLVSIn  { float3 position [[ attribute(SCNVertexSemanticPosition) ]]; };
struct GLVSOut { float4 position [[position]]; float3 worldPos; };

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

// ---- inline helpers ----
inline float hash1(float n) { return fract(sin(n) * 43758.5453123f); }
inline float hash12(float2 p){ return fract(sin(dot(p, float2(127.1,311.7))) * 43758.5453123f); }

inline float noise3(float3 x) {
    float3 p = floor(x), f = x - p;
    f = f * f * (3.0 - 2.0 * f);
    const float3 off = float3(1.0, 57.0, 113.0);
    float n = dot(p, off);
    float n000 = hash1(n + 0.0),   n100 = hash1(n + 1.0);
    float n010 = hash1(n + 57.0),  n110 = hash1(n + 58.0);
    float n001 = hash1(n + 113.0), n101 = hash1(n + 114.0);
    float n011 = hash1(n + 170.0), n111 = hash1(n + 171.0);
    float nx00 = mix(n000, n100, f.x), nx10 = mix(n010, n110, f.x);
    float nx01 = mix(n001, n101, f.x), nx11 = mix(n011, n111, f.x);
    float nxy0 = mix(nx00, nx10, f.y), nxy1 = mix(nx01, nx11, f.y);
    return mix(nxy0, nxy1, f.z);
}

inline float fbmN(float3 p, int oct){
    float a = 0.0, w = 0.5;
    for (int i=0; i<4; ++i){ if (i>=oct) break; a += noise3(p) * w; p = p * 2.02 + 19.19; w *= 0.5; }
    return a;
}

// Cheap 2D Worley (F1) on XZ for micro “puffs”
inline float worley2(float2 x){
    float2 i = floor(x), f = x - i;
    float d = 1e9;
    for (int y=-1; y<=1; ++y)
    for (int xk=-1; xk<=1; ++xk){
        float2 g = float2(xk,y);
        float2 o = float2(hash12(i+g), hash12(i+g+19.7));
        float2 r = g + o - f;
        d = min(d, dot(r,r));
    }
    return sqrt(max(d,0.0));
}

inline float puffFBM(float2 x, int oct) {
    float a = 0.0, w = 0.55, s = 1.0;
    for (int i=0; i<3; ++i){ if (i>=oct) break;
        float v = 1.0 - clamp(worley2(x*s), 0.0, 1.0);
        a += v*w; s *= 2.03; w *= 0.55;
    }
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

// Density field with friendlier coverage mapping (avoids “zero density”)
inline float densityAt(float3 wp, constant GLCloudUniforms& U, float Q){
    float time         = U.params0.x;
    float2 wind        = float2(U.params0.y, U.params0.z);
    float baseY        = U.params0.w;
    float topY         = U.params1.x;
    float coverage     = clamp(U.params1.y, 0.05, 0.98);
    float detailMul    = max(0.0, U.params2.w);
    float horizonLift  = U.params2.z;
    float2 domOff      = float2(U.params3.x, U.params3.y);
    float domRot       = U.params3.z;
    float puffScale    = max(1e-4, U.params3.w);
    float puffStrength = clamp(U.params4.x, 0.0, 1.5);

    int octBase  = (Q > 0.7 ? 4 : (Q > 0.5 ? 3 : 2));
    int octErode = (Q > 0.7 ? 4 : 2);
    int octPuff  = (Q > 0.7 ? 3 : 2);

    float h01 = hProfile(wp.y, baseY, topY);

    float ca = cos(domRot), sa = sin(domRot);
    float2 xz  = wp.xz + domOff;
    float2 xzr = float2(xz.x*ca - xz.y*sa, xz.x*sa + xz.y*ca);
    float adv = mix(0.55, 1.55, h01);
    float2 advXY = xzr + wind * adv * (time * 0.0035);

    float3 P0 = float3(advXY.x, wp.y, advXY.y) * 0.00110;
    float base = fbmN(P0 * float3(1.0, 0.35, 1.0), octBase);

    float yy = wp.y * 0.002 + 5.37;
    float puffs = puffFBM(advXY * puffScale + float2(yy, -yy*0.7), octPuff);

    float3 P1 = float3(advXY.x, wp.y*1.8, advXY.y) * 0.0046 + float3(2.7,0.0,-5.1);
    float erode = fbmN(P1, octErode);

    float shape = base + puffStrength*(puffs - 0.5) - (1.0 - erode) * (0.34 * detailMul);

    // Friendlier coverage map: wide soft knee so thin vapour survives
    float thLo = (1.0 - coverage) - 0.16;   // was too high → zero density
    float thHi = (1.0 - coverage) + 0.56;
    float t    = smoothstep(thLo, thHi, shape);
    float dens = pow(clamp(t, 0.0, 1.0), 0.90);

    dens *= hProfile(wp.y + horizonLift*120.0, baseY, topY);
    return dens;
}

fragment half4 gl_vapour_fragment(GLVSOut in [[stage_in]],
                                  constant SCNSceneBuffer& scn_frame [[buffer(0)]],
                                  constant GLCloudUniforms& u [[buffer(1)]])
{
    float Q = clamp(u.params4.y, 0.3, 1.0);

    float4 camW4 = scn_frame.inverseViewTransform * float4(0,0,0,1);
    float3 camPos = camW4.xyz / camW4.w;
    float3 V = normalize(in.worldPos - camPos);

    float baseY = u.params0.w;
    float topY  = u.params1.x;

    float vdY   = V.y;
    float t0    = (baseY - camPos.y) / max(1e-5, vdY);
    float t1    = (topY  - camPos.y) / max(1e-5, vdY);
    float tEnt  = max(0.0, min(t0, t1));
    float tExt  = min(tEnt + 5000.0, max(t0, t1));
    if (tExt <= tEnt + 1e-5) discard_fragment();

    float Lm = tExt - tEnt;
    float distLOD = clamp(Lm / 4000.0, 0.0, 1.5);
    int   Nbase = (Q > 0.8 ? 36 : (Q > 0.6 ? 28 : 20));
    int   N     = clamp(int(round(float(Nbase) * (0.90 + 0.6*distLOD))), 12, 48);
    float dt    = Lm / float(N);

    float2 st = float2(in.position.x, in.position.y);
    float  j  = fract(sin(dot(st, float2(12.9898, 78.233))) * 43758.5453);
    float  t  = tEnt + (0.25 + 0.5*j) * dt;

    float3 S  = normalize(u.sunDirWorld.xyz);
    float  mu = clamp(dot(V, S), -1.0, 1.0);
    float  g  = clamp(u.params2.x, 0.0, 0.95);

    float T = 1.0;

    // Tweaked gates: lower density gate and slightly stronger sigma
    const float rhoGate = 0.006;           // was 0.025 → caused empty passes
    const float refineMul = 0.45;
    const int   refineMax = 4;
    const float skipMul = (0.9 + (1.6 - 0.9) * (1.0 - Q));

    for (int i=0; i<N && T>0.005; ++i) {
        float3 sp  = camPos + V * t;
        float  rho = densityAt(sp, u, Q);

        if (rho < rhoGate) { t += dt * skipMul; continue; }

        float td = dt * refineMul;
        for (int k=0; k<refineMax && T>0.005; ++k){
            float3 sp2 = sp + V * (td * float(k));
            float  rho2 = densityAt(sp2, u, Q);

            float Lsun = 1.0;
            {
                int   NL = (Q > 0.7 ? 3 : 2);
                float dL = ((topY - baseY)/max(1,NL)) * 0.90;
                float3 lp = sp2;
                for (int j2=0; j2<NL && Lsun > 0.02; ++j2){
                    lp += S * dL;
                    float occ = densityAt(lp, u, Q);
                    float aL  = 1.0 - exp(-occ * max(0.0, u.params1.z) * dL * 0.012); // +20%
                    Lsun *= (1.0 - aL);
                }
            }

            float sigma = max(0.0, u.params1.z) * 0.028;   // was 0.022
            float aStep = 1.0 - exp(-rho2 * sigma * td);

            float ph    = phaseHG(mu, g);
            float shade = Lsun * exp(-u.params2.y * (1.0 - rho2));
            float gain  = clamp(0.85 + 0.30 * ph * shade, 0.0, 1.4);

            T *= (1.0 - aStep * gain);
            if (T <= 0.005) break;
        }

        t += dt;
    }

    float alpha = clamp(1.0 - T, 0.0, 1.0);
    float3 rgb  = float3(1.0) * alpha;   // premultiplied pure white
    return half4(half3(rgb), half(alpha));
}
