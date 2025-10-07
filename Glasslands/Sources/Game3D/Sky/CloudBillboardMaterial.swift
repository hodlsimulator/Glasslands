//
//  CloudBillboardMaterial.swift
//  Glasslands
//
//  Created by . . on 10/4/25.
//
//  Volumetric impostor for billboard puffs with NO texture sampling.
//  – Sun-only single scattering (HG) + compact self-occlusion
//  – Small Rayleigh-like backscatter so backlit puffs never go black
//  – Analytic silhouette (superellipse + lobes + micro scallops)
//

import SceneKit
import UIKit

enum CloudBillboardMaterial {

    @MainActor
    static func makeCurrent() -> SCNMaterial { makeVolumetricImpostor() }

    static let volumetricMarker = "/* VOL_IMPOSTOR_VSAFE_091_ANALYTIC */"

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
        float  skyBackK;       // 0..1
        #pragma body

        float2 uv = _surface.diffuseTexcoord;

        // Analytic radial coords (sprite centred at 0,0)
        float2 c = (uv - float2(0.5, 0.5)) * 2.0;
        float r  = length(c);
        float ang = atan2(c.y, c.x);
        float w = max(1e-5, fwidth(r)) * 1.5;

        // Superellipse guard (rounded square)
        float n = 3.5, guardScale = 1.10;
        float px = abs(c.x) / guardScale, py = abs(c.y) / guardScale;
        float superv = pow(px, n) + pow(py, n);
        float maskGuard = 1.0 - smoothstep(1.0 - w, 1.0 + w, superv);

        // Shape lobes + gravity bulge
        float l2 = sin(ang * 2.0 + 1.10);
        float l3 = sin(ang * 3.0 - 0.70);
        float l5 = sin(ang * 5.0 + 2.40);
        float lobes = (0.55*l2 + 0.35*l3 + 0.10*l5);
        float down = clamp(-c.y, 0.0, 1.0);
        float baseBulge = gravK * down * down;

        // Micro scallops (analytic, no textures)
        float seed = fract(sin(dot(uv, float2(12.9898, 78.233))) * 43758.5453);
        float t = ang + seed * 6.28318;
        float micro = 0.58 * sin(t * 9.0) + 0.36 * sin(t * 13.0 + 1.7) + 0.22 * sin(t * 17.0 - 0.9);
        micro *= (0.65 + 0.45 * down);

        float rMax = 1.0 + protrude * (0.55*baseBulge + lobeAmp * lobes) + microAmp * micro;

        // Radial silhouette with AA
        float maskLobed = 1.0 - smoothstep(rMax - w, rMax + w, r);

        // Sprite presence mask (acts like old texture alpha)
        float mask = maskGuard * maskLobed;
        if (mask < 0.002) { discard_fragment(); }

        // Lighting: view & sun in view space
        float3 V = normalize(-_surface.view);
        float3 S = normalize(sunDirView);
        float mu = clamp(dot(V, S), -1.0, 1.0);

        // HG forward lobe, small Rayleigh backscatter
        float g = 0.56, gg = g*g;
        float phaseHG = (1.0 - gg) / (4.0 * 3.14159265 * pow(1.0 + gg - 2.0*g*mu, 1.5));
        float phaseRay = (3.0 / (16.0 * 3.14159265)) * (1.0 + mu*mu);
        float skyBack = clamp(skyBackK, 0.0, 1.0) * phaseRay;

        // Cheap density & self-occlusion model
        float q  = clamp(stepMul, 0.7, 1.5);
        float vap = clamp(densityMul, 0.5, 4.0);
        float kSigma = (0.42 * q / 8.0) * (0.9 + 1.4 * vap);

        float edge = smoothstep(rMax - 0.12, rMax + 0.02, r);
        float microPos = max(micro, 0.0);
        float vapourSoft = 1.0 - microVapourK * edge * microPos;

        float T = 1.0;  // transmittance
        float ss = 0.0; // single-scatter strength

        // 6 slices stratified
        [unroll] for (int i=0; i<6; ++i) {
            float h = (0.08 + 0.14*float(i));
            float env = smoothstep(0.06,0.40,h) * (1.0 - smoothstep(0.58,0.98,h));
            env *= (0.80 + gravK * pow(1.0 - h, 2.0));
            float dens = mask * env * 1.28 * vapourSoft;

            float a = exp(-kSigma * dens);
            ss += mask * (1.0 - a) * phaseHG;
            T *= a;
        }

        float alphaOut = clamp(mask * (1.0 - pow(T, 0.56)), 0.0, 1.0);

        // Colour: forward HG plus small sky backscatter (scaled by opacity)
        float3 C = sunTint * (ss + skyBack * alphaOut * 0.6);

        // Gentle horizon lift for readability
        C += float3(horizonLift * (1.0 - uv.y) * 0.06) * alphaOut;

        _output.color = float4(clamp(C * alphaOut, 0.0, 1.0), alphaOut);
        """

        let m = SCNMaterial()
        m.lightingModel = .constant
        m.blendMode = .alpha
        m.transparencyMode = .aOne
        m.isDoubleSided = false
        m.readsFromDepthBuffer = false
        m.writesToDepthBuffer = false
        m.shaderModifiers = [.fragment: fragment]

        // Defaults (engine updates each frame)
        m.setValue(SCNVector3(0, 0, 1), forKey: "sunDirView")
        m.setValue(SCNVector3(1.0, 0.94, 0.82), forKey: "sunTint")
        m.setValue(0.42 as CGFloat, forKey: "coverage")
        m.setValue(2.20 as CGFloat, forKey: "densityMul")
        m.setValue(0.95 as CGFloat, forKey: "stepMul")
        m.setValue(0.12 as CGFloat, forKey: "horizonLift")
        m.setValue(0.16 as CGFloat, forKey: "protrude")
        m.setValue(0.24 as CGFloat, forKey: "lobeAmp")
        m.setValue(1.00 as CGFloat, forKey: "gravK")
        m.setValue(0.14 as CGFloat, forKey: "microAmp")
        m.setValue(0.45 as CGFloat, forKey: "microVapourK")
        m.setValue(0.22 as CGFloat, forKey: "skyBackK")     // prevents backlit black
        return m
    }
}
