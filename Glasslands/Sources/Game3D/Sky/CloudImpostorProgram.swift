//
//  CloudImpostorProgram.swift
//  Glasslands
//
//  Created by . . on 10/7/25.
//
//  Volumetric cloud impostors using a fragment-only SceneKit shader modifier.
//  Changes in this revision:
//  – Pure white albedo (no tint).
//  – Removed ambient/self-light: no base term, no rim lift; sunlight only.
//  – Kept forward-scatter + soft self-shadow so form reads, but all from sun.
//

import SceneKit
import simd
import UIKit

enum CloudImpostorProgram {

    static func makeMaterial(halfWidth: CGFloat, halfHeight: CGFloat) -> SCNMaterial {

        let frag = """
        #pragma transparent

        // ========= uniforms (set on SCNMaterial) =========
        #pragma arguments
        float impostorHalfW;
        float impostorHalfH;

        // ray-march quality / density model
        float stepMul;
        float densityMul;
        float thickness;
        float densBias;

        // shape / coverage
        float coverage;
        float puffScale;
        float edgeFeather;
        float edgeCut;
        float edgeNoiseAmp;
        float edgeErode;
        float centreFill;
        float shapeScale;
        float shapeLo;
        float shapeHi;
        float shapeSeed;

        // lighting (sun-only)
        float3 sunDirView;   // normalised view-space sun direction
        float hgG;           // Henyey–Greenstein anisotropy
        float baseWhite;     // white point (premultiplied colour), keep = 1
        float hiGain;        // scatter gain
        float edgeSoft;      // kept for compatibility; set to 0
        float microAmp;
        float occK;

        // ========= helpers =========
        #pragma declarations

        inline float hash1(float n){ return fract(sin(n) * 43758.5453123); }
        inline float hash12(float2 p){ return fract(sin(dot(p, float2(127.1,311.7))) * 43758.5453123); }

        inline float noise3(float3 x) {
            float3 p = floor(x), f = x - p;
            f = f*f*(3.0 - 2.0*f);
            const float3 off = float3(1.0,57.0,113.0);
            float n = dot(p, off);
            float n000 = hash1(n +   0.0), n100 = hash1(n +   1.0);
            float n010 = hash1(n +  57.0), n110 = hash1(n +  58.0);
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
            for (int y = -1; y <= 1; ++y)
            for (int xk = -1; xk <= 1; ++xk){
                float2 g = float2(xk, y);
                float2 o = float2(hash12(i+g), hash12(i+g+19.7));
                float2 r = g + o - f;
                d = min(d, dot(r, r));
            }
            return sqrt(max(d, 0.0));
        }

        inline float puffFBM2(float2 x){
            float a = 0.0, w = 0.62, s = 1.0;
            float v = 1.0 - clamp(worley2(x*s), 0.0, 1.0);
            a += v*w; s *= 2.03; w *= 0.55;
            v = 1.0 - clamp(worley2(x*s), 0.0, 1.0);
            a += v*w;
            return clamp(a, 0.0, 1.0);
        }

        inline float densityUV(float2 uv, float z, float cov, float puffS, float microK) {
            float2 mCoord = uv * 0.62 + float2(z*0.15, -z*0.09);
            float macro = 1.0 - clamp(worley2(mCoord * 1.32), 0.0, 1.0);

            float3 bP = float3(uv * 1.55, z);
            float base = noise3(bP * 1.95);

            float2 pCoord = uv * max(1e-4, puffS * 195.0) + float2(z*0.33, -z*0.21);
            float puffs = puffFBM2(pCoord);

            float micro = mix(base, puffs, 0.72);
            micro = mix(micro, puffs, microK);

            float coverInv = 1.0 - clamp(cov, 0.0, 1.0);
            float thLo = clamp(coverInv - 0.18, 0.0, 1.0);
            float thHi = clamp(coverInv + 0.24, 0.0, 1.0);
            float t = smoothstep(thLo, thHi, micro) * macro;

            return pow(clamp(t, 0.0, 1.0), 1.12);
        }

        inline float shapeMaskUV(float2 uv, float scale, float lo, float hi, float seed) {
            float s1 = fract(sin(seed*12.9898) * 43758.5453);
            float s2 = fract(s1*1.6180339);
            float2 off = float2(s1, s2);
            float w = 1.0 - clamp(worley2(uv * scale + off), 0.0, 1.0);
            return smoothstep(lo, hi, w);
        }

        inline float hg(float cosTheta, float g) {
            float g2 = g*g;
            float denom = pow(max(1e-4, 1.0 + g2 - 2.0*g*cosTheta), 1.5);
            return (1.0 - g2) / (4.0 * 3.14159265 * denom);
        }

        // ========= fragment body =========
        #pragma body

        float2 uv = _surface.diffuseTexcoord * 2.0 - 1.0;
        float2 halfs = float2(max(0.0001, impostorHalfW), max(0.0001, impostorHalfH));
        float s = max(halfs.x, halfs.y);
        float2 uvE = uv * halfs / s;

        float r = length(uvE);
        float nEdge = noise3(float3(uvE * 3.15, 0.0));
        float rWobble = (nEdge * 2.0 - 1.0) * edgeNoiseAmp;
        float rDist = r + rWobble;
        float cutR = 1.0 - clamp(edgeCut, 0.0, 0.49);
        if (rDist >= cutR) { discard_fragment(); }

        float featherR0 = cutR - clamp(edgeFeather, 0.0, 0.49);
        float rimSoft = smoothstep(featherR0, cutR, rDist);
        float interior = 1.0 - rimSoft;

        float sMask = shapeMaskUV(uvE, shapeScale, shapeLo, shapeHi, shapeSeed);
        float edgeMask = interior * sMask;

        float covLocal  = mix(max(0.0, coverage - edgeErode),
                              min(1.0, coverage + centreFill), edgeMask);
        float fillGain  = mix(1.0, 1.0 + centreFill, edgeMask);

        float Lm = clamp(thickness, 0.50, 8.0);
        int   N  = clamp(int(round(20.0 * clamp(stepMul, 0.35, 1.40))), 8, 36);
        float dt = Lm / float(N);

        float j = fract(sin(dot(uvE, float2(12.9898,78.233))) * 43758.5453);
        float t = (0.35 + 0.5*j) * dt;

        float3 sView = normalize(sunDirView);
        float2 sunUV = normalize(abs(sView.x) + abs(sView.y) > 1e-4
                                 ? float2(sView.x, sView.y)
                                 : float2(0.0001, 0.0001));
        float  sunZ  = sView.z;

        float T = 1.0;
        float3 C = float3(0.0);

        // Sun-only brightness via phase function (no ambient/base lift)
        float cosVS = clamp(-sView.z, -1.0, 1.0);
        float Fwd = hg(cosVS, hgG);
        const float liftAtEdge = 1.0; // edgeSoft deliberately unused (sun-only)

        for (int i=0; i<N && T > 0.003; ++i) {
            float z = -0.5*Lm + t;

            float d = densityUV(uvE, z, covLocal, max(1e-4, puffScale), microAmp) * edgeMask;

            if (d > 0.0006) {
                float2 uvOcc = uvE + sunUV * 0.22;
                float  zOcc  = z   + sunZ * 0.22;
                float  occ   = densityUV(uvOcc, zOcc, covLocal, max(1e-4, puffScale), microAmp);
                float  shadow = 1.0 - clamp(occK * occ, 0.0, 0.85);

                float aStep = 1.0 - exp(-(max(0.0, densityMul) * (0.045*d + densBias)) * dt * fillGain);

                // WHITE, sun-only:
                //   – no constant term
                //   – no rim lift
                //   – scale only by phase + shadow
                float l = (baseWhite * (hiGain * Fwd)) * shadow * liftAtEdge;

                C += (l * aStep) * T;
                T *= (1.0 - aStep);
            }

            t += dt;
        }

        float alpha = clamp(1.0 - T, 0.0, 1.0);
        _output.color = float4(C, alpha); // premultiplied
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

        // impostor bounds for aspect-correct UVs
        m.setValue(halfWidth,  forKey: "impostorHalfW")
        m.setValue(halfHeight, forKey: "impostorHalfH")

        // tuned defaults
        m.setValue(1.15 as CGFloat,  forKey: "stepMul")
        m.setValue(2.20 as CGFloat,  forKey: "densityMul")
        m.setValue(3.10 as CGFloat,  forKey: "thickness")
        m.setValue(0.00 as CGFloat,  forKey: "densBias")

        m.setValue(0.62 as CGFloat,  forKey: "coverage")
        m.setValue(0.0100 as CGFloat, forKey: "puffScale")
        m.setValue(0.16 as CGFloat,  forKey: "edgeFeather")
        m.setValue(0.06 as CGFloat,  forKey: "edgeCut")
        m.setValue(0.16 as CGFloat,  forKey: "edgeNoiseAmp")
        m.setValue(0.26 as CGFloat,  forKey: "edgeErode")
        m.setValue(0.36 as CGFloat,  forKey: "centreFill")
        m.setValue(1.03 as CGFloat,  forKey: "shapeScale")
        m.setValue(0.44 as CGFloat,  forKey: "shapeLo")
        m.setValue(0.72 as CGFloat,  forKey: "shapeHi")
        m.setValue(Float.random(in: 0...1000), forKey: "shapeSeed")

        // lighting defaults; engine updates sunDirView per frame
        m.setValue(SCNVector3(0, 1, 0), forKey: "sunDirView")
        m.setValue(0.56 as CGFloat,  forKey: "hgG")
        m.setValue(1.00 as CGFloat,  forKey: "baseWhite")   // pure white
        m.setValue(1.10 as CGFloat,  forKey: "hiGain")      // scatter gain
        m.setValue(0.00 as CGFloat,  forKey: "edgeSoft")    // no rim lift
        m.setValue(0.26 as CGFloat,  forKey: "microAmp")
        m.setValue(1.15 as CGFloat,  forKey: "occK")

        m.diffuse.contents = UIColor.white
        m.multiply.contents = UIColor.white
        return m
    }
}
