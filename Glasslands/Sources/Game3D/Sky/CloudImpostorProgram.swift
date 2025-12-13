//
//  CloudImpostorProgram.swift
//  Glasslands
//
//  Created by . . on 10/7/25.
//
//  Volumetric “puff” impostor shader modifier for SceneKit.
//  Magenta output indicates shader compile failure at runtime.
//  Keep helper functions in `#pragma declarations` (global scope).
//

import SceneKit
import UIKit
import CoreGraphics

enum CloudImpostorProgram {

    @MainActor
    static func makeMaterial(halfWidth: CGFloat, halfHeight: CGFloat) -> SCNMaterial {
        let frag = """
        #pragma transparent

        #pragma arguments
        float3 sunDirView;
        float hgG;
        float baseWhite;
        float lightGain;
        float hiGain;

        float densityMul;
        float thickness;
        float densBias;
        float coverage;

        float puffScale;

        float edgeFeather;
        float edgeCut;
        float edgeNoiseAmp;

        float rimFeatherBoost;
        float rimFadePow;

        float shapeScale;
        float shapeLo;
        float shapeHi;
        float shapePow;

        float occK;

        float shapeSeed;

        float impostorHalfW;
        float impostorHalfH;

        #pragma declarations

        float hash11(float p) {
            p = fract(p * 0.1031);
            p *= p + 33.33;
            p *= p + p;
            return fract(p);
        }

        float hash31(float3 p) {
            p = fract(p * 0.1031);
            p += dot(p, p.yzx + 33.33);
            return fract((p.x + p.y) * p.z);
        }

        float noise3(float3 p) {
            float3 i = floor(p);
            float3 f = fract(p);
            f = f * f * (3.0 - 2.0 * f);

            float n000 = hash31(i + float3(0,0,0));
            float n100 = hash31(i + float3(1,0,0));
            float n010 = hash31(i + float3(0,1,0));
            float n110 = hash31(i + float3(1,1,0));
            float n001 = hash31(i + float3(0,0,1));
            float n101 = hash31(i + float3(1,0,1));
            float n011 = hash31(i + float3(0,1,1));
            float n111 = hash31(i + float3(1,1,1));

            float nx00 = mix(n000, n100, f.x);
            float nx10 = mix(n010, n110, f.x);
            float nx01 = mix(n001, n101, f.x);
            float nx11 = mix(n011, n111, f.x);

            float nxy0 = mix(nx00, nx10, f.y);
            float nxy1 = mix(nx01, nx11, f.y);

            return mix(nxy0, nxy1, f.z);
        }

        float fbm3_billow(float3 p) {
            float a = 0.5;
            float f = 0.0;

            float3 q = p;
            for (int i = 0; i < 4; i++) {
                float n = noise3(q);
                n = 1.0 - abs(2.0 * n - 1.0);
                f += a * n;
                q = q * 2.02 + float3(17.0, 11.0, 5.0);
                a *= 0.5;
            }
            return f;
        }

        float hg(float cosTheta, float g) {
            float g2 = g * g;
            return (1.0 - g2) / pow(1.0 + g2 - 2.0 * g * cosTheta, 1.5);
        }

        float macroMask2D(float2 uv, float seed, float sc, float lo, float hi, float pw) {
            float2 p = uv * sc;
            float n0 = noise3(float3(p, seed));
            float n1 = noise3(float3(p * 2.03 + 11.0, seed + 7.0));
            float n2 = noise3(float3(p * 4.07 + 23.0, seed + 19.0));
            float m = (0.55 * n0 + 0.30 * n1 + 0.15 * n2);
            m = smoothstep(lo, hi, m);
            return pow(m, max(0.01, pw));
        }

        float sampleD3(float3 p) {
            float n = fbm3_billow(p);
            return clamp(n, 0.0, 1.0);
        }

        #pragma body

        float2 uv = _surface.diffuseTexcoord;

        // Ellipse-correct UVs using plane half-sizes in world units.
        float hw = max(0.001, impostorHalfW);
        float hh = max(0.001, impostorHalfH);
        float denom = max(hw, hh);

        float2 uv0 = uv * 2.0 - 1.0;
        float2 uvE = uv0 * float2(hw, hh) / denom;

        float r2 = dot(uvE, uvE);
        if (r2 >= 1.0) {
            discard_fragment();
        }

        float zt = sqrt(max(0.0, 1.0 - r2));

        // Macro breakup (keeps lots of blue sky while allowing dense puffs).
        float macro = macroMask2D(uvE, shapeSeed, max(0.001, shapeScale), shapeLo, shapeHi, shapePow);
        float coreFloorK = clamp(0.20 + 0.22 * coverage, 0.0, 0.60);

        // Edge shaping with small noise erosion.
        float edgeBase = smoothstep(1.0 - max(0.001, edgeFeather), 1.0, sqrt(r2));
        float edgeN = noise3(float3(uvE * 6.0, shapeSeed + 13.0));
        float edge = edgeBase + edgeNoiseAmp * (edgeN - 0.5);
        float edgeMask = 1.0 - smoothstep(edgeCut, 1.0, clamp(edge, 0.0, 1.0));

        // Screen footprint -> sample count, clamped.
        const int NMAX = 5;
        float fw = max(fwidth(uvE.x), fwidth(uvE.y));
        float targetSamples = clamp((3.0 * thickness) / max(0.06, fw * 1200.0), 2.0, float(NMAX));
        int Ncalc = int(ceil(targetSamples));

        float zLUT[NMAX] = { 0.10, 0.32, 0.54, 0.76, 0.90 };
        float wLUT[NMAX] = { 0.20, 0.23, 0.24, 0.21, 0.12 };

        float accumAlpha = 0.0;
        float accumOcc = 0.0;

        float puff = max(0.0005, puffScale);

        // Fake “depth” march through a sphere, modulated by macro field.
        for (int i = 0; i < NMAX; i++) {
            if (i >= Ncalc) { break; }

            float z = zLUT[i] * zt * thickness;
            float w = wLUT[i];

            float3 p = float3(uvE * (1.0 + puff * 22.0) * macro, z + shapeSeed * 3.1);
            float d = sampleD3(p);

            // Bias + macro floor.
            d = max(d + densBias, 0.0);
            d = max(d, coreFloorK * macro);

            // Edge mask.
            d *= edgeMask;

            accumAlpha += d * w;
            accumOcc += d * w;
        }

        float alpha = 1.0 - exp(-accumAlpha * max(0.0, densityMul));
        if (alpha <= 0.001) {
            discard_fragment();
        }

        // View-space lighting: camera looks down -Z.
        float3 sView = normalize(sunDirView);
        float cosVS = clamp(-sView.z, -1.0, 1.0);

        float phase = hg(cosVS, clamp(hgG, 0.0, 0.95));
        phase = phase / max(0.001, hg(1.0, clamp(hgG, 0.0, 0.95)));

        // Rim brightening that fades with opacity so dense cores cover the sun more.
        float rim = pow(1.0 - zt, max(0.2, rimFadePow));
        rim *= (1.0 + rimFeatherBoost * (1.0 - alpha));

        float occ = clamp(1.0 - occK * accumOcc, 0.0, 1.0);

        float light = baseWhite + lightGain * phase * occ;
        float hi = hiGain * pow(max(0.0, phase), 2.0);

        float shade = clamp(light + hi + rim * 0.35, 0.0, 6.0);

        _output.color = float4(shade, shade, shade, alpha);
        """

        let m = SCNMaterial()
        m.lightingModel = .constant
        m.isDoubleSided = false
        m.cullMode = .back
        m.blendMode = .alpha
        m.transparencyMode = .aOne
        m.readsFromDepthBuffer = true
        m.writesToDepthBuffer = false
        m.shaderModifiers = [.fragment: frag]

        // Defaults are overridden by applyCloudSunUniforms(), but keep sensible values.
        m.setValue(SCNVector3(0, 1, 0), forKey: "sunDirView")
        m.setValue(0.62 as CGFloat, forKey: "hgG")
        m.setValue(1.00 as CGFloat, forKey: "baseWhite")
        m.setValue(1.65 as CGFloat, forKey: "lightGain")
        m.setValue(1.00 as CGFloat, forKey: "hiGain")

        m.setValue(14.00 as CGFloat, forKey: "densityMul")
        m.setValue(5.60 as CGFloat, forKey: "thickness")
        m.setValue(-0.02 as CGFloat, forKey: "densBias")
        m.setValue(0.86 as CGFloat, forKey: "coverage")

        m.setValue(0.0036 as CGFloat, forKey: "puffScale")

        m.setValue(0.16 as CGFloat, forKey: "edgeFeather")
        m.setValue(0.07 as CGFloat, forKey: "edgeCut")
        m.setValue(0.18 as CGFloat, forKey: "edgeNoiseAmp")

        m.setValue(2.10 as CGFloat, forKey: "rimFeatherBoost")
        m.setValue(2.80 as CGFloat, forKey: "rimFadePow")

        m.setValue(1.05 as CGFloat, forKey: "shapeScale")
        m.setValue(0.42 as CGFloat, forKey: "shapeLo")
        m.setValue(0.70 as CGFloat, forKey: "shapeHi")
        m.setValue(2.15 as CGFloat, forKey: "shapePow")

        m.setValue(0.70 as CGFloat, forKey: "occK")

        let seed = CGFloat(Double.random(in: 1_000...9_999))
        m.setValue(seed, forKey: "shapeSeed")

        m.setValue(max(0.001, halfWidth) as CGFloat, forKey: "impostorHalfW")
        m.setValue(max(0.001, halfHeight) as CGFloat, forKey: "impostorHalfH")

        return m
    }
}
