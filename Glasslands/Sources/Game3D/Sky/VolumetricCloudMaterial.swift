//
//  VolumetricCloudMaterial.swift
//  Glasslands
//
//  Created by . . on 10/5/25.
//
//  In-scene volumetric cumulus: fast ray-march, height-shaped FBM, domain warping,
//  soft single-scattering, powder effect, wind advection. Fragment-only shader
//  modifier; draws on an inward-facing sphere around the camera.
//

import SceneKit
import UIKit

enum VolumetricCloudMaterial {

    @MainActor
    static func makeTemplate() -> SCNMaterial {
        let frag = """
        #pragma transparent
        #pragma arguments
        float3 cameraPos;      // world-space camera position (set from Swift)
        float3 sunDirWorld;
        float3 sunTint;
        float   time;           // seconds
        float3  wind;           // use .xy for XZ
        float   baseY;          // world metres
        float   topY;           // world metres
        float   coverage;       // 0..1
        float   densityMul;     // scalar multiplier
        float   stepMul;        // world step scale
        float   horizonLift;    // small lift near horizon

        // ---- mini stdlib shims (GL/Metal friendly) ----
        float saturate1(float x) { return clamp(x, 0.0, 1.0); }
        float3 saturate3(float3 v){ return clamp(v, float3(0.0), float3(1.0)); }
        float frac1(float x) { return x - floor(x); }
        float lerp1(float a, float b, float t){ return a + (b - a) * t; }

        // ---- noise ----
        float hash1(float n) { return frac1(sin(n) * 43758.5453123); }

        float noise3(float3 x) {
            float3 p = floor(x);
            float3 f = x - p;
            f = f*f*(3.0 - 2.0*f);

            float n = dot(p, float3(1.0, 57.0, 113.0));

            float n000 = hash1(n +   0.0);
            float n100 = hash1(n +   1.0);
            float n010 = hash1(n +  57.0);
            float n110 = hash1(n +  58.0);
            float n001 = hash1(n + 113.0);
            float n101 = hash1(n + 114.0);
            float n011 = hash1(n + 170.0);
            float n111 = hash1(n + 171.0);

            float nx00 = lerp1(n000, n100, f.x);
            float nx10 = lerp1(n010, n110, f.x);
            float nx01 = lerp1(n001, n101, f.x);
            float nx11 = lerp1(n011, n111, f.x);

            float nxy0 = lerp1(nx00, nx10, f.y);
            float nxy1 = lerp1(nx01, nx11, f.y);
            return lerp1(nxy0, nxy1, f.z);
        }

        float fbm(float3 p) {
            float a = 0.0;
            float w = 0.5;
            // fixed-count for mobile compilers
            for (int i = 0; i < 5; i++) {
                a += noise3(p) * w;
                p = p * 2.01 + 19.0;
                w *= 0.5;
            }
            return a;
        }

        float2 curl2(float2 xz) {
            float e = 0.01;
            float n1 = noise3(float3(xz.x + e, 0.0, xz.y)) - noise3(float3(xz.x - e, 0.0, xz.y));
            float n2 = noise3(float3(xz.x, 0.0, xz.y + e)) - noise3(float3(xz.x, 0.0, xz.y - e));
            float2 v = float2(n2, -n1);
            float len = max(length(v), 1e-5);
            return v / len;
        }

        float heightProfile(float y) {
            float h = saturate1((y - baseY) / max(1.0, (topY - baseY)));
            float up = smoothstep(0.02, 0.25, h);
            float dn = 1.0 - smoothstep(0.68, 1.00, h);
            return pow(up * dn, 0.78);
        }

        float densityAt(float3 wp) {
            float3 q = wp * 0.0011;

            float2 flow = wind.xy * 0.0012 + 1.3 * curl2(q.xz + time * 0.07);
            q.xz += flow * time;

            float3 warp = float3(fbm(q*1.7 + 31.0), fbm(q*1.8 + 57.0), fbm(q*1.9 + 83.0));
            q += (warp - 0.5) * 0.48;

            float shape  = fbm(q * 0.8);
            float detail = fbm(q * 2.8) * 0.55;
            float prof   = heightProfile(wp.y);

            float thr = lerp1(0.65, 0.45, saturate1(coverage));
            float d = (shape * 0.95 + detail * 0.65) * prof - thr + 0.08;

            return smoothstep(0.0, 0.70, d);
        }

        #pragma body

        // World-space fragment position on the sky sphere
        float3 Pw = _surface.position.xyz;

        // Per-pixel ray: camera → fragment
        float3 ro = cameraPos;
        float3 rd = normalize(Pw - ro);

        // Intersect horizontal slab [baseY, topY]
        float denom = rd.y;
        if (abs(denom) < 1e-4) { _output.color = float4(0.0,0.0,0.0,0.0); return; }

        float tb = (baseY - ro.y) / denom;
        float tt = (topY  - ro.y) / denom;
        float t0 = min(tb, tt);
        float t1 = max(tb, tt);
        if (t1 <= 0.0) { _output.color = float4(0.0,0.0,0.0,0.0); return; }
        t0 = max(t0, 0.0);

        // March (fixed upper bound; early-exit)
        const int MAX_STEPS = 32;
        float baseStep = 140.0 * stepMul;
        float grazing  = clamp(1.0 - abs(rd.y), 0.0, 1.0);
        float worldStep = baseStep * lerp1(1.0, 1.8, grazing);

        float3 sunW = normalize(sunDirWorld);
        float3 acc  = float3(0.0,0.0,0.0);
        float  trans = 1.0;

        float horizonBoost = horizonLift * smoothstep(0.0, 0.15, grazing);
        float jitter = frac1(dot(Pw, float3(1.0, 57.0, 113.0))) * worldStep;

        float t = t0 + jitter;
        for (int i = 0; i < MAX_STEPS; ++i) {
            float3 p = ro + rd * t;
            if (t > t1) break;

            float d = densityAt(p) * densityMul;

            if (d > 1e-3) {
                float3 ps = p + sunW * 300.0;
                float dl  = densityAt(ps);
                float shade = 0.55 + 0.45 * smoothstep(0.15, 0.95, 1.0 - dl);

                float powder = 1.0 - exp(-2.2 * d);

                float3 localCol = float3(1.0,1.0,1.0) * (0.70 + 0.30 * shade + horizonBoost);
                localCol = saturate3(localCol);

                float a = saturate1(d * (worldStep / 220.0));
                float3 add = localCol * (powder * a);

                acc += trans * add;
                trans *= (1.0 - a);
                if (trans < 0.015) break;
            }

            t += worldStep;
        }

        float alpha = saturate1(1.0 - trans);
        float3 outRGB = acc + sunTint * acc * 0.08;
        _output.color = float4(outRGB, alpha);
        """

        let m = SCNMaterial()
        m.lightingModel = .constant
        m.isDoubleSided = true
        m.blendMode = .alpha
        m.transparencyMode = .aOne
        m.readsFromDepthBuffer = false
        m.writesToDepthBuffer = false
        m.shaderModifiers = [.fragment: frag]

        // Defaults (swift updates per-frame)
        m.setValue(SCNVector3(0, 1, 0), forKey: "sunDirWorld")
        m.setValue(SCNVector3(1.00, 0.94, 0.82), forKey: "sunTint")
        m.setValue(0.0 as CGFloat, forKey: "time")
        m.setValue(SCNVector3(6.0, 2.0, 0.0), forKey: "wind")
        m.setValue(1350.0 as CGFloat, forKey: "baseY")
        m.setValue(2500.0 as CGFloat, forKey: "topY")
        m.setValue(0.55 as CGFloat, forKey: "coverage")
        m.setValue(1.00 as CGFloat, forKey: "densityMul")
        m.setValue(1.00 as CGFloat, forKey: "stepMul")
        m.setValue(0.16 as CGFloat, forKey: "horizonLift")
        // cameraPos is set every frame from Swift
        return m
    }
}
