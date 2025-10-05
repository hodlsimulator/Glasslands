//
//  SkyVolumetricClouds.metal
//  Glasslands
//
//  Created by . . on 10/5/25.
//
//  Volumetric cumulus via fast ray-march (single scattering + powder effect)
//  with an HDR sun disc/halo drawn into the base sky. Used by SCNProgram.
//

#include <metal_stdlib>
#include <simd/simd.h>
using namespace metal;
using namespace simd;
#include <SceneKit/scn_metal>

struct CloudUniforms {
    float4 sunDirWorld;
    float4 sunTint;
    float   time;
    float2  wind;
    float   baseY;
    float   topY;
    float   coverage;
    float   densityMul;
    float   stepMul;
    float   horizonLift;
    float   _pad;
};

struct VSIn { float3 position [[attribute(SCNVertexSemanticPosition)]]; };
struct VSOut { float4 position [[position]]; float3 worldPos; };

vertex VSOut clouds_vertex(VSIn vin [[stage_in]],
                           constant SCNSceneBuffer& scn_frame [[buffer(0)]]) {
    VSOut o;
    float4 world = float4(vin.position, 1.0);
    float4 view  = scn_frame.viewTransform * world;
    o.position   = scn_frame.projectionTransform * view;
    o.worldPos   = world.xyz;
    return o;
}

// ---- helpers ----
inline float  saturate1(float x){ return clamp(x,0.0f,1.0f); }
inline float3 saturate3(float3 v){ return clamp(v,float3(0.0),float3(1.0)); }
inline float  frac1(float x){ return x - floor(x); }
inline float  lerp1(float a,float b,float t){ return a + (b-a)*t; }
inline float3 lerp3(float3 a,float3 b,float t){ return a + (b-a)*t; }
inline float  deg2rad(float d){ return d * 0.017453292519943295f; }
inline float  hash1(float n){ return frac1(sin(n)*43758.5453123f); }

inline float noise3(float3 x){
    float3 p = floor(x), f = x - p; f = f*f*(3.0f - 2.0f*f);
    float n = dot(p, float3(1.0,57.0,113.0));
    float n000 = hash1(n+0.0),   n100 = hash1(n+1.0);
    float n010 = hash1(n+57.0),  n110 = hash1(n+58.0);
    float n001 = hash1(n+113.0), n101 = hash1(n+114.0);
    float n011 = hash1(n+170.0), n111 = hash1(n+171.0);
    float nx00 = lerp1(n000,n100,f.x), nx10 = lerp1(n010,n110,f.x);
    float nx01 = lerp1(n001,n101,f.x), nx11 = lerp1(n011,n111,f.x);
    float nxy0 = lerp1(nx00,nx10,f.y), nxy1 = lerp1(nx01,nx11,f.y);
    return lerp1(nxy0,nxy1,f.z);
}
inline float fbm(float3 p){
    float a=0.0f,w=0.5f;
    for(int i=0;i<4;i++){ a+=noise3(p)*w; p=p*2.01f+19.0f; w*=0.5f; }
    return a;
}
inline float2 curl2(float2 xz){
    const float e=0.02f;
    float n1 = noise3(float3(xz.x+e,0.0,xz.y)) - noise3(float3(xz.x-e,0.0,xz.y));
    float n2 = noise3(float3(xz.x,0.0,xz.y+e)) - noise3(float3(xz.x,0.0,xz.y-e));
    float2 v = float2(n2,-n1);
    float len = max(length(v),1e-5f);
    return v/len;
}
inline float heightProfile(float y,float baseY,float topY){
    float h=saturate1((y-baseY)/max(1.0f,(topY-baseY)));
    float up=smoothstep(0.02f,0.25f,h);
    float dn=1.0f-smoothstep(0.68f,1.00f,h);
    return pow(up*dn,0.78f);
}
inline float densityAt(float3 wp, constant CloudUniforms& U){
    float3 q = wp * 0.0011f;
    float2 flow = U.wind*0.0012f + 1.1f*curl2(q.xz + U.time*0.07f);
    q.xz += flow*U.time;
    float3 warp = float3(fbm(q*1.6f+31.0f), fbm(q*1.7f+57.0f), fbm(q*1.8f+83.0f));
    q += (warp-0.5f)*0.44f;
    float shape=fbm(q*0.8f), detail=fbm(q*2.4f)*0.50f;
    float prof=heightProfile(wp.y,U.baseY,U.topY);
    float thr = lerp1(0.65f,0.45f,saturate1(U.coverage));
    float d = (shape*0.95f + detail*0.65f)*prof - thr + 0.08f;
    return smoothstep(0.0f,0.70f,d);
}
inline float3 sunGlow(float3 rd,float3 sunW,float3 sunTint){
    float ct=clamp(dot(rd,sunW),-1.0f,1.0f), ang=acos(ct);
    const float rad=deg2rad(0.95f);
    float core=1.0f-smoothstep(rad*0.75f,rad,ang);
    float halo1=1.0f-smoothstep(rad*1.25f,rad*3.50f,ang);
    float halo2=1.0f-smoothstep(rad*3.50f,rad*7.50f,ang);
    float edr=core*5.0f + halo1*0.90f + halo2*0.25f;
    return sunTint*edr;
}

fragment float4 clouds_fragment(VSOut in [[stage_in]],
                                constant SCNSceneBuffer& scn_frame [[buffer(0)]],
                                constant CloudUniforms& U [[buffer(2)]]) {

    float3 ro = (scn_frame.inverseViewTransform * float4(0,0,0,1)).xyz;
    float3 rd = normalize(in.worldPos - ro);

    float tSky = saturate1(rd.y*0.6f + 0.4f);
    float3 base = lerp3(float3(0.88,0.93,0.99), float3(0.30,0.56,0.96), tSky);
    float3 sunW = normalize(U.sunDirWorld.xyz);
    base += sunGlow(rd, sunW, U.sunTint.xyz);

    float denom = rd.y; float tb=0.0f, tt=-1.0f; bool hits = fabs(denom) >= 1e-4f;
    if(hits){ tb=(U.baseY-ro.y)/denom; tt=(U.topY-ro.y)/denom; }
    float t0 = hits ? max(min(tb,tt),0.0f) : 1e9f;
    float t1 = hits ? max(tb,tt) : -1e9f;

    float3 acc = float3(0.0); float trans=1.0f;
    if(hits && t1>0.0f){
        const int MAX_STEPS=20;
        float baseStep=220.0f*U.stepMul;
        float grazing=clamp(1.0f - fabs(rd.y), 0.0f, 1.0f);
        float worldStep=baseStep * lerp1(1.0f,2.2f,grazing);
        float horizonK=U.horizonLift * smoothstep(0.0f,0.15f,grazing);
        float jitter=frac1(dot(in.worldPos,float3(1.0,57.0,113.0))) * worldStep;
        float t=t0 + jitter;
        for(int i=0;i<MAX_STEPS;++i){
            if(t>t1) break;
            float3 p=ro+rd*t;
            float d=densityAt(p,U)*U.densityMul;
            if(d>1e-3f){
                float dl=densityAt(p + sunW*300.0f, U);
                float shade=0.55f + 0.45f*smoothstep(0.15f,0.95f,1.0f - dl);
                float powder=1.0f - exp(-2.2f*d);
                float3 localCol = saturate3(float3(1.0) * (0.70f + 0.30f*shade + horizonK));
                float a = saturate1(d * (worldStep/220.0f));
                float3 add = localCol * (powder * a);
                acc += trans * add;
                trans *= (1.0f - a);
                if(trans < 0.03f) break;
            }
            t += worldStep;
        }
    }

    float3 outRGB = base * trans + acc + U.sunTint.xyz * acc * 0.08f;
    return float4(outRGB, 1.0);
}
