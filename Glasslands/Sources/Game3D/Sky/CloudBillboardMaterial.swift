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
    private static let marker = "/* VOL_IMPOSTOR_VSAFE_006_WHITE_ROUND */"

    @MainActor
    static func makeVolumetricImpostor() -> SCNMaterial {
        // White, round puffs; single-sample alpha mask; premultiplied output.
        let fragment = """
        \(marker)
        #pragma transparent

        #pragma arguments
        float3 sunDirView;   // kept for phase; colour is driven to white
        float3 sunTint;      // unused in colour (kept for compatibility)
        float  coverage;     // 0..1
        float  densityMul;   // 0.5..2.0
        float  stepMul;      // 0.7..1.5 (scales extinction)
        float  horizonLift;

        #pragma body

        // Sprite alpha (SceneKit provides these built-ins).
        float2 uv  = _surface.diffuseTexcoord;
        float  a0  = u_diffuseTexture.sample(u_diffuseTextureSampler, uv).a;
        if (a0 < 0.002f) { discard_fragment(); }

        // Simple phase to brighten with sun direction.
        float3 rd   = float3(0.0f, 0.0f, 1.0f);
        float3 sunV = normalize(sunDirView);
        float  mu   = clamp(dot(rd, sunV), -1.0f, 1.0f);
        float  g    = 0.62f;
        float  kph  = 1.55f * g - 0.55f * g * g;
        float  den  = 1.0f + kph * (1.0f - mu);
        float  phase= (1.0f - kph*kph) / (den*den + 1e-4f);

        // Density from the sprite alpha only (round), with a gentle height envelope.
        float c       = clamp(coverage, 0.0f, 1.0f);
        float thresh  = clamp(0.56f - 0.36f * c, 0.20f, 0.62f);
        float soft    = 0.30f;                       // softer = rounder
        float q       = clamp(stepMul, 0.7f, 1.5f);
        float kSigma  = 0.11f * q / 8.0f * densityMul;

        float  T = 1.0f;                             // transmittance
        float  ss = 0.0f;                            // scalar single-scatter accumulator

        // 8 fixed slices; sampler use is only the alpha read above.
        #define SLICE(hVal) { \
            float h = hVal; \
            float env = smoothstep(0.06f, 0.40f, h) * (1.0f - smoothstep(0.58f, 0.98f, h)); \
            float d = smoothstep(thresh - soft, thresh + soft, a0); \
            float dens = max(0.0f, d * env) * 1.10f; \
            float a = exp(-kSigma * dens); \
            float sliceT = T * (1.0f - a); \
            ss += sliceT; \
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

        // Final colour: bright white with a small ambient lift and phase boost.
        float  alphaOut = clamp((1.0f - T) * a0, 0.0f, 1.0f);
        float  ambient  = 0.20f;                     // soft multiple-scatter look
        float  boost    = 1.40f * (0.35f + 0.65f * phase);
        float3 whiteCol = float3(1.0f);
        float3 Cpm      = whiteCol * (ambient + boost * ss); // premultiplied scale term
        Cpm             = clamp(Cpm, float3(0.0f), float3(1.0f));

        // Horizon glow to stop silhouettes reading as cut-outs.
        Cpm += float3(horizonLift * (1.0f - uv.y) * 0.10f);
        Cpm  = clamp(Cpm, float3(0.0f), float3(1.0f));

        _output.color = float4(Cpm * alphaOut, alphaOut);
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

        // Defaults (tint kept but colour driven to white in the shader)
        m.setValue(SCNVector3(0, 0, 1),            forKey: "sunDirView")
        m.setValue(SCNVector3(1.00, 0.94, 0.82),   forKey: "sunTint")
        m.setValue(0.42 as CGFloat,                forKey: "coverage")
        m.setValue(1.00 as CGFloat,                forKey: "densityMul")
        m.setValue(1.00 as CGFloat,                forKey: "stepMul")
        m.setValue(0.14 as CGFloat,                forKey: "horizonLift")
        return m
    }

    static var volumetricMarker: String { marker }
}
