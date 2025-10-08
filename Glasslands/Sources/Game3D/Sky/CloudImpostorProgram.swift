//
//  CloudImpostorProgram.swift
//  Glasslands
//
//  Created by . . on 10/7/25.
//
//  Volumetric cloud impostors via a fragment shader modifier only.
//  Erode near the rim, dilate the interior, add an irregular shape mask,
//  and keep density anchored to the impostor so the vapour moves as a unit.
//

import SceneKit
import simd
import UIKit

enum CloudImpostorProgram {
    static func makeMaterial(halfWidth: CGFloat, halfHeight: CGFloat) -> SCNMaterial {
        let frag = """
        #pragma transparent

        // -------- uniforms (all set on the material) --------
        #pragma arguments
        float impostorHalfW;      // local half width
        float impostorHalfH;      // local half height

        float stepMul;            // 0.35..1.25 (quality/cost)
        float densityMul;         // base extinction
        float thickness;          // slab thickness in UV-depth units

        float coverage;           // macro gate (0..1)
        float puffScale;          // micro puff scale

        float edgeFeather;        // soft rim width (0..0.5)
        float edgeCut;            // extra hard cut outside feather (0..0.5)
        float edgeNoiseAmp;       // noisy rim wobble (0..0.2)

        float edgeErode;          // additional erode near rim (0..0.5)
        float centreFill;         // extra fill at centre (0..0.8)

        float shapeScale;         // 0.6..1.6 (mask size)
        float shapeLo;            // mask lower threshold
        float shapeHi;            // mask upper threshold
        float shapeSeed;          // per-material seed

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

        // Macro/micro billow field (2.5D) in quad space
        inline float densityUV(float2 uv, float z, float cov, float puffS) {
            float2 mCoord = uv * 0.62 + float2(z*0.15, -z*0.09);
            float macro = 1.0 - clamp(worley2(mCoord * 1.32), 0.0, 1.0);

            float3 bP = float3(uv * 1.55, z);
            float base = noise3(bP * 1.95);

            float2 pCoord = uv * max(1e-4, puffS * 175.0) + float2(z*0.33, -z*0.21);
            float puffs = puffFBM2(pCoord);

            float coverInv = 1.0 - clamp(cov, 0.0, 1.0);
            float shape = mix(base, puffs, 0.55);
            float thLo = clamp(coverInv - 0.18, 0.0, 1.0);
            float thHi = clamp(coverInv + 0.24, 0.0, 1.0);
            float t    = smoothstep(thLo, thHi, shape) * macro;

            // Slightly steeper for a fuller interior
            return pow(clamp(t, 0.0, 1.0), 1.10);
        }

        // Soft blobby silhouette mask (irregular, seedable)
        inline float shapeMaskUV(float2 uv, float scale, float lo, float hi, float seed) {
            float s1 = fract(sin(seed*12.9898) * 43758.5453);
            float s2 = fract(s1*1.6180339);
            float2 off = float2(s1, s2);
            float w = 1.0 - clamp(worley2(uv * scale + off), 0.0, 1.0);
            return smoothstep(lo, hi, w);
        }

        // -------- fragment body --------
        #pragma body
        // Quad UV in [-1,1], aspect-aware mapping
        float2 uv = _surface.diffuseTexcoord * 2.0 - 1.0;
        float2 halfs = float2(max(0.0001, impostorHalfW), max(0.0001, impostorHalfH));
        float s = max(halfs.x, halfs.y);
        float2 uvE = uv * halfs / s;

        // Noisy, elliptical rim (hard cut + feather)
        float r = length(uvE);
        float nEdge = noise3(float3(uvE * 3.10, 0.0));
        float rWobble = (nEdge * 2.0 - 1.0) * edgeNoiseAmp;
        float rDist = r + rWobble;

        float cutR = 1.0 - clamp(edgeCut, 0.0, 0.49);
        if (rDist >= cutR) { discard_fragment(); }

        float featherR0 = cutR - clamp(edgeFeather, 0.0, 0.49);
        float rimSoft   = smoothstep(featherR0, cutR, rDist); // 0 centre … 1 rim
        float interior  = 1.0 - rimSoft;                      // 1 centre … 0 rim

        // Irregular silhouette inside the card
        float sMask = shapeMaskUV(uvE, shapeScale, shapeLo, shapeHi, shapeSeed);
        float edgeMask = interior * sMask;

        // Local “retract then fill”: erode near rim, dilate at centre
        float covLocal   = mix(max(0.0, coverage - edgeErode), min(1.0, coverage + centreFill), edgeMask);
        float fillGain   = mix(1.0, 1.0 + centreFill, edgeMask); // boosts extinction in the core

        // Slab + steps
        float Lm = max(0.2, thickness);
        int   N  = clamp(int(round(16.0 * clamp(stepMul, 0.35, 1.25))), 6, 32);
        float dt = Lm / float(N);

        // Per-fragment jitter to reduce banding
        float j = fract(sin(dot(uvE, float2(12.9898,78.233))) * 43758.5453);
        float t = (0.25 + 0.5*j) * dt;

        // March
        float T = 1.0;
        for (int i=0; i<N && T>0.004; ++i) {
            float z = -0.5*Lm + t;
            float d = densityUV(uvE, z, covLocal, max(1e-4, puffScale)) * edgeMask;
            if (d > 0.0008) {
                float aStep = 1.0 - exp(-max(0.0, densityMul) * 0.045 * d * dt * fillGain);
                T *= (1.0 - aStep);
            }
            t += dt;
        }

        float alpha = clamp(1.0 - T, 0.0, 1.0);
        float3 rgb  = float3(1.0) * alpha;   // premultiplied white
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

        // Defaults tuned for “irregular fluffy blobs” without card edges
        m.setValue(halfWidth,  forKey: "impostorHalfW")
        m.setValue(halfHeight, forKey: "impostorHalfH")

        m.setValue(0.90 as CGFloat, forKey: "stepMul")
        m.setValue(1.65 as CGFloat, forKey: "densityMul")
        m.setValue(2.30 as CGFloat, forKey: "thickness")

        m.setValue(0.58 as CGFloat, forKey: "coverage")
        m.setValue(0.0042 as CGFloat, forKey: "puffScale")

        m.setValue(0.28 as CGFloat, forKey: "edgeFeather")
        m.setValue(0.10 as CGFloat, forKey: "edgeCut")
        m.setValue(0.10 as CGFloat, forKey: "edgeNoiseAmp")

        m.setValue(0.18 as CGFloat, forKey: "edgeErode")   // retract near rim
        m.setValue(0.22 as CGFloat, forKey: "centreFill")  // dilate centre

        m.setValue(1.05 as CGFloat, forKey: "shapeScale")
        m.setValue(0.38 as CGFloat, forKey: "shapeLo")
        m.setValue(0.62 as CGFloat, forKey: "shapeHi")
        m.setValue(Float.random(in: 0...1000), forKey: "shapeSeed")

        m.diffuse.contents = UIColor.white
        m.multiply.contents = UIColor.white
        return m
    }
}
