//
//  CloudBillboardMaterial.swift
//  Glasslands
//
//  Created by . . on 10/4/25.
//
//  Lobed, bottom-heavy cumulus with MICRO-CAULIFLOWER scallops that are airier.
//  – Irregular silhouette with scallops (no straight edges).
//  – Scallop peaks near the rim are rendered with lower optical depth (“vapoury”).
//  – Bases stay thick via gravity bias.
//  – Premultiplied output; analytically anti-aliased silhouette.
//

import SceneKit
import UIKit

enum CloudBillboardMaterial {

    @MainActor
    static func makeCurrent() -> SCNMaterial { makeVolumetricImpostor() }

    private static let marker = "/* VOL_IMPOSTOR_VSAFE_085_MICRO_VAPOUR */"

    @MainActor
    static func makeVolumetricImpostor() -> SCNMaterial {

        // No helper functions between pragmas (SceneKit requirement).
        let fragment = """
        \(marker)
        #pragma transparent

        #pragma arguments
        float3 sunDirView;
        float3 sunTint;
        float coverage;
        float densityMul;      // 0.5..4.0
        float stepMul;         // 0.7..1.5
        float horizonLift;     // 0..1

        // Shape / behaviour controls
        float protrude;        // 0..0.25  bulge beyond base circle
        float lobeAmp;         // 0..0.5   low-order lobes
        float gravK;           // 0..2.0   bottom heaviness
        float microAmp;        // 0..0.25  micro-scallop amplitude
        float microVapourK;    // 0..1.0   how airy scallop peaks are (0=solid, 1=very wispy)

        #pragma body
        // Sample sprite alpha at LOD0 (avoid transparent-frame bleed).
        float2 uv = _surface.diffuseTexcoord;
        float  a0 = u_diffuseTexture.sample(u_diffuseTextureSampler, uv, level(0.0)).a;
        if (a0 < 0.002f) { discard_fragment(); }

        // Centre-relative: r=1 at mid-edge of the quad.
        float2 c = (uv - float2(0.5f, 0.5f)) * 2.0f;
        float  r = length(c);
        float  ang = atan2(c.y, c.x);
        float  w = max(1e-5f, fwidth(r)) * 1.5f;

        // -------------------- LOBES (soft cauliflower) --------------------
        float l2 = sin(ang * 2.0f + 1.10f);
        float l3 = sin(ang * 3.0f - 0.70f);
        float l5 = sin(ang * 5.0f + 2.40f);
        float lobes = (0.55f*l2 + 0.35f*l3 + 0.10f*l5);

        // Gravity bias: fuller at the base.
        float down = clamp(-c.y, 0.0f, 1.0f);
        float baseBulge = gravK * down * down;

        // ---------------- MICRO-CAULIFLOWER (high-frequency scallops) ---------------
        // Cheap per-atlas phase to de-sync sprites.
        float sA = u_diffuseTexture.sample(u_diffuseTextureSampler, float2(0.23f, 0.73f), level(0.0)).a;
        float sB = u_diffuseTexture.sample(u_diffuseTextureSampler, float2(0.67f, 0.29f), level(0.0)).a;
        float phase = (sA * 6.2831853f) + (sB * 12.5663706f);
        float t = ang + phase;

        float micro =
              0.58f * sin(t * 9.0f)
            + 0.36f * sin(t * 13.0f + 1.7f)
            + 0.22f * sin(t * 17.0f - 0.9f);
        micro *= (0.65f + 0.45f * down); // stronger near base

        // Target edge radius (circle + lobes + micro scallops).
        float rMax = 1.0f
                   + protrude * (0.55f*baseBulge + lobeAmp * lobes)
                   + microAmp * micro;

        // Silhouette mask with analytic AA.
        float maskLobed = 1.0f - smoothstep(rMax - w, rMax + w, r);

        // Rounded-square guard so corners never show when protruding.
        float n = 3.5f, guardScale = 1.12f;
        float px = abs(c.x) / guardScale, py = abs(c.y) / guardScale;
        float superv = pow(px, n) + pow(py, n);
        float maskGuard = 1.0f - smoothstep(1.0f - w, 1.0f + w, superv);

        // Tightened sprite alpha (never grows footprint by itself).
        float maskSprite = pow(clamp(a0, 0.0f, 1.0f), 1.30f);

        // Final silhouette.
        float mask = maskSprite * maskGuard * maskLobed;
        if (mask < 0.002f) { discard_fragment(); }

        // --------------------------- Lighting & density ------------------------
        // Mild forward scatter for sun punch.
        float3 rd    = float3(0.0f, 0.0f, 1.0f);
        float3 sunV  = normalize(sunDirView);
        float  mu    = clamp(dot(rd, sunV), -1.0f, 1.0f);
        float  g     = 0.56f, gg = g*g;
        float  phaseHG = (1.0f - gg) / (4.0f * 3.14159265f * pow(1.0f + gg - 2.0f*g*mu, 1.5f));

        float q      = clamp(stepMul, 0.7f, 1.5f);
        float vap    = clamp(densityMul, 0.5f, 4.0f);
        float kSigma = (0.42f * q / 8.0f) * (0.9f + 1.4f * vap);

        // Jitter to break slice banding.
        float jitter = fract(sin(dot(uv, float2(12.9898f, 78.233f))) * 43758.5453f) - 0.5f;
        jitter *= 0.10f;

        // Edge proximity (0 deep inside → 1 at edge).
        float edge = smoothstep(rMax - 0.12f, rMax + 0.02f, r);

        // Positive scallops (bulges) get vapoury treatment near the rim.
        float microPos = max(micro, 0.0f); // only peaks, not indents
        float vapourSoft = 1.0f - microVapourK * edge * microPos; // 0..1 (lower → airier)

        float T  = 1.0f;
        float ss = 0.0f;

        // 10 slices; bases denser; scallop peaks softened by vapourSoft.
        {
            float h=0.05f + jitter;
            float env=smoothstep(0.06f,0.40f,h)*(1.0f-smoothstep(0.58f,0.98f,h));
            env *= (0.80f + gravK * pow(1.0f - h, 2.0f));
            float dens = mask * env * 1.28f * vapourSoft;
            float a = exp(-kSigma*dens);
            ss += mask * (1.0f - a) * (0.86f + 0.14f*phaseHG);
            T *= a;
        }{
            float h=0.15f + jitter; float env=smoothstep(0.06f,0.40f,h)*(1.0f-smoothstep(0.58f,0.98f,h)); env *= (0.80f + gravK * pow(1.0f - h, 2.0f)); float dens = mask * env * 1.28f * vapourSoft; float a = exp(-kSigma*dens); ss += mask * (1.0f - a) * (0.86f + 0.14f*phaseHG); T *= a;
        }{
            float h=0.25f + jitter; float env=smoothstep(0.06f,0.40f,h)*(1.0f-smoothstep(0.58f,0.98f,h)); env *= (0.80f + gravK * pow(1.0f - h, 2.0f)); float dens = mask * env * 1.28f * vapourSoft; float a = exp(-kSigma*dens); ss += mask * (1.0f - a) * (0.86f + 0.14f*phaseHG); T *= a;
        }{
            float h=0.35f + jitter; float env=smoothstep(0.06f,0.40f,h)*(1.0f-smoothstep(0.58f,0.98f,h)); env *= (0.80f + gravK * pow(1.0f - h, 2.0f)); float dens = mask * env * 1.28f * vapourSoft; float a = exp(-kSigma*dens); ss += mask * (1.0f - a) * (0.86f + 0.14f*phaseHG); T *= a;
        }{
            float h=0.45f + jitter; float env=smoothstep(0.06f,0.40f,h)*(1.0f-smoothstep(0.58f,0.98f,h)); env *= (0.80f + gravK * pow(1.0f - h, 2.0f)); float dens = mask * env * 1.28f * vapourSoft; float a = exp(-kSigma*dens); ss += mask * (1.0f - a) * (0.86f + 0.14f*phaseHG); T *= a;
        }{
            float h=0.55f + jitter; float env=smoothstep(0.06f,0.40f,h)*(1.0f-smoothstep(0.58f,0.98f,h)); env *= (0.80f + gravK * pow(1.0f - h, 2.0f)); float dens = mask * env * 1.28f * vapourSoft; float a = exp(-kSigma*dens); ss += mask * (1.0f - a) * (0.86f + 0.14f*phaseHG); T *= a;
        }{
            float h=0.65f + jitter; float env=smoothstep(0.06f,0.40f,h)*(1.0f-smoothstep(0.58f,0.98f,h)); env *= (0.80f + gravK * pow(1.0f - h, 2.0f)); float dens = mask * env * 1.28f * vapourSoft; float a = exp(-kSigma*dens); ss += mask * (1.0f - a) * (0.86f + 0.14f*phaseHG); T *= a;
        }{
            float h=0.75f + jitter; float env=smoothstep(0.06f,0.40f,h)*(1.0f-smoothstep(0.58f,0.98f,h)); env *= (0.80f + gravK * pow(1.0f - h, 2.0f)); float dens = mask * env * 1.28f * vapourSoft; float a = exp(-kSigma*dens); ss += mask * (1.0f - a) * (0.86f + 0.14f*phaseHG); T *= a;
        }{
            float h=0.85f + jitter; float env=smoothstep(0.06f,0.40f,h)*(1.0f-smoothstep(0.58f,0.98f,h)); env *= (0.80f + gravK * pow(1.0f - h, 2.0f)); float dens = mask * env * 1.28f * vapourSoft; float a = exp(-kSigma*dens); ss += mask * (1.0f - a) * (0.86f + 0.14f*phaseHG); T *= a;
        }{
            float h=0.95f + jitter; float env=smoothstep(0.06f,0.40f,h)*(1.0f-smoothstep(0.58f,0.98f,h)); env *= (0.80f + gravK * pow(1.0f - h, 2.0f)); float dens = mask * env * 1.28f * vapourSoft; float a = exp(-kSigma*dens); ss += mask * (1.0f - a) * (0.86f + 0.14f*phaseHG); T *= a;
        }

        // Centre weighting keeps bulk white; airy scallops come from vapourSoft.
        float roundBoost = 1.0f - smoothstep(0.55f, 1.00f, r);
        float alphaOut = clamp(mask * (1.0f - pow(T, 0.56f)) * (0.85f + 0.35f * roundBoost), 0.0f, 1.0f);

        float ambient = 0.60f, gain = 2.40f;
        float3 Cpm = float3(min(1.0f, ambient + gain * ss));

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

        // Texture sampling (LOD0 fetch above; nearest keeps the rim clean).
        m.diffuse.wrapS = .clamp
        m.diffuse.wrapT = .clamp
        m.diffuse.mipFilter = .nearest
        m.diffuse.minificationFilter = .linear
        m.diffuse.magnificationFilter = .linear
        m.diffuse.maxAnisotropy = 4.0

        // Defaults; tweak at runtime if desired.
        m.setValue(SCNVector3(0, 0, 1),         forKey: "sunDirView")
        m.setValue(SCNVector3(1.0, 0.94, 0.82), forKey: "sunTint")
        m.setValue(0.42 as CGFloat,             forKey: "coverage")
        m.setValue(3.00 as CGFloat,             forKey: "densityMul")
        m.setValue(0.95 as CGFloat,             forKey: "stepMul")
        m.setValue(0.14 as CGFloat,             forKey: "horizonLift")

        // Shape behaviour
        m.setValue(0.16 as CGFloat,             forKey: "protrude")
        m.setValue(0.24 as CGFloat,             forKey: "lobeAmp")
        m.setValue(1.25 as CGFloat,             forKey: "gravK")
        m.setValue(0.14 as CGFloat,             forKey: "microAmp")
        m.setValue(0.45 as CGFloat,             forKey: "microVapourK")   // 0.35–0.65 nice range

        return m
    }

    static var volumetricMarker: String { marker }
}
