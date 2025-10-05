//
//  CloudBillboardMaterial.swift
//  Glasslands
//
//  Created by . . on 10/4/25.
//
//  Sprite-based cumulus impostors: confined density (no footprint growth),
//  rounder cores, soft white lighting. Premultiplied output.
//

import SceneKit
import UIKit

enum CloudBillboardMaterial {

    @MainActor
    static func makeCurrent() -> SCNMaterial { makeVolumetricImpostor() }

    // Marker for quick verification.
    private static let marker = "/* VOL_IMPOSTOR_VSAFE_013_CONFINED_ROUND_NOHASH */"

    @MainActor
    static func makeVolumetricImpostor() -> SCNMaterial {

        // NOTE:
        //  • No function declarations between #pragma arguments and #pragma body.
        //  • Any “helpers” are written inline inside the body to keep SceneKit happy.

        let fragment = """
        \(marker)
        #pragma transparent

        #pragma arguments
        float3 sunDirView;
        float3 sunTint;        // kept for compatibility
        float coverage;        // 0..1 (unused here but preserved)
        float densityMul;      // 0.5..3.5 — raise for “more vapour”, stays confined
        float stepMul;         // 0.7..1.5
        float horizonLift;     // 0..1

        #pragma body
        // Sprite alpha.
        float2 uv = _surface.diffuseTexcoord;
        float  a0 = u_diffuseTexture.sample(u_diffuseTextureSampler, uv).a;
        if (a0 < 0.002f) { discard_fragment(); }

        // Confinement: tighten edges so extra density never bleeds outside the sprite.
        float edgePow = 1.35f;
        float mask    = pow(clamp(a0, 0.0f, 1.0f), edgePow);

        // Mild forward scattering for sun “punch”.
        float3 rd    = float3(0.0f, 0.0f, 1.0f);
        float3 sunV  = normalize(sunDirView);
        float  mu    = clamp(dot(rd, sunV), -1.0f, 1.0f);
        float  g     = 0.55f;
        float  gg    = g * g;
        float  phase = (1.0f - gg) / (4.0f * 3.14159265f * pow(1.0f + gg - 2.0f*g*mu, 1.5f));

        // Optical depth.
        float q      = clamp(stepMul, 0.7f, 1.5f);
        float vap    = clamp(densityMul, 0.5f, 3.5f);
        float kSigma = (0.28f * q / 8.0f) * (0.9f + 1.6f * vap);

        // Tiny per-pixel jitter to kill arced banding when dense.
        float jitter = fract(sin(dot(uv, float2(12.9898f, 78.233f))) * 43758.5453f) - 0.5f;
        jitter *= 0.12f;

        float T  = 1.0f; // transmittance
        float ss = 0.0f; // single scattering accumulator

        // 8 fixed slices through a thin vertical profile; only a0 used via sampler above.
        {
            float h=0.0625f + jitter;
            float env=smoothstep(0.06f,0.40f,h)*(1.0f-smoothstep(0.58f,0.98f,h));
            float dens = mask * env * 1.20f;
            float a = exp(-kSigma*dens);
            ss += mask * (1.0f - a) * (0.86f + 0.14f*phase);
            T *= a;
        }{
            float h=0.1875f + jitter;
            float env=smoothstep(0.06f,0.40f,h)*(1.0f-smoothstep(0.58f,0.98f,h));
            float dens = mask * env * 1.20f;
            float a = exp(-kSigma*dens);
            ss += mask * (1.0f - a) * (0.86f + 0.14f*phase);
            T *= a;
        }{
            float h=0.3125f + jitter;
            float env=smoothstep(0.06f,0.40f,h)*(1.0f-smoothstep(0.58f,0.98f,h));
            float dens = mask * env * 1.20f;
            float a = exp(-kSigma*dens);
            ss += mask * (1.0f - a) * (0.86f + 0.14f*phase);
            T *= a;
        }{
            float h=0.4375f + jitter;
            float env=smoothstep(0.06f,0.40f,h)*(1.0f-smoothstep(0.58f,0.98f,h));
            float dens = mask * env * 1.20f;
            float a = exp(-kSigma*dens);
            ss += mask * (1.0f - a) * (0.86f + 0.14f*phase);
            T *= a;
        }{
            float h=0.5625f + jitter;
            float env=smoothstep(0.06f,0.40f,h)*(1.0f-smoothstep(0.58f,0.98f,h));
            float dens = mask * env * 1.20f;
            float a = exp(-kSigma*dens);
            ss += mask * (1.0f - a) * (0.86f + 0.14f*phase);
            T *= a;
        }{
            float h=0.6875f + jitter;
            float env=smoothstep(0.06f,0.40f,h)*(1.0f-smoothstep(0.58f,0.98f,h));
            float dens = mask * env * 1.20f;
            float a = exp(-kSigma*dens);
            ss += mask * (1.0f - a) * (0.86f + 0.14f*phase);
            T *= a;
        }{
            float h=0.8125f + jitter;
            float env=smoothstep(0.06f,0.40f,h)*(1.0f-smoothstep(0.58f,0.98f,h));
            float dens = mask * env * 1.20f;
            float a = exp(-kSigma*dens);
            ss += mask * (1.0f - a) * (0.86f + 0.14f*phase);
            T *= a;
        }{
            float h=0.9375f + jitter;
            float env=smoothstep(0.06f,0.40f,h)*(1.0f-smoothstep(0.58f,0.98f,h));
            float dens = mask * env * 1.20f;
            float a = exp(-kSigma*dens);
            ss += mask * (1.0f - a) * (0.86f + 0.14f*phase);
            T *= a;
        }

        // Roundness bias so silhouettes read as cauliflower, not squares.
        float2 d = uv - float2(0.5f, 0.5f);
        float  r = clamp(length(d) * 2.0f, 0.0f, 1.0f);
        float  roundBoost = 1.0f - smoothstep(0.55f, 1.00f, r);  // centre > rim

        // Alpha strictly within original mask, centre-weighted.
        float alphaOut = clamp(mask * (1.0f - pow(T, 0.62f)) * (0.85f + 0.30f * roundBoost), 0.0f, 1.0f);

        // Bright white, centre-weighted lighting, premultiplied.
        float ambient = 0.62f;
        float gain    = 2.35f;
        float centre  = pow(a0, 0.95f);
        float3 Cpm    = float3(min(1.0f, ambient + gain * ss * centre));

        // Gentle horizon lift respecting alpha.
        Cpm += float3(horizonLift * (1.0f - uv.y) * 0.10f) * alphaOut;
        Cpm = clamp(Cpm, float3(0.0f), float3(1.0f));

        _output.color = float4(Cpm * alphaOut, alphaOut);
        """

        let m = SCNMaterial()
        m.lightingModel = .constant
        m.blendMode = .alpha
        m.transparencyMode = .aOne
        m.isDoubleSided = false
        m.readsFromDepthBuffer = false
        m.writesToDepthBuffer = false
        m.shaderModifiers = [.fragment: fragment]

        // Sampling defaults.
        m.diffuse.wrapS = .clamp
        m.diffuse.wrapT = .clamp
        m.diffuse.mipFilter = .linear
        m.diffuse.minificationFilter = .linear
        m.diffuse.magnificationFilter = .linear
        m.diffuse.maxAnisotropy = 4.0

        // Defaults (engine overrides at runtime).
        m.setValue(SCNVector3(0, 0, 1),         forKey: "sunDirView")
        m.setValue(SCNVector3(1.0, 0.94, 0.82), forKey: "sunTint")
        m.setValue(0.42 as CGFloat,             forKey: "coverage")
        m.setValue(2.20 as CGFloat,             forKey: "densityMul")  // thicker core
        m.setValue(0.95 as CGFloat,             forKey: "stepMul")
        m.setValue(0.14 as CGFloat,             forKey: "horizonLift")
        return m
    }

    static var volumetricMarker: String { marker }
}
