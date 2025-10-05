//
//  CloudBillboardMaterial.swift
//  Glasslands
//
//  Created by . . on 10/4/25.
//
//  Bottom-heavy, lobed cumulus with MICRO-CAULIFLOWER scallops.
//  – Irregular silhouette (never straight, never perfectly circular).
//  – Micro scallops ride on top of the lobes so edges are always “bumpy”.
//  – Bases are denser via gravity bias.
//  – Premultiplied output, strictly clipped to a rounded guard (no quad corners).
//

import SceneKit
import UIKit

enum CloudBillboardMaterial {

    @MainActor
    static func makeCurrent() -> SCNMaterial { makeVolumetricImpostor() }

    private static let marker = "/* VOL_IMPOSTOR_VSAFE_060_MICROCAULI */"

    @MainActor
    static func makeVolumetricImpostor() -> SCNMaterial {

        // NOTE: no function defs between #pragma arguments/body (SceneKit rule).
        let fragment = """
        \(marker)
        #pragma transparent

        #pragma arguments
        float3 sunDirView;
        float3 sunTint;
        float coverage;
        float densityMul;      // 0.5..4.0  ← thicker vapour
        float stepMul;         // 0.7..1.5
        float horizonLift;     // 0..1

        // Shape controls
        float protrude;        // 0..0.25  big bulge beyond base circle
        float lobeAmp;         // 0..0.5   low-order lobes (cauliflower “caps”)
        float gravK;           // 0..2.0   bottom heaviness
        float microAmp;        // 0..0.25  micro-scallops on the rim

        #pragma body
        // Sprite alpha at LOD0 to avoid bleeding from the transparent frame.
        float2 uv = _surface.diffuseTexcoord;
        float  a0 = u_diffuseTexture.sample(u_diffuseTextureSampler, uv, level(0.0)).a;
        if (a0 < 0.002f) { discard_fragment(); }

        // Centre-relative coords: r=1 at mid-edge of the quad.
        float2 c = (uv - float2(0.5f, 0.5f)) * 2.0f;
        float  r = length(c);
        float  ang = atan2(c.y, c.x);
        float  w = max(1e-5f, fwidth(r)) * 1.5f;

        // -------------------- LOBES (soft cauliflower caps) --------------------
        float l2 = sin(ang * 2.0f + 1.10f);
        float l3 = sin(ang * 3.0f - 0.70f);
        float l5 = sin(ang * 5.0f + 2.40f);
        float lobes = (0.55f*l2 + 0.35f*l3 + 0.10f*l5);

        // Gravity bias: bases fuller.
        float down = clamp(-c.y, 0.0f, 1.0f);
        float baseBulge = gravK * down * down;

        // ---------------- MICRO-CAULIFLOWER (high-freq scallops) ---------------
        // Per-atlas variation from a couple of fixed taps (cheap seed).
        float sA = u_diffuseTexture.sample(u_diffuseTextureSampler, float2(0.23f, 0.73f), level(0.0)).a;
        float sB = u_diffuseTexture.sample(u_diffuseTextureSampler, float2(0.67f, 0.29f), level(0.0)).a;
        float phase = (sA * 6.2831853f) + (sB * 12.5663706f);
        float t = ang + phase;

        // Smooth multi-sine noise along the rim; more at the bottom.
        float micro =
              0.58f * sin(t * 9.0f)
            + 0.36f * sin(t * 13.0f + 1.7f)
            + 0.22f * sin(t * 17.0f - 0.9f);
        micro *= (0.65f + 0.45f * down); // heavier scallops near base

        // Target edge radius as a function of angle.
        float rMax = 1.0f
                   + protrude * (0.55f*baseBulge + lobeAmp * lobes)
                   + microAmp * micro;

        // Mask 1: inside the lobed+micro silhouette (analytic AA).
        float maskLobed = 1.0f - smoothstep(rMax - w, rMax + w, r);

        // Mask 2: rounded-square guard (superellipse) so corners never show.
        float n = 3.5f;
        float guardScale = 1.12f;
        float px = abs(c.x) / guardScale, py = abs(c.y) / guardScale;
        float superv = pow(px, n) + pow(py, n);
        float maskGuard = 1.0f - smoothstep(1.0f - w, 1.0f + w, superv);

        // Mask 3: tightened sprite alpha (never grows footprint).
        float maskSprite = pow(clamp(a0, 0.0f, 1.0f), 1.30f);

        // Final silhouette.
        float mask = maskSprite * maskGuard * maskLobed;
        if (mask < 0.002f) { discard_fragment(); }

        // --------------------------- Lighting & density ------------------------
        float3 rd    = float3(0.0f, 0.0f, 1.0f);
        float3 sunV  = normalize(sunDirView);
        float  mu    = clamp(dot(rd, sunV), -1.0f, 1.0f);
        float  g     = 0.56f;
        float  gg    = g * g;
        float  phaseHG = (1.0f - gg) / (4.0f * 3.14159265f * pow(1.0f + gg - 2.0f*g*mu, 1.5f));

        float q      = clamp(stepMul, 0.7f, 1.5f);
        float vap    = clamp(densityMul, 0.5f, 4.0f);
        float kSigma = (0.42f * q / 8.0f) * (0.9f + 1.4f * vap);

        // Micro jitter to break slice banding.
        float jitter = fract(sin(dot(uv, float2(12.9898f, 78.233f))) * 43758.5453f) - 0.5f;
        jitter *= 0.10f;

        float T  = 1.0f;
        float ss = 0.0f;

        // Rim thickening near scallops so circles never show through.
        float rim = smoothstep(rMax - 0.08f, rMax + 0.02f, r) * (1.0f - smoothstep(rMax + 0.02f, rMax + 0.12f, r));
        float rimBoost = 1.0f + rim * (0.7f + 0.6f * down);

        // 10 slices; bases denser via gravK.
        {
            float h=0.05f + jitter;
            float env=smoothstep(0.06f,0.40f,h)*(1.0f-smoothstep(0.58f,0.98f,h));
            env *= (0.80f + gravK * pow(1.0f - h, 2.0f));
            float dens = mask * env * 1.28f * rimBoost;
            float a = exp(-kSigma*dens);
            ss += mask * (1.0f - a) * (0.86f + 0.14f*phaseHG);
            T *= a;
        }{
            float h=0.15f + jitter; float env=smoothstep(0.06f,0.40f,h)*(1.0f-smoothstep(0.58f,0.98f,h)); env *= (0.80f + gravK * pow(1.0f - h, 2.0f)); float dens = mask * env * 1.28f * rimBoost; float a = exp(-kSigma*dens); ss += mask * (1.0f - a) * (0.86f + 0.14f*phaseHG); T *= a;
        }{
            float h=0.25f + jitter; float env=smoothstep(0.06f,0.40f,h)*(1.0f-smoothstep(0.58f,0.98f,h)); env *= (0.80f + gravK * pow(1.0f - h, 2.0f)); float dens = mask * env * 1.28f * rimBoost; float a = exp(-kSigma*dens); ss += mask * (1.0f - a) * (0.86f + 0.14f*phaseHG); T *= a;
        }{
            float h=0.35f + jitter; float env=smoothstep(0.06f,0.40f,h)*(1.0f-smoothstep(0.58f,0.98f,h)); env *= (0.80f + gravK * pow(1.0f - h, 2.0f)); float dens = mask * env * 1.28f * rimBoost; float a = exp(-kSigma*dens); ss += mask * (1.0f - a) * (0.86f + 0.14f*phaseHG); T *= a;
        }{
            float h=0.45f + jitter; float env=smoothstep(0.06f,0.40f,h)*(1.0f-smoothstep(0.58f,0.98f,h)); env *= (0.80f + gravK * pow(1.0f - h, 2.0f)); float dens = mask * env * 1.28f * rimBoost; float a = exp(-kSigma*dens); ss += mask * (1.0f - a) * (0.86f + 0.14f*phaseHG); T *= a;
        }{
            float h=0.55f + jitter; float env=smoothstep(0.06f,0.40f,h)*(1.0f-smoothstep(0.58f,0.98f,h)); env *= (0.80f + gravK * pow(1.0f - h, 2.0f)); float dens = mask * env * 1.28f * rimBoost; float a = exp(-kSigma*dens); ss += mask * (1.0f - a) * (0.86f + 0.14f*phaseHG); T *= a;
        }{
            float h=0.65f + jitter; float env=smoothstep(0.06f,0.40f,h)*(1.0f-smoothstep(0.58f,0.98f,h)); env *= (0.80f + gravK * pow(1.0f - h, 2.0f)); float dens = mask * env * 1.28f * rimBoost; float a = exp(-kSigma*dens); ss += mask * (1.0f - a) * (0.86f + 0.14f*phaseHG); T *= a;
        }{
            float h=0.75f + jitter; float env=smoothstep(0.06f,0.40f,h)*(1.0f-smoothstep(0.58f,0.98f,h)); env *= (0.80f + gravK * pow(1.0f - h, 2.0f)); float dens = mask * env * 1.28f * rimBoost; float a = exp(-kSigma*dens); ss += mask * (1.0f - a) * (0.86f + 0.14f*phaseHG); T *= a;
        }{
            float h=0.85f + jitter; float env=smoothstep(0.06f,0.40f,h)*(1.0f-smoothstep(0.58f,0.98f,h)); env *= (0.80f + gravK * pow(1.0f - h, 2.0f)); float dens = mask * env * 1.28f * rimBoost; float a = exp(-kSigma*dens); ss += mask * (1.0f - a) * (0.86f + 0.14f*phaseHG); T *= a;
        }{
            float h=0.95f + jitter; float env=smoothstep(0.06f,0.40f,h)*(1.0f-smoothstep(0.58f,0.98f,h)); env *= (0.80f + gravK * pow(1.0f - h, 2.0f)); float dens = mask * env * 1.28f * rimBoost; float a = exp(-kSigma*dens); ss += mask * (1.0f - a) * (0.86f + 0.14f*phaseHG); T *= a;
        }

        // Centre weighting keeps volume thick; irregular edge comes from masks.
        float roundBoost = 1.0f - smoothstep(0.55f, 1.00f, r);
        float alphaOut = clamp(mask * (1.0f - pow(T, 0.56f)) * (0.85f + 0.35f * roundBoost), 0.0f, 1.0f);

        float ambient = 0.60f;
        float gain    = 2.40f;
        float3 Cpm    = float3(min(1.0f, ambient + gain * ss));

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

        // Texture sampling: LOD0 fetch above; nearest keeps the rim clean.
        m.diffuse.wrapS = .clamp
        m.diffuse.wrapT = .clamp
        m.diffuse.mipFilter = .nearest
        m.diffuse.minificationFilter = .linear
        m.diffuse.magnificationFilter = .linear
        m.diffuse.maxAnisotropy = 4.0

        // Defaults (tweak at runtime if desired).
        m.setValue(SCNVector3(0, 0, 1),         forKey: "sunDirView")
        m.setValue(SCNVector3(1.0, 0.94, 0.82), forKey: "sunTint")
        m.setValue(0.42 as CGFloat,             forKey: "coverage")
        m.setValue(3.00 as CGFloat,             forKey: "densityMul")
        m.setValue(0.95 as CGFloat,             forKey: "stepMul")
        m.setValue(0.14 as CGFloat,             forKey: "horizonLift")

        // Shape: tuned for the micro-cauliflower look.
        m.setValue(0.16 as CGFloat,             forKey: "protrude")
        m.setValue(0.24 as CGFloat,             forKey: "lobeAmp")
        m.setValue(1.25 as CGFloat,             forKey: "gravK")
        m.setValue(0.14 as CGFloat,             forKey: "microAmp")

        return m
    }

    static var volumetricMarker: String { marker }
}
