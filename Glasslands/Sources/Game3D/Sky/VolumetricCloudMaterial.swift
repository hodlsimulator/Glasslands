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
        float3 sunDirWorld;
        float3 sunTint;
        float   time;           // seconds
        float3  wind;           // XZ in .xy (metres/sec), .z unused
        float   baseY;          // world metres
        float   topY;           // world metres
        float   coverage;       // 0..1
        float   densityMul;     // scale
        float   stepMul;        // step scale
        float   horizonLift;    // slight lift near horizon

        inline float saturate(float x) { return clamp(x, 0.0, 1.0); }
        inline float3 saturate3(float3 v){ return clamp(v, float3(0), float3(1)); }

        inline float hash11(float p) {
            p = fract(p * 0.1031);
            p *= p + 33.33;
            p *= p + p;
            return fract(p);
        }

        inline float hash31(float3 p) {
            p = fract(p * 0.1031);
            p += dot(p, p.yzx + 33.33);
            return fract((p.x + p.y) * p.z);
        }

        // 3D value noise
        inline float vnoise3(float3 p) {
            float3 i = floor(p), f = fract(p);
            float n000 = hash31(i + float3(0,0,0));
            float n100 = hash31(i + float3(1,0,0));
            float n010 = hash31(i + float3(0,1,0));
            float n110 = hash31(i + float3(1,1,0));
            float n001 = hash31(i + float3(0,0,1));
            float n101 = hash31(i + float3(1,0,1));
            float n011 = hash31(i + float3(0,1,1));
            float n111 = hash31(i + float3(1,1,1));
            float3 u = f*f*(3.0 - 2.0*f);
            float nx00 = mix(n000, n100, u.x);
            float nx10 = mix(n010, n110, u.x);
            float nx01 = mix(n001, n101, u.x);
            float nx11 = mix(n011, n111, u.x);
            float nxy0 = mix(nx00, nx10, u.y);
            float nxy1 = mix(nx01, nx11, u.y);
            return mix(nxy0, nxy1, u.z);
        }

        inline float fbm3(float3 p) {
            float a = 0.0;
            float w = 0.5;
            for (int i=0; i<5; ++i) {
                a += vnoise3(p) * w;
                p = p * 2.06 + 17.0;
                w *= 0.5;
            }
            return a;
        }

        // Curl-like 2D field (for gentle drift)
        inline float2 curl2(float2 xz) {
            float e = 0.005;
            float n1 = vnoise3(float3(xz.x + e, 0.0, xz.y)) - vnoise3(float3(xz.x - e, 0.0, xz.y));
            float n2 = vnoise3(float3(xz.x, 0.0, xz.y + e)) - vnoise3(float3(xz.x, 0.0, xz.y - e));
            float2 v = float2(n2, -n1);
            float len = max(length(v), 1e-5);
            return v / len;
        }

        // Bell-like height profile for cumulus
        inline float heightProfile(float y, float baseY, float topY) {
            float h = saturate((y - baseY) / max(1.0, (topY - baseY)));
            float b = smoothstep(0.02, 0.25, h) * (1.0 - smoothstep(0.68, 1.00, h));
            return pow(b, 0.78);
        }

        // Density field
        inline float densityAt(float3 wp, float baseY, float topY, float cov, float t, float3 wind) {
            float3 q = wp * 0.0011;
            float2 flow = wind.xy * 0.0012 + 1.3 * curl2(q.xz + t * 0.07);
            q.xz += flow * t;

            float3 warp = float3(fbm3(q*1.7 + 31.0), fbm3(q*1.8 + 57.0), fbm3(q*1.9 + 83.0));
            q += (warp - 0.5) * 0.48;

            float shape  = fbm3(q * 0.8);
            float detail = fbm3(q * 2.8) * 0.55;
            float prof   = heightProfile(wp.y, baseY, topY);

            float thr = mix(0.65, 0.45, saturate(cov));
            float d = (shape * 0.95 + detail * 0.65) * prof - thr + 0.08;

            return smoothstep(0.00, 0.70, d);
        }

        #pragma body

        // Camera world position
        float3 ro = (scn_frame.inverseViewTransform * float4(0.0, 0.0, 0.0, 1.0)).xyz;
        // Fragment world position (on the big sky sphere)
        float3 Pw = _surface.position.xyz;
        // Ray from camera through this pixel
        float3 rd = normalize(Pw - ro);

        // Intersect the horizontal slab [baseY, topY]
        float denom = rd.y;
        if (abs(denom) < 1e-4) discard_fragment();

        float tb = (baseY - ro.y) / denom;
        float tt = (topY  - ro.y) / denom;
        float t0 = min(tb, tt);
        float t1 = max(tb, tt);
        if (t1 <= 0.0) discard_fragment();
        t0 = max(t0, 0.0);

        // March setup
        float baseStep = 140.0 * stepMul;
        float grazing  = clamp(1.0 - abs(rd.y), 0.0, 1.0);   // 0 overhead → 1 horizon
        float worldStep = baseStep * mix(1.0, 1.8, grazing);
        int   maxSteps  = min(36, max(10, int(ceil((t1 - t0) / worldStep) + 2.0)));

        float3 sunW = normalize(sunDirWorld);
        float3 acc  = float3(0.0);
        float  trans = 1.0;

        float horizonBoost = horizonLift * smoothstep(0.0, 0.15, grazing);
        float jitter = hash11(dot(Pw, float3(1.0, 57.0, 113.0))) * worldStep;

        float t = t0 + jitter;
        for (int i = 0; i < maxSteps; ++i) {
            float3 p = ro + rd * t;
            if (t > t1) break;

            float d = densityAt(p, baseY, topY, coverage, time, wind) * densityMul;

            if (d > 1e-3) {
                float3 ps = p + sunW * 300.0;
                float dl  = densityAt(ps, baseY, topY, coverage, time, wind);
                float shade = 0.55 + 0.45 * smoothstep(0.15, 0.95, 1.0 - dl);

                float powder = 1.0 - exp(-2.2 * d);

                float3 localCol = float3(1.0) * (0.70 + 0.30 * shade + horizonBoost);
                localCol = saturate3(localCol);

                float a = saturate(d * (worldStep / 220.0));
                float3 add = localCol * (powder * a);

                acc += trans * add;
                trans *= (1.0 - a);
                if (trans < 0.015) break;
            }

            t += worldStep;
        }

        float alpha = saturate(1.0 - trans);
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
        return m
    }
}
