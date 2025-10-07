//
//  CloudBillboardMaterial.swift
//  Glasslands
//
//  Created by . . on 10/4/25.
//
//  Analytic, magenta-proof billboard puffs (no texture sampling).
//  Clouds are WHITE and lit only by the sun (Henyey–Greenstein forward lobe).
//  No ambient/backscatter: the sun alone determines brightness.
//
//  Tunables:
//  – hgG       : anisotropy (0..0.95) — higher = tighter lobe
//  – baseWhite : base whiteness floor (0..1)
//  – hiGain    : highlight gain from HG lobe (0..1)
//  – edgeSoft  : silhouette softening (0.02..0.15)
//

import SceneKit
import UIKit

enum CloudBillboardMaterial {

    static let volumetricMarker = "/* VOL_IMPOSTOR_VSAFE_093_WHITE_SUN_ONLY */"

    @MainActor
    static func makeVolumetricImpostor() -> SCNMaterial { makeAnalyticWhitePuff() }

    @MainActor
    static func makeAnalyticWhitePuff() -> SCNMaterial {
        let frag = """
        \(volumetricMarker)
        #pragma transparent
        #pragma arguments
        float3 sunDirView;   // sun direction in view space
        float  hgG;          // 0..0.95
        float  baseWhite;    // 0..1
        float  hiGain;       // 0..1
        float  edgeSoft;     // 0.02..0.15
        #pragma body

        // Analytic circular mask with AA
        float2 uv = _surface.diffuseTexcoord;
        float2 c  = (uv - float2(0.5, 0.5)) * 2.0;
        float  r  = length(c);
        float  w  = max(1e-5, fwidth(r)) * edgeSoft;
        float  alpha = 1.0 - smoothstep(1.0 - w, 1.0 + w, r);
        if (alpha < 0.002) { discard_fragment(); }

        // Lighting (sun only): Henyey–Greenstein forward lobe
        float3 V = normalize(-_surface.view);
        float3 S = normalize(sunDirView);
        float  mu = clamp(dot(V,S), -1.0, 1.0);
        float  g  = clamp(hgG, 0.0, 0.95);
        float  g2 = g*g;
        float  hg = (1.0 - g2) / (4.0 * 3.14159265 * pow(1.0 + g2 - 2.0*g*mu, 1.5));

        // White clouds: floor + highlight; hard clamp to [0,1]
        float  L = clamp(baseWhite + hiGain * hg, 0.0, 1.0);
        float3 C = float3(L);

        _output.color = float4(C, alpha);
        """

        let m = SCNMaterial()
        m.lightingModel = .constant
        m.isDoubleSided = false
        m.cullMode = .back
        m.readsFromDepthBuffer = false
        m.writesToDepthBuffer = false
        m.blendMode = .alpha
        m.transparencyMode = .aOne
        m.shaderModifiers = [.fragment: frag]

        // Bright, safe defaults (engine updates per frame)
        m.setValue(SCNVector3(0, 0, 1), forKey: "sunDirView")
        m.setValue(0.56 as CGFloat,     forKey: "hgG")
        m.setValue(0.72 as CGFloat,     forKey: "baseWhite") // whiteness floor
        m.setValue(0.55 as CGFloat,     forKey: "hiGain")    // sun highlight gain
        m.setValue(0.06 as CGFloat,     forKey: "edgeSoft")
        return m
    }
}
