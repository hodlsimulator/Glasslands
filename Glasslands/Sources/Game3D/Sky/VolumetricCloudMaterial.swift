//
//  VolumetricCloudMaterial.swift
//  Glasslands
//
//  Created by . . on 10/5/25.
//
//  Binder-free volumetric clouds: pure-white vapour with sun-only shaping.
//  Scattering and self-occlusion affect alpha; RGB stays white (premultiplied).
//  Lightweight march with early-outs and short light probes.
//

import SceneKit
import UIKit

enum VolumetricCloudMaterial {
    @MainActor
    static func makeMaterial() -> SCNMaterial {
        let fragment = """
        #pragma transparent

        // ---- Uniforms (set from Swift) ----
        #pragma arguments
        float time;
        float3 sunDirWorld;
        float3 wind;
        float3 domainOffset;
        float  domainRotate;
        float  baseY;
        float  topY;
        float  coverage;     // 0..1 sky fill
        float  densityMul;   // overall thickness
        float  stepMul;      // 0.35..1.0 march quality
        float  mieG;         // HG forward scatter eccentricity
        float  powderK;      // powder effect strength
        float  horizonLift;  // raises density near horizon slightly
        float  detailMul;    // small-scale erosion amount

        // ---- Noise helpers (hash, value noise, fBm, simple curl) ----
        float fractf(float x){ return x - floor(x); }
        float hash1(float n){ return fractf(sin(n) * 43758.5453123); }

        float noise3(float3 x){
            float3 p = floor(x);
            float3 f = x - p;
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
            for(int i=0;i<4;++i){
                a += noise3(p) * w;
                p  = p * 2.02 + 19.19;
                w *= 0.5;
            }
            return a;
        }

        float2 curl2(float2 xz){
            const float e = 0.02;
            float n1 = noise3(float3(xz.x+e,0.0,xz.y)) - noise3(float3(xz.x-e,0.0,xz.y));
            float n2 = noise3(float3(xz.x,0.0,xz.y+e)) - noise3(float3(xz.x,0.0,xz.y-e));
            float2 v = float2(n2,-n1);
            float len = max(length(v), 1e-5);
            return v/len;
        }

        // Vertical density envelope (flatish in middle, feathered at ends).
        float hProfile(float y, float b, float t){
            float h = clamp((y-b)/max(1.0,(t-b)), 0.0, 1.0);
            float up = smoothstep(0.03, 0.25, h);
            float dn = 1.0 - smoothstep(0.68, 1.00, h);
            return pow(clamp(up*dn, 0.0, 1.0), 0.80);
        }

        // Single-parameter HG phase (used to bias alpha, not colour).
        float phaseHG(float mu, float g){
            float g2 = g*g;
            return (1.0-g2)/max(1e-4, 4.0*3.14159265*pow(1.0 + g2 - 2.0*g*mu, 1.5));
        }

        // Coverage-aware density field: base fBm + erosion + gentle curl advection.
        float densityAt(float3 wp){
            float2 off = domainOffset.xy;
            float  ang = domainRotate;
            float  ca = cos(ang), sa = sin(ang);
            float2 xz = wp.xz + off;
            float2 xzr = float2(xz.x*ca - xz.y*sa, xz.x*sa + xz.y*ca);

            // Height-dependent advection so tops shear a bit faster.
            float adv = mix(0.5, 1.6, hProfile(wp.y, baseY, topY));
            float2 advXY = xzr + wind.xy * adv * (time * 0.0035);

            // Low-frequency mass (streaked in Y so anvils form).
            float3 P0 = float3(advXY.x, wp.y, advXY.y) * 0.00110;
            float base = fbm4(P0 * float3(1.0, 0.35, 1.0));

            // Erosion detail removes mush, leaving cauliflower edges.
            float3 P1 = float3(advXY.x, wp.y*1.8, advXY.y) * 0.0046 + float3(2.7,0.0,-5.1);
            float erode = fbm4(P1);

            float2 cr = curl2(advXY * 0.0022);
            float curlBump = 0.10 * cr.x;

            // Coverage mapping: shifts threshold so higher coverage fills in.
            // Erosion term carves out gaps; detailMul scales its influence.
            float shape = base - (1.0 - erode) * (0.42 * detailMul) + curlBump;
            float dens  = clamp( (shape - (1.0 - coverage)) / max(1e-3, coverage), 0.0, 1.0 );

            // Height envelope + slight near-horizon lift.
            dens *= hProfile(wp.y + horizonLift*120.0, baseY, topY);
            return dens;
        }

        #pragma body
        // Camera + view ray.
        float3 camPos = (u_inverseViewTransform * float4(0,0,0,1)).xyz;
        float3 wp     = _surface.position;
        float3 V      = normalize(wp - camPos);

        // Reject rays leaving the cloud slab from below.
        if (V.y < -0.01 && camPos.y < baseY - 2.0) discard_fragment();

        // Slab intersection.
        float vdY   = V.y;
        float t0    = (baseY - camPos.y) / max(1e-5, vdY);
        float t1    = (topY - camPos.y) / max(1e-5, vdY);
        float tEnt  = max(0.0, min(t0, t1));
        float tExt  = min(tEnt + 4500.0, max(t0, t1));
        if (tExt <= tEnt + 1e-5) discard_fragment();

        // March quality.
        const int Nbase = 24;
        int   N  = clamp(int(round(float(Nbase) * clamp(stepMul, 0.35, 1.0))), 12, 36);
        float Lm = tExt - tEnt;
        float dt = Lm / float(N);

        // Tiny per-pixel jitter to reduce banding.
        float2 st = _surface.diffuseTexcoord;
        float  j  = fractf(sin(dot(st, float2(12.9898, 78.233))) * 43758.5453);
        float  t  = tEnt + (0.25 + 0.5*j) * dt;

        float3 S  = normalize(sunDirWorld);
        float  mu = clamp(dot(V, S), -1.0, 1.0);
        float  g  = clamp(mieG, 0.0, 0.95);

        float T = 1.0; // transmittance along the view ray

        // Raymarch.
        for (int i=0; i<N && T > 0.005; ++i) {
            float3 sp  = camPos + V * t;
            float  rho = densityAt(sp);

            // Empty-space skipping.
            if (rho < 1e-4) { t += dt * 1.6; continue; }

            // Short light probe for self-occlusion along sun direction.
            float Lsun = 1.0;
            {
                const int NL = 3;
                float dL = ((topY - baseY)/max(1,NL)) * 0.90;
                float3 lp = sp;
                for (int j=0; j<NL && Lsun > 0.02; ++j){
                    lp += S * dL;
                    float occ = densityAt(lp);
                    float aL  = 1.0 - exp(-occ * max(0.0, densityMul) * dL * 0.010);
                    Lsun     *= (1.0 - aL);
                }
            }

            // Per-step extinction.
            float sigma = max(0.0, densityMul) * 0.022;
            float aStep = 1.0 - exp(-rho * sigma * dt);

            // Phase & powder bias pushed into alpha so RGB can stay pure white.
            float ph    = phaseHG(mu, g);
            float shade = Lsun * exp(-powderK * (1.0 - rho));
            float gain  = clamp(0.85 + 0.35 * ph * shade, 0.0, 1.5);

            // Update transmittance with biased step opacity.
            T *= (1.0 - aStep * gain);

            t += dt;
        }

        // Pure-white premultiplied output.
        float alpha = clamp(1.0 - T, 0.0, 1.0);
        float3 rgb  = float3(1.0) * alpha;   // premultiplied white
        _output.color = float4(rgb, alpha);
        """

        let m = SCNMaterial()
        m.lightingModel = .constant
        m.isDoubleSided = false
        m.cullMode = .front                // render inside a skydome
        m.readsFromDepthBuffer = false
        m.writesToDepthBuffer = false
        m.blendMode = .alpha
        m.transparencyMode = .aOne         // premultiplied alpha
        m.shaderModifiers = [.fragment: fragment]

        // Safe defaults; engine updates at runtime.
        m.setValue(NSNumber(value: 0.0), forKey: "time")
        m.setValue(SCNVector3(0.55, 0.20, 0), forKey: "wind")
        m.setValue(SCNVector3(0, 0, 0), forKey: "domainOffset")
        m.setValue(NSNumber(value: 0.0), forKey: "domainRotate")
        m.setValue(NSNumber(value: 400.0), forKey: "baseY")
        m.setValue(NSNumber(value: 1400.0), forKey: "topY")
        m.setValue(NSNumber(value: 0.46), forKey: "coverage")
        m.setValue(NSNumber(value: 1.10), forKey: "densityMul")
        m.setValue(NSNumber(value: 0.80), forKey: "stepMul")
        m.setValue(NSNumber(value: 0.60), forKey: "mieG")
        m.setValue(NSNumber(value: 2.00), forKey: "powderK")
        m.setValue(NSNumber(value: 0.14), forKey: "horizonLift")
        m.setValue(NSNumber(value: 1.00), forKey: "detailMul")
        m.setValue(SCNVector3(0, 1, 0), forKey: "sunDirWorld")
        return m
    }
}
