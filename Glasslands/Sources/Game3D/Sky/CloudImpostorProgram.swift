//
//  CloudImpostorProgram.swift
//  Glasslands
//
//  Created by . . on 10/7/25.
//
//  Volumetric cloud impostors using a fragment shader modifier only.
//  No SCNProgram/technique/binders. Density anchors to the impostor.
//  Corrected edge feather (centre stays dense), thicker slab, and fuller fill.
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
        float impostorHalfW;    // local half width (geometry units)
        float impostorHalfH;    // local half height
        float stepMul;          // 0.35..1.25 (quality/cost)
        float densityMul;       // base extinction scale
        float coverage;         // 0..1 macro gate
        float puffScale;        // micro puff scale
        float thickness;        // slab thickness in UV-depth units
        float edgeFeather;      // soft rim width (0..0.5)
        float edgeCut;          // extra hard cut beyond feather (0..0.5)
        float edgeNoiseAmp;     // rim wobble amount (0..0.2)

        // -------- helpers --------
        #pragma declarations
        inline float hash1(float n) { return fract(sin(n) * 43758.5453123); }
        inline float hash12(float2 p){ return fract(sin(dot(p, float2(127.1,311.7))) * 43758.5453123); }

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

        // 2.5D density anchored to quad-local UV
        inline float densityUV(float2 uv, float z, float coverage, float puffScale) {
            float2 mCoord = uv * 0.60 + float2(z*0.15, -z*0.09);
            float macro = 1.0 - clamp(worley2(mCoord * 1.25), 0.0, 1.0);

            float3 bP = float3(uv * 1.45, z);
            float base = noise3(bP * 2.00);

            float2 pCoord = uv * max(1e-4, puffScale * 165.0) + float2(z*0.33, -z*0.21);
            float puffs = puffFBM2(pCoord);

            float coverInv = 1.0 - clamp(coverage, 0.0, 1.0);
            float shape = mix(base, puffs, 0.55);
            float thLo = clamp(coverInv - 0.18, 0.0, 1.0);
            float thHi = clamp(coverInv + 0.24, 0.0, 1.0);
            float t    = smoothstep(thLo, thHi, shape) * macro;

            return pow(clamp(t, 0.0, 1.0), 0.90);
        }

        // -------- fragment body --------
        #pragma body
        // Quad UV in [-1,1]
        float2 uv = _surface.diffuseTexcoord * 2.0 - 1.0;

        // Elliptical mapping to respect plane aspect
        float2 halfs = float2(max(0.0001, impostorHalfW), max(0.0001, impostorHalfH));
        float s = max(halfs.x, halfs.y);
        float2 uvE = uv * halfs / s;

        // Noisy rim radius
        float r = length(uvE);                          // 0 centre … ~1 rim
        float nEdge = noise3(float3(uvE * 3.10, 0.0));  // 0..1
        float rWobble = (nEdge * 2.0 - 1.0) * edgeNoiseAmp;
        float rDist = r + rWobble;

        // Hard cut just outside the feather band
        float cutR = 1.0 - clamp(edgeCut, 0.0, 0.49);
        if (rDist >= cutR) { discard_fragment(); }

        // Correct feather: fades only near rim (centre stays dense)
        float featherR0 = cutR - clamp(edgeFeather, 0.0, 0.49);
        float edgeSoft  = smoothstep(featherR0, cutR, rDist);
        float edgeMask  = 1.0 - edgeSoft;

        // Slab thickness / steps
        float Lm = max(0.2, thickness);
        int   N  = clamp(int(round(16.0 * clamp(stepMul, 0.35, 1.25))), 6, 32);
        float dt = Lm / float(N);

        // Per-fragment jitter
        float j = fract(sin(dot(uvE, float2(12.9898,78.233))) * 43758.5453);
        float t = (0.25 + 0.5*j) * dt;

        // March
        float T = 1.0;
        for (int i=0; i<N && T>0.004; ++i) {
            float z = -0.5*Lm + t;                      // symmetric about plane
            float d = densityUV(uvE, z, coverage, max(1e-4, puffScale)) * edgeMask;
            if (d > 0.0010) {
                float aStep = 1.0 - exp(-max(0.0, densityMul) * 0.045 * d * dt);
                T *= (1.0 - aStep);
            }
            t += dt;
        }

        float alpha = clamp(1.0 - T, 0.0, 1.0);
        float3 rgb  = float3(1.0) * alpha;              // premultiplied white
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

        // Defaults: full, soft, and edge-free
        m.setValue(halfWidth,  forKey: "impostorHalfW")
        m.setValue(halfHeight, forKey: "impostorHalfH")
        m.setValue(0.90 as CGFloat, forKey: "stepMul")
        m.setValue(1.60 as CGFloat, forKey: "densityMul")
        m.setValue(0.60 as CGFloat, forKey: "coverage")
        m.setValue(0.0042 as CGFloat, forKey: "puffScale")
        m.setValue(2.20 as CGFloat, forKey: "thickness")
        m.setValue(0.26 as CGFloat, forKey: "edgeFeather")
        m.setValue(0.08 as CGFloat, forKey: "edgeCut")
        m.setValue(0.08 as CGFloat, forKey: "edgeNoiseAmp")

        m.diffuse.contents = UIColor.white
        m.multiply.contents = UIColor.white
        return m
    }
}
