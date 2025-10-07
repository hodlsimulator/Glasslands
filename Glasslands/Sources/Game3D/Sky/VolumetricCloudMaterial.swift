//
//  VolumetricCloudMaterial.swift
//  Glasslands
//
//  Created by . . on 10/5/25.
//
//  True volumetric vapour: base mass + micro "puff" cells.
//  RGB is premultiplied pure white; alpha carries shading.
//

import SceneKit
import UIKit

enum VolumetricCloudMaterial {
    @MainActor
    static func makeMaterial() -> SCNMaterial {
        let fragment = """
        #pragma transparent

        // -------- uniforms --------
        #pragma arguments
        float time;
        float3 sunDirWorld;
        float3 wind;
        float3 domainOffset;
        float  domainRotate;
        float  baseY;
        float  topY;
        float  coverage;
        float  densityMul;
        float  stepMul;
        float  mieG;
        float  powderK;
        float  horizonLift;
        float  detailMul;
        float  puffScale;
        float  puffStrength;
        #pragma body

        // -------- helpers --------
        float fractf(float x){ return x - floor(x); }
        float hash1(float n){ return fractf(sin(n) * 43758.5453123); }
        float hash12(float2 p){ return fractf(sin(dot(p, float2(127.1,311.7))) * 43758.5453123); }

        float noise3(float3 x){
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

        float fbm4(float3 p){
            float a = 0.0, w = 0.5;
            for(int i=0;i<4;++i){ a += noise3(p) * w; p = p * 2.02 + 19.19; w *= 0.5; }
            return a;
        }

        // 2D Worley F1 for micro-puffs (cheap: 3x3 neighbourhood on XZ)
        float worley2(float2 x){
            float2 i = floor(x), f = x - i;
            float d = 1e9;
            for(int y=-1;y<=1;++y){
                for(int xk=-1;xk<=1;++xk){
                    float2 g = float2(xk,y);
                    float2 o = float2(hash12(i+g), hash12(i+g+19.7));
                    float2 r = g + o - f;
                    d = min(d, dot(r,r));
                }
            }
            return sqrt(d); // 0..~1
        }

        float puffFBM(float2 x){
            // Combine octaves of 1 - Worley to get cauliflower micro-cells
            float a = 0.0, w = 0.55, s = 1.0;
            for(int i=0;i<3;++i){
                float v = 1.0 - clamp(worley2(x * s), 0.0, 1.0);
                a += v * w;
                s *= 2.03; w *= 0.55;
            }
            return clamp(a, 0.0, 1.0);
        }

        float2 curl2(float2 xz){
            const float e = 0.02;
            float n1 = noise3(float3(xz.x+e,0.0,xz.y)) - noise3(float3(xz.x-e,0.0,xz.y));
            float n2 = noise3(float3(xz.x,0.0,xz.y+e)) - noise3(float3(xz.x,0.0,xz.y-e));
            float2 v = float2(n2,-n1);
            float len = max(length(v), 1e-5);
            return v/len;
        }

        float hProfile(float y, float b, float t){
            float h = clamp((y-b)/max(1.0,(t-b)), 0.0, 1.0);
            float up = smoothstep(0.03, 0.25, h);
            float dn = 1.0 - smoothstep(0.68, 1.00, h);
            return pow(clamp(up*dn, 0.0, 1.0), 0.80);
        }

        float phaseHG(float mu, float g){
            float g2 = g*g;
            return (1.0 - g2) / max(1e-4, 4.0*3.14159265*pow(1.0 + g2 - 2.0*g*mu, 1.5));
        }

        // Density: low-frequency mass + eroded by micro puff cells
        float densityAt(float3 wp){
            float2 off = domainOffset.xy;
            float  ang = domainRotate;
            float  ca = cos(ang), sa = sin(ang);
            float2 xz = wp.xz + off;
            float2 xzr = float2(xz.x*ca - xz.y*sa, xz.x*sa + xz.y*ca);

            float h01 = hProfile(wp.y, baseY, topY);

            float adv = mix(0.55, 1.55, h01);
            float2 advXY = xzr + wind.xy * adv * (time * 0.0035);

            // Low-frequency cloud mass
            float3 P0 = float3(advXY.x, wp.y, advXY.y) * 0.00110;
            float base = fbm4(P0 * float3(1.0, 0.35, 1.0));

            // Micro puff cells in XZ with slight Y warping
            float yy = wp.y * 0.002 + 5.37;
            float puffs = puffFBM(advXY * max(0.0001, puffScale) + float2(yy, -yy*0.7));

            // Edge shaping and gentle curl to avoid mush
            float3 P1 = float3(advXY.x, wp.y*1.8, advXY.y) * 0.0046 + float3(2.7,0.0,-5.1);
            float erode = fbm4(P1);
            float2 cr = curl2(advXY * 0.0022);

            // Coalescence: micro cells boost mass where they cluster; detail erodes gaps
            float shape = base + puffStrength*(puffs - 0.5) - (1.0 - erode) * (0.38 * detailMul) + 0.10 * cr.x;

            // Coverage mapping and height envelope
            float dens  = clamp( (shape - (1.0 - coverage)) / max(1e-3, coverage), 0.0, 1.0 );
            dens *= hProfile(wp.y + horizonLift*120.0, baseY, topY);

            return dens;
        }

        // -------- fragment --------
        float3 camPos = (u_inverseViewTransform * float4(0,0,0,1)).xyz;
        float3 wp     = _surface.position;
        float3 V      = normalize(wp - camPos);

        // Intersect the slab
        float vdY   = V.y;
        float t0    = (baseY - camPos.y) / max(1e-5, vdY);
        float t1    = (topY - camPos.y) / max(1e-5, vdY);
        float tEnt  = max(0.0, min(t0, t1));
        float tExt  = min(tEnt + 5000.0, max(t0, t1));
        if (tExt <= tEnt + 1e-5) { discard_fragment(); }

        const int   Nbase = 32;
        int   N  = clamp(int(round(float(Nbase) * clamp(stepMul, 0.35, 1.25))), 16, 60);
        float Lm = tExt - tEnt;
        float dt = Lm / float(N);

        // Jitter to reduce banding
        float2 st = _surface.diffuseTexcoord;
        float  j  = fractf(sin(dot(st, float2(12.9898, 78.233))) * 43758.5453);
        float  t  = tEnt + (0.25 + 0.5*j) * dt;

        float3 S  = normalize(sunDirWorld);
        float  mu = clamp(dot(V, S), -1.0, 1.0);
        float  g  = clamp(mieG, 0.0, 0.95);

        float T = 1.0;

        for (int i=0; i<N && T > 0.004; ++i) {
            float3 sp  = camPos + V * t;
            float  rho = densityAt(sp);
            if (rho < 1e-4) { t += dt * 1.6; continue; }

            // Short sun probe
            float Lsun = 1.0;
            {
                const int NL = 4;
                float dL = ((topY - baseY)/max(1,NL)) * 0.90;
                float3 lp = sp;
                for (int j=0; j<NL && Lsun > 0.02; ++j){
                    lp += S * dL;
                    float occ = densityAt(lp);
                    float aL  = 1.0 - exp(-occ * max(0.0, densityMul) * dL * 0.010);
                    Lsun     *= (1.0 - aL);
                }
            }

            float sigma = max(0.0, densityMul) * 0.022;
            float aStep = 1.0 - exp(-rho * sigma * dt);

            float ph    = phaseHG(mu, g);
            float shade = Lsun * exp(-powderK * (1.0 - rho));
            float gain  = clamp(0.85 + 0.35 * ph * shade, 0.0, 1.5);

            T *= (1.0 - aStep * gain);
            t += dt;
        }

        float alpha = clamp(1.0 - T, 0.0, 1.0);
        float3 rgb  = float3(1.0) * alpha;   // premultiplied pure white
        _output.color = float4(rgb, alpha);
        """

        let m = SCNMaterial()
        m.lightingModel = .constant
        m.isDoubleSided = false
        m.cullMode = .front
        m.readsFromDepthBuffer = false
        m.writesToDepthBuffer = false
        m.blendMode = .alpha
        m.transparencyMode = .aOne
        m.shaderModifiers = [.fragment: fragment]

        // Defaults; FirstPersonEngine updates time/sun/wind every frame.
        m.setValue(0.0 as CGFloat, forKey: "time")
        m.setValue(SCNVector3(0.55, 0.20, 0), forKey: "wind")
        m.setValue(SCNVector3(0, 0, 0), forKey: "domainOffset")
        m.setValue(0.0 as CGFloat, forKey: "domainRotate")
        m.setValue(400.0 as CGFloat, forKey: "baseY")
        m.setValue(1400.0 as CGFloat, forKey: "topY")
        m.setValue(0.50 as CGFloat, forKey: "coverage")
        m.setValue(1.10 as CGFloat, forKey: "densityMul")
        m.setValue(0.85 as CGFloat, forKey: "stepMul")
        m.setValue(0.60 as CGFloat, forKey: "mieG")
        m.setValue(2.00 as CGFloat, forKey: "powderK")
        m.setValue(0.14 as CGFloat, forKey: "horizonLift")
        m.setValue(1.00 as CGFloat, forKey: "detailMul")
        m.setValue(0.0045 as CGFloat, forKey: "puffScale")     // smaller => more, tinier puffs
        m.setValue(0.65 as CGFloat, forKey: "puffStrength")    // how much micro-cells influence mass
        m.setValue(SCNVector3(0, 1, 0), forKey: "sunDirWorld")
        return m
    }
}
