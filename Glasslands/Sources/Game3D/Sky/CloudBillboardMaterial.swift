//
//  CloudBillboardMaterial.swift
//  Glasslands
//
//  Created by . . on 10/4/25.
//
//  Single source of truth for the sprite material and its soft back-lighting.
//

import SceneKit
import UIKit

enum CloudBillboardMaterial {
    // Flip to true after you see non-magenta, semi-transparent white puffs.
    private static let useVolumetric = false

    @MainActor
    static func makeCurrent() -> SCNMaterial {
        useVolumetric ? makeVolumetricImpostor() : makeFlatAlpha()
    }

    // -------------- Flat-alpha (compile-proof, no samplers) --------------
    @MainActor
    static func makeFlatAlpha() -> SCNMaterial {
        let fragment = """
        #pragma transparent
        #pragma body
        float a0 = clamp(_output.color.a, 0.0, 1.0);
        _output.color = float4(a0, a0, a0, a0);
        """
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.blendMode = .alpha
        m.transparencyMode = .aOne
        m.isDoubleSided = false
        m.readsFromDepthBuffer = true
        m.writesToDepthBuffer = false
        m.shaderModifiers = [.fragment: fragment]
        m.diffuse.wrapS = .clamp
        m.diffuse.wrapT = .clamp
        m.diffuse.mipFilter = .linear
        m.diffuse.minificationFilter = .linear
        m.diffuse.magnificationFilter = .linear
        m.diffuse.maxAnisotropy = 4.0
        return m
    }

    // -------------- No-sampler volumetric impostor --------------
    @MainActor
    static func makeVolumetricImpostor() -> SCNMaterial {
        let fragment = """
        #pragma transparent
        #pragma arguments
        float3 sunDirView;
        float3 sunTint;
        float  coverage;
        float  densityMul;
        float  stepMul;
        float  horizonLift;

        float  saturate1(float x) { return clamp(x, 0.0, 1.0); }
        float3 sat3(float3 v)     { return clamp(v, float3(0.0), float3(1.0)); }
        float  hash21(float2 p) {
            p = fract(p * float2(123.34, 456.21));
            float h = dot(p, p + float2(78.233, 78.233));
            p += float2(h, h);
            return fract(p.x * p.y);
        }
        float  hg(float g, float mu) {
            float gg = g * g;
            return (1.0 - gg) / pow(1.0 + gg - 2.0*g*mu, 1.5);
        }

        #pragma body
        float2 uv  = _surface.diffuseTexcoord;
        float  a0  = saturate1(_output.color.a);
        if (a0 < 0.002) { discard_fragment(); }

        float3 rd   = normalize(-_surface.view);
        float3 sunV = normalize(sunDirView);

        int   N  = (int)round(clamp(stepMul, 0.7, 1.5) * 18.0);
        float T  = 1.0;
        float3 S = float3(0.0, 0.0, 0.0);

        float phase  = clamp(hg(0.62, clamp(dot(rd, sunV), -1.0, 1.0)), 0.0, 5.0);
        float thresh = clamp(0.56 - 0.36 * saturate1(coverage), 0.20, 0.62);
        float soft   = 0.25;

        for (int i = 0; i < N; ++i) {
            float t = (float(i) + 0.5) / (float)N;
            float h = t;

            float env = smoothstep(0.06, 0.40, h) * (1.0 - smoothstep(0.58, 0.98, h));

            float j = (hash21(uv * 19.0 + float2(t, t*1.7)) - 0.5) * 0.08;
            float bias = (h - 0.5) * 0.10 + j;

            float d = smoothstep(thresh - soft, thresh + soft, saturate1(a0 + bias));
            float powder = 1.0 - exp(-2.0 * d);

            float dens  = max(0.0, d * env) * densityMul * 1.15;
            float sigma = 1.05 / (float)N;
            float A = sigma * dens;
            float a = exp(-A);
            float sliceT = T * (1.0 - a);

            float3 scat = sunTint * (phase * (0.40 + 0.60 * powder));
            S += scat * sliceT;

            T *= a;
            if (T < 0.02) break;
        }

        S += float3(horizonLift * (1.0 - uv.y) * 0.22);
        float alphaOut = (1.0 - T) * a0;
        _output.color = float4(sat3(S), alphaOut);
        """

        let m = SCNMaterial()
        m.lightingModel = .constant
        m.blendMode = .alpha
        m.transparencyMode = .aOne
        m.isDoubleSided = false
        m.readsFromDepthBuffer = true
        m.writesToDepthBuffer = false
        m.shaderModifiers = [.fragment: fragment]

        m.diffuse.wrapS = .clamp
        m.diffuse.wrapT = .clamp
        m.diffuse.mipFilter = .linear
        m.diffuse.minificationFilter = .linear
        m.diffuse.magnificationFilter = .linear
        m.diffuse.maxAnisotropy = 4.0

        m.setValue(SCNVector3(0, 0, 1),          forKey: "sunDirView")
        m.setValue(SCNVector3(1.00, 0.94, 0.82), forKey: "sunTint")
        m.setValue(0.42 as CGFloat,              forKey: "coverage")
        m.setValue(1.10 as CGFloat,              forKey: "densityMul")
        m.setValue(1.00 as CGFloat,              forKey: "stepMul")
        m.setValue(0.16 as CGFloat,              forKey: "horizonLift")

        return m
    }
}
