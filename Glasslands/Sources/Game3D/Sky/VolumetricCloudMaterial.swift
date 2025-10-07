//
//  VolumetricCloudMaterial.swift
//  Glasslands
//
//  Created by . . on 10/5/25.
//
//  Binder-free volumetric clouds using a fragment shader-modifier.
//  Lit ONLY by the sun (HG single scattering + compact sun-ray occlusion).
//  Drawn on an inside-out sphere (cull .front), alpha-blended over the sky.
//

import SceneKit
import UIKit

enum VolumetricCloudMaterial {

    static func makeMaterial() -> SCNMaterial {
        let fragment = """
        #pragma transparent

        // -------- Arguments (set via SCNMaterial.setValue) --------
        #pragma arguments
        float   time;
        float3  sunDirWorld;
        float3  sunTint;

        float3  wind;            // x,y used
        float3  domainOffset;    // x,y used
        float   domainRotate;

        float   baseY;
        float   topY;
        float   coverage;        // 0..1
        float   densityMul;      // 0..+
        float   stepMul;         // 0.25..1.5 (quality/perf)
        float   mieG;            // 0..0.95
        float   powderK;         // 0..3
        float   horizonLift;     // 0..1
        float   detailMul;       // 0..+

        // -------- Helpers --------
        float frac(float x) { return x - floor(x); }
        float hash1(float n) { return frac(sin(n) * 43758.5453123); }

        float noise3(float3 x){
            float3 p = floor(x);
            float3 f = x - p;
            f = f * f * (3.0 - 2.0 * f);

            const float3 off = float3(1.0, 57.0, 113.0);
            float n = dot(p, off);

            float n000 = hash1(n + 0.0);
            float n100 = hash1(n + 1.0);
            float n010 = hash1(n + 57.0);
            float n110 = hash1(n + 58.0);
            float n001 = hash1(n + 113.0);
            float n101 = hash1(n + 114.0);
            float n011 = hash1(n + 170.0);
            float n111 = hash1(n + 171.0);

            float nx00 = mix(n000, n100, f.x);
            float nx10 = mix(n010, n110, f.x);
            float nx01 = mix(n001, n101, f.x);
            float nx11 = mix(n011, n111, f.x);

            float nxy0 = mix(nx00, nx10, f.y);
            float nxy1 = mix(nx01, nx11, f.y);
            return mix(nxy0, nxy1, f.z);
        }

        float fbm5(float3 p){
            float a = 0.0, w = 0.5;
            for (int i = 0; i < 5; ++i) {
                a += noise3(p) * w;
                p = p * 2.02 + 19.19;
                w *= 0.5;
            }
            return a;
        }

        float2 curl2(float2 xz){
            const float e = 0.02;
            float n1 = noise3(float3(xz.x + e, 0.0, xz.y)) - noise3(float3(xz.x - e, 0.0, xz.y));
            float n2 = noise3(float3(xz.x, 0.0, xz.y + e)) - noise3(float3(xz.x, 0.0, xz.y - e));
            float2 v = float2(n2, -n1);
            float len = max(length(v), 1e-5);
            return v / len;
        }

        float heightProfile(float y, float baseY, float topY){
            float h = clamp((y - baseY) / max(1.0, (topY - baseY)), 0.0, 1.0);
            float up = smoothstep(0.03, 0.25, h);
            float dn = 1.0 - smoothstep(0.68, 1.00, h);
            return pow(clamp(up * dn, 0.0, 1.0), 0.80);
        }

        float phaseHG(float cosTheta, float g){
            float g2 = g * g;
            float denom = pow(1.0 + g2 - 2.0 * g * cosTheta, 1.5);
            return (1.0 - g2) / max(1e-4, 4.0 * 3.1415926536 * denom);
        }

        float powderTerm(float occult, float k) {
            return exp(-k * clamp(occult, 0.0, 1.0));
        }

        // Density field consistent with billboard look
        float densityAt(float3 wp){
            float2 domOff = domainOffset.xy;
            float  ang    = domainRotate;
            float  ca = cos(ang), sa = sin(ang);

            float2 xz   = wp.xz + domOff;
            float2 xzr  = float2(xz.x*ca - xz.y*sa, xz.x*sa + xz.y*ca);

            // Altitude-dependent advection factor
            float h01 = heightProfile(wp.y, baseY, topY);
            float adv = mix(0.5, 1.5, h01);
            float2 advXY = xzr + wind.xy * adv * (time * 0.0035);

            // Base mass
            float3 P0 = float3(advXY.x, wp.y, advXY.y) * 0.00115;
            float base = fbm5(P0 * float3(1.0, 0.35, 1.0));

            // Cauliflower detail
            float3 P1 = float3(advXY.x, wp.y * 1.8, advXY.y) * 0.0046 + float3(2.7, 0.0, -5.1);
            float detail = fbm5(P1);

            float2 curl = curl2(advXY * 0.0022);
            float edge  = base + (detailMul * 0.55) * (detail - 0.45) + 0.10 * curl.x;

            float dens = clamp( (edge - (1.0 - coverage)) / max(1e-3, coverage), 0.0, 1.0 );
            dens *= heightProfile(wp.y + horizonLift * 120.0, baseY, topY);
            return clamp(dens, 0.0, 1.0);
        }

        #pragma body
        // Camera/world vectors
        float3 camPos = (u_inverseViewTransform * float4(0.0, 0.0, 0.0, 1.0)).xyz;
        float3 worldPos = _surface.position;
        float3 viewDir = normalize(worldPos - camPos);

        // Slab intersection [baseY, topY]
        float vdY = viewDir.y;
        float t0 = (baseY - camPos.y) / max(1e-5, vdY);
        float t1 = (topY  - camPos.y) / max(1e-5, vdY);
        float tEnter = max(0.0, min(t0, t1));
        float tExit  = min(tEnter + 6000.0, max(t0, t1));

        // If we don't pass through the layer, keep transparent
        if (tExit <= tEnter + 1e-5) {
            discard_fragment();
        }

        float3 sunW = normalize(sunDirWorld);
        float sunDotV = clamp(dot(viewDir, sunW), -1.0, 1.0);
        float gHG     = clamp(mieG, -0.99, 0.99);
        float powder  = max(0.0, powderK);
        float  densK  = max(0.0, densityMul);
        float  qMul   = clamp(stepMul, 0.25, 1.5);

        // Background sky will show through via alpha, so no hard gradient here.
        float  T = 1.0;         // transmittance
        float3 C = float3(0.0); // in-scattered radiance

        const int   Nbase  = 48;
        int   Nsteps = clamp(int(round(float(Nbase) * qMul)), 16, 84);
        float marchLen = max(1e-3, tExit - tEnter);
        float dt = marchLen / float(Nsteps);

        float t = tEnter + 0.5 * dt;
        for (int i = 0; i < Nsteps && T > 0.0035; ++i, t += dt) {
            float3 sp = camPos + viewDir * t;

            float rho = densityAt(sp);
            if (rho <= 1e-4) { continue; }

            // Short, cheap sun-ray occlusion
            float lightT = 1.0;
            {
                const int NL = 6;
                float dL = ((topY - baseY) / max(1, NL)) * 0.9;
                float3 lp = sp;
                for (int j = 0; j < NL && lightT > 0.01; ++j) {
                    lp += sunW * dL;
                    float occ = densityAt(lp);
                    float aL  = 1.0 - exp(-occ * densK * dL * 0.012);
                    lightT *= (1.0 - aL);
                }
            }

            float sigma = densK * 0.022;
            float a = 1.0 - exp(-rho * sigma * dt);
            float ph = phaseHG(sunDotV, gHG);
            float pd = powderTerm(1.0 - rho, powder);
            float3 sunRGB = sunTint;

            float3 S = sunRGB * lightT * ph * pd;
            C += T * a * S;
            T *= (1.0 - a);
        }

        float alpha = clamp(1.0 - T, 0.0, 1.0);
        float3 col = clamp(C, 0.0, 1.0);

        _output.color = float4(col, alpha);
        """

        let m = SCNMaterial()
        m.lightingModel = .constant
        m.isDoubleSided = false
        m.cullMode = .front               // render interior of skydome
        m.readsFromDepthBuffer = false
        m.writesToDepthBuffer = false
        m.blendMode = .alpha
        m.shaderModifiers = [.fragment: fragment]

        // Defaults: engine updates many of these each frame
        m.setValue(NSNumber(value: 0.0), forKey: "time")
        m.setValue(SCNVector3(0, 1, 0), forKey: "sunDirWorld")
        m.setValue(SCNVector3(1, 1, 1), forKey: "sunTint")

        m.setValue(SCNVector3(0.60, 0.20, 0), forKey: "wind")
        m.setValue(SCNVector3(0, 0, 0), forKey: "domainOffset")
        m.setValue(NSNumber(value: 0.0), forKey: "domainRotate")

        m.setValue(NSNumber(value: 400.0), forKey: "baseY")
        m.setValue(NSNumber(value: 1400.0), forKey: "topY")
        m.setValue(NSNumber(value: 0.42), forKey: "coverage")
        m.setValue(NSNumber(value: 1.15), forKey: "densityMul")
        m.setValue(NSNumber(value: 0.90), forKey: "stepMul")
        m.setValue(NSNumber(value: 0.60), forKey: "mieG")
        m.setValue(NSNumber(value: 2.20), forKey: "powderK")
        m.setValue(NSNumber(value: 0.14), forKey: "horizonLift")
        m.setValue(NSNumber(value: 1.10), forKey: "detailMul")

        return m
    }
}
