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

    @MainActor
    static func makeCurrent() -> SCNMaterial { makeVolumetricImpostor() }

    // Version marker for verification logs.
    private static let marker = "/* VOL_IMPOSTOR_VSAFE_005 */"

    @MainActor
    static func makeVolumetricImpostor() -> SCNMaterial {
        // Single-sample, premultiplied impostor; NO helper functions outside #pragma body.
        let fragment = """
        \(marker)
        #pragma transparent

        #pragma arguments
        float3 sunDirView;
        float3 sunTint;
        float  coverage;     // 0..1
        float  densityMul;   // 0.5..2.0
        float  stepMul;      // 0.7..1.5 (scales extinction)
        float  horizonLift;

        #pragma body

        // Alpha mask from the material's diffuse texture (SceneKit provides these built-ins).
        float2 uv  = _surface.diffuseTexcoord;
        float  a0  = u_diffuseTexture.sample(u_diffuseTextureSampler, uv).a;
        if (a0 < 0.002f) { discard_fragment(); }

        // View ray and lighting phase (Schlick single-scatter inline).
        float3 rd   = float3(0.0f, 0.0f, 1.0f);
        float3 sunV = normalize(sunDirView);
        float  mu   = clamp(dot(rd, sunV), -1.0f, 1.0f);
        float  g    = 0.62f;
        float  k    = 1.55f * g - 0.55f * g * g;
        float  den  = 1.0f + k * (1.0f - mu);
        float  phase= (1.0f - k*k) / (den*den + 1e-4f);

        // Shape/coverage.
        float c       = clamp(coverage, 0.0f, 1.0f);
        float thresh  = clamp(0.56f - 0.36f * c, 0.20f, 0.62f);
        float soft    = 0.25f;
        float q       = clamp(stepMul, 0.7f, 1.5f);
        float kSigma  = 0.14f * q / 8.0f * densityMul;

        float  T = 1.0f;             // transmittance
        float3 S = float3(0.0f);     // single scatter

        // Helper macro for 8 fixed slices (keeps code simple without extra functions).
        #define SLICE(hVal) { \
            float h = hVal; \
            float env = smoothstep(0.06f, 0.40f, h) * (1.0f - smoothstep(0.58f, 0.98f, h)); \
            float n = sin(dot(uv * 19.0f + float2(h, h * 1.7f), float2(12.9898f, 78.233f))) * 43758.5453f; \
            float j = (fract(n) - 0.5f) * 0.08f; \
            float bias = (h - 0.5f) * 0.10f + j; \
            float d = smoothstep(thresh - soft, thresh + soft, clamp(a0 + bias, 0.0f, 1.0f)); \
            float powder = 1.0f - exp(-2.0f * d); \
            float dens = max(0.0f, d * env) * 1.15f; \
            float a = exp(-kSigma * dens); \
            float sliceT = T * (1.0f - a); \
            S += sunTint * (phase * (0.40f + 0.60f * powder)) * sliceT; \
            T *= a; \
        }

        SLICE(0.0625f)
        SLICE(0.1875f)
        SLICE(0.3125f)
        SLICE(0.4375f)
        SLICE(0.5625f)
        SLICE(0.6875f)
        SLICE(0.8125f)
        SLICE(0.9375f)

        #undef SLICE

        // Subtle horizon lift and premultiplied write.
        S += float3(horizonLift * (1.0f - uv.y) * 0.22f);
        float alphaOut = clamp((1.0f - T) * a0, 0.0f, 1.0f);
        _output.color  = float4(clamp(S, float3(0.0f), float3(1.0f)) * alphaOut, alphaOut);
        """

        let m = SCNMaterial()
        m.lightingModel = .constant
        m.blendMode = .alpha
        m.transparencyMode = .aOne
        m.isDoubleSided = false
        m.readsFromDepthBuffer = true
        m.writesToDepthBuffer = false
        m.shaderModifiers = [.fragment: fragment]

        // Safe sampling defaults
        m.diffuse.wrapS = .clamp
        m.diffuse.wrapT = .clamp
        m.diffuse.mipFilter = .linear
        m.diffuse.minificationFilter = .linear
        m.diffuse.magnificationFilter = .linear
        m.diffuse.maxAnisotropy = 4.0

        // Default arguments
        m.setValue(SCNVector3(0, 0, 1),            forKey: "sunDirView")
        m.setValue(SCNVector3(1.00, 0.94, 0.82),   forKey: "sunTint")
        m.setValue(0.42 as CGFloat,                forKey: "coverage")
        m.setValue(1.10 as CGFloat,                forKey: "densityMul")
        m.setValue(1.00 as CGFloat,                forKey: "stepMul")
        m.setValue(0.16 as CGFloat,                forKey: "horizonLift")
        return m
    }

    static var volumetricMarker: String { marker }
}
