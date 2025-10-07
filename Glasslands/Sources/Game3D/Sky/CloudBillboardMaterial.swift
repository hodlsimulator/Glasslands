//
//  CloudBillboardMaterial.swift
//  Glasslands
//
//  Created by . . on 10/4/25.
//
//  Magenta-proof billboard puffs.
//  – No texture sampling (can’t hit pink “missing texture” path)
//  – Forward HG lobe + tiny sky backscatter so backlit puffs don’t go black
//  – Analytic silhouette; tiny math; no loops over textures
//

import SceneKit
import UIKit

enum CloudBillboardMaterial {

    /// Marker string used by code that probes material shader text.
    static let volumetricMarker = "/* VOL_IMPOSTOR_VSAFE_091_ANALYTIC */"

    /// Legacy API kept for compatibility with existing calls.
    @MainActor
    static func makeVolumetricImpostor() -> SCNMaterial { makeAnalyticPuff() }

    /// Convenience used elsewhere.
    @MainActor
    static func makeCurrent() -> SCNMaterial { makeAnalyticPuff() }

    @MainActor
    static func makeAnalyticPuff() -> SCNMaterial {
        let fragment = """
        \(volumetricMarker)
        #pragma transparent
        #pragma arguments
        float3 sunDirView;   // sun dir in view space
        float3 sunTint;      // linear RGB
        float  edgeSoft;     // 0.01..0.20
        float  skyBackK;     // 0..1 backscatter lift
        float  densityMul;   // 0.5..3 (thickness)
        #pragma body

        // Analytic circular mask with AA
        float2 uv = _surface.diffuseTexcoord;
        float2 c  = (uv - float2(0.5, 0.5)) * 2.0;
        float  r  = length(c);
        float  w  = max(1e-5, fwidth(r)) * edgeSoft;
        float  alpha = 1.0 - smoothstep(1.0 - w, 1.0 + w, r);
        if (alpha < 0.002) { discard_fragment(); }

        // Lighting
        float3 V = normalize(-_surface.view);
        float3 S = normalize(sunDirView);
        float  mu = clamp(dot(V,S), -1.0, 1.0);

        // Henyey–Greenstein forward lobe (single scattering proxy)
        float  g  = 0.56;
        float  g2 = g*g;
        float  hg = (1.0 - g2) / (4.0 * 3.14159265 * pow(1.0 + g2 - 2.0*g*mu, 1.5));

        // Tiny Rayleigh-like backscatter so backlit puffs don’t crush
        float  ray = (3.0 / (16.0 * 3.14159265)) * (1.0 + mu*mu);
        float  sky = clamp(skyBackK, 0.0, 1.0) * ray * 0.6;

        float  dens = clamp(densityMul, 0.5, 3.0);
        float  shade = 1.0 - exp(-dens * 0.7);   // simple thickness response

        float3 C = sunTint * (hg * shade + sky * alpha);
        _output.color = float4(clamp(C, 0.0, 1.0), alpha);
        """

        let m = SCNMaterial()
        m.lightingModel = .constant
        m.isDoubleSided = false
        m.cullMode = .back
        m.readsFromDepthBuffer = false
        m.writesToDepthBuffer = false
        m.blendMode = .alpha
        m.transparencyMode = .aOne
        m.shaderModifiers = [.fragment: fragment]

        // Sane defaults; engine updates each frame
        m.setValue(SCNVector3(0, 0, 1),         forKey: "sunDirView")
        m.setValue(SCNVector3(1.0, 0.96, 0.90), forKey: "sunTint")
        m.setValue(0.06 as CGFloat,             forKey: "edgeSoft")
        m.setValue(0.22 as CGFloat,             forKey: "skyBackK")
        m.setValue(1.60 as CGFloat,             forKey: "densityMul")
        return m
    }
}
