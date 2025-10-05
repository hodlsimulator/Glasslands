//
//  CloudBillboardMaterial.swift
//  Glasslands
//
//  Created by . . on 10/4/25.
//
//  Sprite-based cumulus impostors: confined density, rounded corners,
//  anti-aliased alpha, and premultiplied output.
//

import SceneKit
import UIKit

enum CloudBillboardMaterial {

    @MainActor
    static func makeCurrent() -> SCNMaterial { makeVolumetricImpostor() }

    private static let marker = "/* VOL_IMPOSTOR_VSAFE_015_ROUND_LOD0 */"

    @MainActor
    static func makeVolumetricImpostor() -> SCNMaterial {

        // No helper functions between #pragma arguments/body.
        let fragment = """
        \(marker)
        #pragma transparent

        #pragma arguments
        float3 sunDirView;
        float3 sunTint;
        float coverage;
        float densityMul;      // 0.5..3.5  ← increase for thicker cores
        float stepMul;         // 0.7..1.5
        float horizonLift;

        #pragma body
        float2 uv = _surface.diffuseTexcoord;

        // Alpha from top mip to avoid “square bleed” from mip filtering.
        float a0 = u_diffuseTexture.sample(u_diffuseTextureSampler, uv, level(0.0)).a;
        if (a0 < 0.002f) { discard_fragment(); }

        // Edge-confined mask: tighten slightly and apply analytic AA.
        float edgePow = 1.55f;
        float rawMask = pow(clamp(a0, 0.0f, 1.0f), edgePow);
        float fw = fwidth(rawMask) * 1.2f;
        float mask = smoothstep(0.0f + fw, 1.0f - fw, rawMask);

        // Corner feather to kill visible quad corners (keeps footprint similar).
        float2 c = abs(uv - float2(0.5f, 0.5f)) * 2.0f;    // 0..1 from centre to edge
        float rr = max(c.x, c.y);                           // rounded-rect radius
        float corner = smoothstep(0.92f, 1.00f, rr);        // only near corners
        mask *= (1.0f - 0.75f * corner);

        // Mild forward scattering for sun punch.
        float3 rd    = float3(0.0f, 0.0f, 1.0f);
        float3 sunV  = normalize(sunDirView);
        float  mu    = clamp(dot(rd, sunV), -1.0f, 1.0f);
        float  g     = 0.56f;
        float  gg    = g * g;
        float  phase = (1.0f - gg) / (4.0f * 3.14159265f * pow(1.0f + gg - 2.0f*g*mu, 1.5f));

        // Optical depth (thicker by default; still confined to mask).
        float q      = clamp(stepMul, 0.7f, 1.5f);
        float vap    = clamp(densityMul, 0.5f, 3.5f);
        float kSigma = (0.38f * q / 8.0f) * (0.9f + 1.5f * vap);

        // Tiny per-pixel jitter to break banding.
        float jitter = fract(sin(dot(uv, float2(12.9898f, 78.233f))) * 43758.5453f) - 0.5f;
        jitter *= 0.10f;

        float T  = 1.0f;
        float ss = 0.0f;

        // 8 slices through a thin vertical profile (a0 was already sampled).
        {
            float h=0.0625f + jitter;
            float env=smoothstep(0.06f,0.40f,h)*(1.0f-smoothstep(0.58f,0.98f,h));
            float dens = mask * env * 1.25f;
            float a = exp(-kSigma*dens);
            ss += mask * (1.0f - a) * (0.86f + 0.14f*phase);
            T *= a;
        }{
            float h=0.1875f + jitter;
            float env=smoothstep(0.06f,0.40f,h)*(1.0f-smoothstep(0.58f,0.98f,h));
            float dens = mask * env * 1.25f;
            float a = exp(-kSigma*dens);
            ss += mask * (1.0f - a) * (0.86f + 0.14f*phase);
            T *= a;
        }{
            float h=0.3125f + jitter;
            float env=smoothstep(0.06f,0.40f,h)*(1.0f-smoothstep(0.58f,0.98f,h));
            float dens = mask * env * 1.25f;
            float a = exp(-kSigma*dens);
            ss += mask * (1.0f - a) * (0.86f + 0.14f*phase);
            T *= a;
        }{
            float h=0.4375f + jitter;
            float env=smoothstep(0.06f,0.40f,h)*(1.0f-smoothstep(0.58f,0.98f,h));
            float dens = mask * env * 1.25f;
            float a = exp(-kSigma*dens);
            ss += mask * (1.0f - a) * (0.86f + 0.14f*phase);
            T *= a;
        }{
            float h=0.5625f + jitter;
            float env=smoothstep(0.06f,0.40f,h)*(1.0f-smoothstep(0.58f,0.98f,h));
            float dens = mask * env * 1.25f;
            float a = exp(-kSigma*dens);
            ss += mask * (1.0f - a) * (0.86f + 0.14f*phase);
            T *= a;
        }{
            float h=0.6875f + jitter;
            float env=smoothstep(0.06f,0.40f,h)*(1.0f-smoothstep(0.58f,0.98f,h));
            float dens = mask * env * 1.25f;
            float a = exp(-kSigma*dens);
            ss += mask * (1.0f - a) * (0.86f + 0.14f*phase);
            T *= a;
        }{
            float h=0.8125f + jitter;
            float env=smoothstep(0.06f,0.40f,h)*(1.0f-smoothstep(0.58f,0.98f,h));
            float dens = mask * env * 1.25f;
            float a = exp(-kSigma*dens);
            ss += mask * (1.0f - a) * (0.86f + 0.14f*phase);
            T *= a;
        }{
            float h=0.9375f + jitter;
            float env=smoothstep(0.06f,0.40f,h)*(1.0f-smoothstep(0.58f,0.98f,h));
            float dens = mask * env * 1.25f;
            float a = exp(-kSigma*dens);
            ss += mask * (1.0f - a) * (0.86f + 0.14f*phase);
            T *= a;
        }

        // Roundness emphasis in lighting/alpha (centre > rim).
        float2 d = uv - float2(0.5f, 0.5f);
        float  r = clamp(length(d) * 2.0f, 0.0f, 1.0f);
        float  roundBoost = 1.0f - smoothstep(0.55f, 1.00f, r);

        float alphaOut = clamp(mask * (1.0f - pow(T, 0.58f)) * (0.85f + 0.35f * roundBoost), 0.0f, 1.0f);

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

        // Sprite sampling: nearest mip to honour the hard 2-px transparent frame.
        m.diffuse.wrapS = .clamp
        m.diffuse.wrapT = .clamp
        m.diffuse.mipFilter = .nearest
        m.diffuse.minificationFilter = .linear
        m.diffuse.magnificationFilter = .linear
        m.diffuse.maxAnisotropy = 4.0

        // Defaults; engine can override.
        m.setValue(SCNVector3(0, 0, 1),         forKey: "sunDirView")
        m.setValue(SCNVector3(1.0, 0.94, 0.82), forKey: "sunTint")
        m.setValue(0.42 as CGFloat,             forKey: "coverage")
        m.setValue(2.40 as CGFloat,             forKey: "densityMul")
        m.setValue(0.95 as CGFloat,             forKey: "stepMul")
        m.setValue(0.14 as CGFloat,             forKey: "horizonLift")
        return m
    }

    static var volumetricMarker: String { marker }
}
