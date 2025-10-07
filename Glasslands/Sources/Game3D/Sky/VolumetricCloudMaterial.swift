//
//  VolumetricCloudMaterial.swift
//  Glasslands
//
//  Created by . . on 10/5/25.
//
//  Binder-free volumetric clouds using a fragment shader-modifier.
//  Now lighter: fewer steps + early-outs. Lit only by the sun.
//

import SceneKit
import UIKit

enum VolumetricCloudMaterial {

    static func makeMaterial() -> SCNMaterial {
        let fragment = """
        #pragma transparent
        #pragma arguments
        float   time;
        float3  sunDirWorld;
        float3  sunTint;
        float3  wind;
        float3  domainOffset;
        float   domainRotate;
        float   baseY;
        float   topY;
        float   coverage;
        float   densityMul;
        float   stepMul;     // 0.35..1.0
        float   mieG;
        float   powderK;
        float   horizonLift;
        float   detailMul;

        float frac(float x){ return x - floor(x); }
        float hash1(float n){ return frac(sin(n) * 43758.5453123); }
        float noise3(float3 x){
            float3 p = floor(x);
            float3 f = x - p; f = f * f * (3.0 - 2.0 * f);
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
        float fbm4(float3 p){
            float a=0.0,w=0.5; for(int i=0;i<4;++i){ a+=noise3(p)*w; p=p*2.02+19.19; w*=0.5; } return a;
        }
        float2 curl2(float2 xz){
            const float e=0.02;
            float n1=noise3(float3(xz.x+e,0.0,xz.y))-noise3(float3(xz.x-e,0.0,xz.y));
            float n2=noise3(float3(xz.x,0.0,xz.y+e))-noise3(float3(xz.x,0.0,xz.y-e));
            float2 v=float2(n2,-n1); float len=max(length(v),1e-5); return v/len;
        }
        float hProf(float y,float b,float t){
            float h=clamp((y-b)/max(1.0,(t-b)),0.0,1.0);
            float up=smoothstep(0.03,0.25,h); float dn=1.0-smoothstep(0.68,1.0,h);
            return pow(clamp(up*dn,0.0,1.0),0.80);
        }
        float densityAt(float3 wp){
            float2 domOff=domainOffset.xy; float ang=domainRotate;
            float ca=cos(ang), sa=sin(ang);
            float2 xz=wp.xz+domOff; float2 xzr=float2(xz.x*ca-xz.y*sa, xz.x*sa+xz.y*ca);
            float adv=mix(0.5,1.5,hProf(wp.y,baseY,topY));
            float2 advXY=xzr+wind.xy*adv*(time*0.0035);
            float3 P0=float3(advXY.x, wp.y, advXY.y)*0.00115;
            float base=fbm4(P0*float3(1.0,0.35,1.0));
            float3 P1=float3(advXY.x, wp.y*1.8, advXY.y)*0.0046+float3(2.7,0.0,-5.1);
            float detail=fbm4(P1);
            float2 cr=curl2(advXY*0.0022);
            float edge=base + (detailMul*0.55)*(detail-0.45) + 0.10*cr.x;
            float dens=clamp( (edge-(1.0-coverage))/max(1e-3,coverage), 0.0, 1.0 );
            dens*=hProf(wp.y + horizonLift*120.0, baseY, topY);
            return dens;
        }
        float phaseHG(float c,float g){ float g2=g*g; return (1.0-g2)/max(1e-4,4.0*3.14159265*pow(1.0+g2-2.0*g*c,1.5)); }
        float powder(float occ,float k){ return exp(-k*clamp(occ,0.0,1.0)); }

        #pragma body
        float3 camPos = (u_inverseViewTransform * float4(0,0,0,1)).xyz;
        float3 wp = _surface.position;
        float3 V = normalize(wp - camPos);

        // Early reject: if ray heads downward and starts below base, discard
        if (V.y < -0.01 && camPos.y < baseY-2.0) discard_fragment();

        // Slab hit
        float vdY = V.y;
        float t0 = (baseY - camPos.y) / max(1e-5, vdY);
        float t1 = (topY  - camPos.y) / max(1e-5, vdY);
        float tEnter = max(0.0, min(t0, t1));
        float tExit  = min(tEnter + 4500.0, max(t0, t1));
        if (tExit <= tEnter + 1e-5) discard_fragment();

        float3 S = normalize(sunDirWorld);
        float cosSV = clamp(dot(V,S), -1.0, 1.0);
        float g = clamp(mieG, 0.0, 0.95);

        // Cheaper march
        const int Nbase = 28;
        int N = clamp(int(round(float(Nbase)*clamp(stepMul,0.35,1.0))), 12, 42);
        float len = max(1e-3, tExit - tEnter);
        float dt = len / float(N);

        float T = 1.0;
        float3 C = float3(0);

        float t = tEnter + 0.5*dt;
        for (int i=0; i<N && T>0.004; ++i, t+=dt) {
            float3 sp = camPos + V * t;
            float rho = densityAt(sp);
            if (rho <= 1e-4) continue;

            // Very short sun occlusion
            float L = 1.0; {
                const int NL=4; float dL=((topY-baseY)/max(1,NL))*0.9;
                float3 lp = sp;
                for (int j=0;j<NL && L>0.02;++j){ lp += S*dL; float occ=densityAt(lp);
                    float aL = 1.0 - exp(-occ * max(0.0,densityMul) * dL * 0.012);
                    L *= (1.0 - aL);
                }
            }

            float sigma = max(0.0,densityMul)*0.022;
            float a = 1.0 - exp(-rho * sigma * dt);
            float ph = phaseHG(cosSV, g);
            float pd = powder(1.0 - rho, powderK);
            C += T * a * (sunTint * L * ph * pd);
            T *= (1.0 - a);
        }

        _output.color = float4(clamp(C,0.0,1.0), clamp(1.0-T,0.0,1.0));
        """

        let m = SCNMaterial()
        m.lightingModel = .constant
        m.cullMode = .front
        m.readsFromDepthBuffer = false
        m.writesToDepthBuffer = false
        m.blendMode = .alpha
        m.shaderModifiers = [.fragment: fragment]

        // Defaults; the engine updates these
        m.setValue(NSNumber(value: 0.0), forKey: "time")
        m.setValue(SCNVector3(0, 1, 0), forKey: "sunDirWorld")
        m.setValue(SCNVector3(1, 1, 1), forKey: "sunTint")
        m.setValue(SCNVector3(0.55, 0.20, 0), forKey: "wind")
        m.setValue(SCNVector3(0, 0, 0), forKey: "domainOffset")
        m.setValue(NSNumber(value: 0.0), forKey: "domainRotate")
        m.setValue(NSNumber(value: 400.0), forKey: "baseY")
        m.setValue(NSNumber(value: 1400.0), forKey: "topY")
        m.setValue(NSNumber(value: 0.42), forKey: "coverage")
        m.setValue(NSNumber(value: 1.05), forKey: "densityMul")
        m.setValue(NSNumber(value: 0.55), forKey: "stepMul")   // ← lighter
        m.setValue(NSNumber(value: 0.60), forKey: "mieG")
        m.setValue(NSNumber(value: 2.00), forKey: "powderK")
        m.setValue(NSNumber(value: 0.14), forKey: "horizonLift")
        m.setValue(NSNumber(value: 1.00), forKey: "detailMul")
        return m
    }
}
