//
//  CloudBillboardMaterial.swift
//  Glasslands
//
//  Created by . . on 10/4/25.
//
//  Volumetric impostor for billboard puffs (no ambient hacks).
//  – Sun-only single scattering (HG) + compact self-occlusion
//  – Small Rayleigh backscatter term from the sky so backlit puffs aren’t black
//  – Uses the actual view vector; lighter 6-slice integration
//

import SceneKit
import UIKit

enum CloudBillboardMaterial {

    @MainActor
    static func makeCurrent() -> SCNMaterial { makeVolumetricImpostor() }

    static let volumetricMarker = "/* VOL_IMPOSTOR_VSAFE_090_BACKSCATTER */"

    @MainActor
    static func makeVolumetricImpostor() -> SCNMaterial {
        let fragment = """
        \(volumetricMarker)
        #pragma transparent
        #pragma arguments
        float3 sunDirView;     // sun dir in view space
        float3 sunTint;        // sun RGB (linear)
        float  coverage;       // 0..1
        float  densityMul;     // 0.5..4
        float  stepMul;        // 0.7..1.5
        float  horizonLift;    // 0..1
        float  protrude;       // 0..0.25
        float  lobeAmp;        // 0..0.5
        float  gravK;          // 0..2
        float  microAmp;       // 0..0.25
        float  microVapourK;   // 0..1
        float  skyBackK;       // 0..1  (new) backscatter lift for backlit sides
        #pragma body

        // Texture alpha (sprite mask)
        float2 uv = _surface.diffuseTexcoord;
        float a0 = u_diffuseTexture.sample(u_diffuseTextureSampler, uv, level(0.0)).a;
        if (a0 < 0.002f) { discard_fragment(); }

        // Radial coords in sprite space
        float2 c = (uv - float2(0.5f, 0.5f)) * 2.0f;
        float r = length(c);
        float ang = atan2(c.y, c.x);
        float w = max(1e-5f, fwidth(r)) * 1.5f;

        // Lobes & gravity bias (shape)
        float l2 = sin(ang * 2.0f + 1.10f);
        float l3 = sin(ang * 3.0f - 0.70f);
        float l5 = sin(ang * 5.0f + 2.40f);
        float lobes = (0.55f*l2 + 0.35f*l3 + 0.10f*l5);
        float down = clamp(-c.y, 0.0f, 1.0f);
        float baseBulge = gravK * down * down;

        // Micro scallops
        float sA = u_diffuseTexture.sample(u_diffuseTextureSampler, float2(0.23f, 0.73f), level(0.0)).a;
        float sB = u_diffuseTexture.sample(u_diffuseTextureSampler, float2(0.67f, 0.29f), level(0.0)).a;
        float phase = (sA * 6.2831853f) + (sB * 12.5663706f);
        float t = ang + phase;
        float micro = 0.58f * sin(t * 9.0f) + 0.36f * sin(t * 13.0f + 1.7f) + 0.22f * sin(t * 17.0f - 0.9f);
        micro *= (0.65f + 0.45f * down);

        float rMax = 1.0f + protrude * (0.55f*baseBulge + lobeAmp * lobes) + microAmp * micro;

        // AA silhouette + rounded-square guard
        float maskLobed = 1.0f - smoothstep(rMax - w, rMax + w, r);
        float n = 3.5f, guardScale = 1.12f;
        float px = abs(c.x) / guardScale, py = abs(c.y) / guardScale;
        float superv = pow(px, n) + pow(py, n);
        float maskGuard = 1.0f - smoothstep(1.0f - w, 1.0f + w, superv);
        float maskSprite = pow(clamp(a0, 0.0f, 1.0f), 1.30f);
        float mask = maskSprite * maskGuard * maskLobed;
        if (mask < 0.002f) { discard_fragment(); }

        // Lighting parameters
        float3 V = normalize(-_surface.view);        // real view direction
        float3 S = normalize(sunDirView);
        float mu = clamp(dot(V, S), -1.0f, 1.0f);

        // HG forward lobe (single scattering)
        float g = 0.56f, gg = g*g;
        float phaseHG = (1.0f - gg) / (4.0f * 3.14159265f * pow(1.0f + gg - 2.0f*g*mu, 1.5f));

        // Small Rayleigh-like backscatter so backlit puffs don’t go black
        float phaseRay = (3.0f / (16.0f * 3.14159265f)) * (1.0f + mu*mu);
        float skyBack = clamp(skyBackK, 0.0f, 1.0f) * phaseRay;

        // Coeffs (fast)
        float q = clamp(stepMul, 0.7f, 1.5f);
        float vap = clamp(densityMul, 0.5f, 4.0f);
        float kSigma = (0.42f * q / 8.0f) * (0.9f + 1.4f * vap);

        float jitter = fract(sin(dot(uv, float2(12.9898f, 78.233f))) * 43758.5453f) - 0.5f;
        jitter *= 0.10f;

        float edge = smoothstep(rMax - 0.12f, rMax + 0.02f, r);
        float microPos = max(micro, 0.0f);
        float vapourSoft = 1.0f - microVapourK * edge * microPos;

        float T = 1.0f;    // transmittance
        float ss = 0.0f;   // single-scatter

        // 6 slices is plenty for puffs
        [unroll] for (int i=0; i<6; ++i) {
            float h = (0.08f + 0.14f*float(i)) + jitter;
            float env = smoothstep(0.06f,0.40f,h) * (1.0f - smoothstep(0.58f,0.98f,h));
            env *= (0.80f + gravK * pow(1.0f - h, 2.0f));
            float dens = mask * env * 1.28f * vapourSoft;

            float a = exp(-kSigma * dens);
            ss += mask * (1.0f - a) * phaseHG;
            T *= a;
        }

        float alphaOut = clamp(mask * (1.0f - pow(T, 0.56f)), 0.0f, 1.0f);

        // Colour: forward HG plus small sky backscatter (scaled by opacity)
        float3 C = sunTint * (ss + skyBack * alphaOut * 0.6f);

        // Gentle horizon lift for readability
        C += float3(horizonLift * (1.0f - uv.y) * 0.06f) * alphaOut;

        _output.color = float4(clamp(C * alphaOut, 0.0f, 1.0f), alphaOut);
        """

        let m = SCNMaterial()
        m.lightingModel = .constant
        m.blendMode = .alpha
        m.transparencyMode = .aOne
        m.isDoubleSided = false
        m.readsFromDepthBuffer = false
        m.writesToDepthBuffer = false
        m.shaderModifiers = [.fragment: fragment]

        // Texture sampling
        m.diffuse.wrapS = .clamp
        m.diffuse.wrapT = .clamp
        m.diffuse.mipFilter = .nearest
        m.diffuse.minificationFilter = .linear
        m.diffuse.magnificationFilter = .linear
        m.diffuse.maxAnisotropy = 4.0

        // Defaults (engine updates each frame)
        m.setValue(SCNVector3(0, 0, 1), forKey: "sunDirView")
        m.setValue(SCNVector3(1.0, 0.94, 0.82), forKey: "sunTint")
        m.setValue(0.42 as CGFloat, forKey: "coverage")
        m.setValue(2.40 as CGFloat, forKey: "densityMul")
        m.setValue(0.95 as CGFloat, forKey: "stepMul")
        m.setValue(0.12 as CGFloat, forKey: "horizonLift")
        m.setValue(0.16 as CGFloat, forKey: "protrude")
        m.setValue(0.24 as CGFloat, forKey: "lobeAmp")
        m.setValue(1.10 as CGFloat, forKey: "gravK")
        m.setValue(0.14 as CGFloat, forKey: "microAmp")
        m.setValue(0.45 as CGFloat, forKey: "microVapourK")
        m.setValue(0.22 as CGFloat, forKey: "skyBackK")   // ← small, prevents “black”
        return m
    }
}
