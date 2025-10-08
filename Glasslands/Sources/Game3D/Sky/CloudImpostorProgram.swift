//
//  CloudImpostorProgram.swift
//  Glasslands
//
//  Created by . . on 10/7/25.
//
//  Volumetric cloud impostors using a fragment shader modifier only.
//  No SCNProgram, no techniques, no binders. Anchors sampling to the quad’s UVs
//  so the vapour moves with its impostor when the camera pans/rotates.
//

import SceneKit
import simd
import UIKit

enum CloudImpostorProgram {
    static func makeMaterial(halfWidth: CGFloat, halfHeight: CGFloat) -> SCNMaterial {
        let frag = """
        #pragma transparent

        // -------- uniforms --------
        #pragma arguments
        float impostorHalfW;   // local half width (geometry units)
        float impostorHalfH;   // local half height
        float stepMul;         // 0.35..1.25 (quality / cost)
        float densityMul;      // base extinction scale
        float coverage;        // 0..1
        float puffScale;       // micro puff scale

        // -------- helpers --------
        #pragma declarations
        inline float hash1(float n) { return fract(sin(n) * 43758.5453123); }
        inline float hash12(float2 p) { return fract(sin(dot(p, float2(127.1,311.7))) * 43758.5453123); }

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

        inline float puffFBM2(float2 x){
            float a = 0.0, w = 0.6, s = 1.0;
            float v = 1.0 - clamp(worley2(x*s), 0.0, 1.0);
            a += v*w; s *= 2.03; w *= 0.55;
            v = 1.0 - clamp(worley2(x*s), 0.0, 1.0);
            a += v*w;
            return clamp(a, 0.0, 1.0);
        }

        // 2.5D density anchored to UVs (quad-local)
        inline float densityUV(float2 uv, float z, float coverage, float puffScale) {
            // Macro breakup
            float2 mCoord = uv * 0.65 + float2(z*0.15, -z*0.09);
            float macro = 1.0 - clamp(worley2(mCoord * 1.40), 0.0, 1.0);

            // Base field
            float3 bP = float3(uv * 1.65, z);
            float base = noise3(bP * 2.10);

            // Micro puffs
            float2 pCoord = uv * max(1e-4, puffScale * 185.0) + float2(z*0.33, -z*0.21);
            float puffs = puffFBM2(pCoord);

            // Coverage gating
            float coverInv = 1.0 - clamp(coverage, 0.0, 1.0);
            float shape = mix(base, puffs, 0.55);
            float thLo = clamp(coverInv - 0.22, 0.0, 1.0);
            float thHi = clamp(coverInv + 0.26, 0.0, 1.0);
            float t    = smoothstep(thLo, thHi, shape) * macro;

            return pow(clamp(t, 0.0, 1.0), 0.90);
        }

        // -------- fragment body --------
        #pragma body
        // Quad-local UV in [-1,1], anchored to the impostor
        float2 uv = _surface.diffuseTexcoord * 2.0 - 1.0;

        // Soft edge falloff in quad space to hide the card
        float2 halfs = float2(max(0.0001, impostorHalfW), max(0.0001, impostorHalfH));
        float2 e = abs(uv);
        float edge = smoothstep(1.0, 0.92, 1.0 - max(e.x, e.y));

        // Slab thickness and step count (view-aligned 2.5D march)
        float Lm = 1.0;                            // nominal thickness in UV-depth units
        int   N  = clamp(int(round(12.0 * clamp(stepMul, 0.35, 1.25))), 6, 24);
        float dt = Lm / float(N);

        // Per-fragment jitter to reduce banding
        float j = fract(sin(dot(uv, float2(12.9898,78.233))) * 43758.5453);
        float t = (0.25 + 0.5*j) * dt;

        float T = 1.0;
        for (int i=0; i<N && T>0.004; ++i) {
            float z = -0.5 + t;                   // symmetric slab about the plane
            float d = densityUV(uv, z, coverage, max(1e-4, puffScale)) * edge;
            if (d > 0.0015) {
                float aStep = 1.0 - exp(-max(0.0, densityMul) * 0.040 * d * dt);
                T *= (1.0 - aStep);
            }
            t += dt;
        }

        float alpha = clamp(1.0 - T, 0.0, 1.0);
        float3 rgb  = float3(1.0) * alpha;       // premultiplied white
        _output.color = float4(rgb, alpha);
        """

        let m = SCNMaterial()
        m.lightingModel = .constant
        m.isDoubleSided = false
        m.cullMode = .back
        m.readsFromDepthBuffer = false
        m.writesToDepthBuffer = false
        m.blendMode = .alpha
        m.transparencyMode = .aOne
        m.shaderModifiers = [.fragment: frag]

        // Defaults (fast, soft volumetric look)
        m.setValue(halfWidth,  forKey: "impostorHalfW")
        m.setValue(halfHeight, forKey: "impostorHalfH")
        m.setValue(0.75 as CGFloat, forKey: "stepMul")
        m.setValue(1.05 as CGFloat, forKey: "densityMul")
        m.setValue(0.42 as CGFloat, forKey: "coverage")
        m.setValue(0.0045 as CGFloat, forKey: "puffScale")

        m.diffuse.contents = UIColor.white
        m.multiply.contents = UIColor.white
        return m
    }
}
