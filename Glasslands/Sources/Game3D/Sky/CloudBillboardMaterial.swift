//
//  CloudBillboardMaterial.swift
//  Glasslands
//
//  Created by . . on 10/4/25.
//
//  Round-disc cumulus impostors: strictly circular silhouette with analytic AA,
//  confined density (no footprint growth), and premultiplied output.
//

import SceneKit
import UIKit

enum CloudBillboardMaterial {

    @MainActor
    static func makeCurrent() -> SCNMaterial { makeVolumetricImpostor() }

    private static let marker = "/* VOL_IMPOSTOR_VSAFE_020_ROUNDDISC */"

    @MainActor
    static func makeVolumetricImpostor() -> SCNMaterial {

        // No helper functions between #pragma arguments/body.
        let fragment = """
        \(marker)
        #pragma transparent

        #pragma arguments
        float3 sunDirView;
        float3 sunTint;        // kept for compatibility
        float coverage;        // kept for compatibility
        float densityMul;      // 0.5..4.0  ← raise for thicker cores
        float stepMul;         // 0.7..1.5
        float horizonLift;     // 0..1

        #pragma body
        // Sprite alpha at top mip to avoid bleed from transparent frame.
        float2 uv = _surface.diffuseTexcoord;
        float  a0 = u_diffuseTexture.sample(u_diffuseTextureSampler, uv, level(0.0)).a;
        if (a0 < 0.002f) { discard_fragment(); }

        // --- Pure circular silhouette with analytic AA -----------------------
        // r = 1 at the mid-points of the quad edges, ~1.414 at the corners.
        float2 d = uv - float2(0.5f, 0.5f);
        float  r = length(d) * 2.0f;

        // Analytic edge width in UV, scaled slightly to keep the rim clean.
        float w = fwidth(r) * 1.5f;

        // Disc mask: 1 inside, 0 outside, smooth across the boundary.
        float disc = 1.0f - smoothstep(1.0f - w, 1.0f + w, r);

        // Tightened sprite mask (never grows the footprint).
        float mask = pow(clamp(a0, 0.0f, 1.0f), 1.35f) * disc;

        // If the disc culled everything, finish early.
        if (mask < 0.002f) { discard_fragment(); }

        // --- Lighting and thickness -----------------------------------------
        // Mild forward scattering for a bit of sun punch.
        float3 rd    = float3(0.0f, 0.0f, 1.0f);
        float3 sunV  = normalize(sunDirView);
        float  mu    = clamp(dot(rd, sunV), -1.0f, 1.0f);
        float  g     = 0.56f;
        float  gg    = g * g;
        float  phase = (1.0f - gg) / (4.0f * 3.14159265f * pow(1.0f + gg - 2.0f*g*mu, 1.5f));

        // Optical depth. Constrained to the disc+sprite mask.
        float q      = clamp(stepMul, 0.7f, 1.5f);
        float vap    = clamp(densityMul, 0.5f, 4.0f);
        float kSigma = (0.42f * q / 8.0f) * (0.9f + 1.4f * vap);

        // Small jitter to break slice banding at high density.
        float jitter = fract(sin(dot(uv, float2(12.9898f, 78.233f))) * 43758.5453f) - 0.5f;
        jitter *= 0.10f;

        float T  = 1.0f; // transmittance
        float ss = 0.0f; // single scatter accumulator

        // 10 slices for smoother round bodies when very close.
        {
            float h=0.05f  + jitter;
            float env=smoothstep(0.06f,0.40f,h)*(1.0f-smoothstep(0.58f,0.98f,h));
            float dens = mask * env * 1.28f;
            float a = exp(-kSigma*dens);
            ss += mask * (1.0f - a) * (0.86f + 0.14f*phase);
            T *= a;
        }{
            float h=0.15f  + jitter; float env=smoothstep(0.06f,0.40f,h)*(1.0f-smoothstep(0.58f,0.98f,h)); float dens = mask * env * 1.28f; float a = exp(-kSigma*dens); ss += mask * (1.0f - a) * (0.86f + 0.14f*phase); T *= a;
        }{
            float h=0.25f  + jitter; float env=smoothstep(0.06f,0.40f,h)*(1.0f-smoothstep(0.58f,0.98f,h)); float dens = mask * env * 1.28f; float a = exp(-kSigma*dens); ss += mask * (1.0f - a) * (0.86f + 0.14f*phase); T *= a;
        }{
            float h=0.35f  + jitter; float env=smoothstep(0.06f,0.40f,h)*(1.0f-smoothstep(0.58f,0.98f,h)); float dens = mask * env * 1.28f; float a = exp(-kSigma*dens); ss += mask * (1.0f - a) * (0.86f + 0.14f*phase); T *= a;
        }{
            float h=0.45f  + jitter; float env=smoothstep(0.06f,0.40f,h)*(1.0f-smoothstep(0.58f,0.98f,h)); float dens = mask * env * 1.28f; float a = exp(-kSigma*dens); ss += mask * (1.0f - a) * (0.86f + 0.14f*phase); T *= a;
        }{
            float h=0.55f  + jitter; float env=smoothstep(0.06f,0.40f,h)*(1.0f-smoothstep(0.58f,0.98f,h)); float dens = mask * env * 1.28f; float a = exp(-kSigma*dens); ss += mask * (1.0f - a) * (0.86f + 0.14f*phase); T *= a;
        }{
            float h=0.65f  + jitter; float env=smoothstep(0.06f,0.40f,h)*(1.0f-smoothstep(0.58f,0.98f,h)); float dens = mask * env * 1.28f; float a = exp(-kSigma*dens); ss += mask * (1.0f - a) * (0.86f + 0.14f*phase); T *= a;
        }{
            float h=0.75f  + jitter; float env=smoothstep(0.06f,0.40f,h)*(1.0f-smoothstep(0.58f,0.98f,h)); float dens = mask * env * 1.28f; float a = exp(-kSigma*dens); ss += mask * (1.0f - a) * (0.86f + 0.14f*phase); T *= a;
        }{
            float h=0.85f  + jitter; float env=smoothstep(0.06f,0.40f,h)*(1.0f-smoothstep(0.58f,0.98f,h)); float dens = mask * env * 1.28f; float a = exp(-kSigma*dens); ss += mask * (1.0f - a) * (0.86f + 0.14f*phase); T *= a;
        }{
            float h=0.95f  + jitter; float env=smoothstep(0.06f,0.40f,h)*(1.0f-smoothstep(0.58f,0.98f,h)); float dens = mask * env * 1.28f; float a = exp(-kSigma*dens); ss += mask * (1.0f - a) * (0.86f + 0.14f*phase); T *= a;
        }

        // Centre weighting to emphasise round volume.
        float roundBoost = 1.0f - smoothstep(0.55f, 1.00f, r);
        float alphaOut = clamp(mask * (1.0f - pow(T, 0.56f)) * (0.85f + 0.35f * roundBoost), 0.0f, 1.0f);

        // Bright, premultiplied colour.
        float ambient = 0.60f;
        float gain    = 2.40f;
        float centreW = pow(a0, 0.95f);
        float3 Cpm    = float3(min(1.0f, ambient + gain * ss * centreW));

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

        // Texture sampling: honour the transparent frame; avoid bleeding.
        m.diffuse.wrapS = .clamp
        m.diffuse.wrapT = .clamp
        m.diffuse.mipFilter = .nearest   // lod0 fetch above; nearest keeps rim clean
        m.diffuse.minificationFilter = .linear
        m.diffuse.magnificationFilter = .linear
        m.diffuse.maxAnisotropy = 4.0

        // Defaults; engine can override.
        m.setValue(SCNVector3(0, 0, 1),         forKey: "sunDirView")
        m.setValue(SCNVector3(1.0, 0.94, 0.82), forKey: "sunTint")
        m.setValue(0.42 as CGFloat,             forKey: "coverage")
        m.setValue(2.80 as CGFloat,             forKey: "densityMul")  // thicker core
        m.setValue(0.95 as CGFloat,             forKey: "stepMul")
        m.setValue(0.14 as CGFloat,             forKey: "horizonLift")
        return m
    }

    static var volumetricMarker: String { marker }
}
