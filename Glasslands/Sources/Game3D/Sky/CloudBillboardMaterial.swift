//
//  CloudBillboardMaterial.swift
//  Glasslands
//
//  Created by . . on 10/4/25.
//
//  Magenta-proof analytic billboards (no texture sampling).
//  – Henyey–Greenstein forward lobe (sun-only) to “light up” fronts
//  – Tiny Rayleigh back-scatter so backlit puffs aren't dark grey
//  – Small multiple-scattering lift tied to thickness (cheap)
//

import SceneKit
import UIKit

enum CloudBillboardMaterial {

    static let volumetricMarker = "/* VOL_IMPOSTOR_VSAFE_092_PHYS */"

    @MainActor
    static func makeVolumetricImpostor() -> SCNMaterial { makeAnalyticPuff() }

    @MainActor
    static func makeAnalyticPuff() -> SCNMaterial {
        let frag = """
        \(volumetricMarker)
        #pragma transparent
        #pragma arguments
        float3 sunDirView;   // sun dir in view space
        float3 sunTint;      // linear RGB
        float  edgeSoft;     // 0.02..0.15
        float  densityMul;   // 0.6..3.0  (thickness)
        float  skyBackK;     // 0..1      (Rayleigh back-scatter scale)
        float  msLiftK;      // 0..1      (multiple-scatter lift)
        float  mieG;         // 0..0.95   (forward bias)
        float  turbidity;    // 1..10     (for sky back colour)
        #pragma body

        // Analytic circular mask with AA
        float2 uv = _surface.diffuseTexcoord;
        float2 c  = (uv - float2(0.5, 0.5)) * 2.0;
        float  r  = length(c);
        float  w  = max(1e-5, fwidth(r)) * edgeSoft;
        float  alpha = 1.0 - smoothstep(1.0 - w, 1.0 + w, r);
        if (alpha < 0.002) { discard_fragment(); }

        // View & sun
        float3 V = normalize(-_surface.view);
        float3 S = normalize(sunDirView);
        float  mu = clamp(dot(V,S), -1.0, 1.0);

        // HG forward lobe: lights sun-facing sides
        float g  = clamp(mieG, 0.0, 0.95);
        float g2 = g*g;
        float hg = (1.0 - g2) / (4.0 * 3.14159265 * pow(1.0 + g2 - 2.0*g*mu, 1.5));

        // Very small Rayleigh back-scatter for backlit lift
        float  ray = (3.0 / (16.0 * 3.14159265)) * (1.0 + mu*mu);
        float  back = clamp(skyBackK, 0.0, 1.0) * ray * 0.6;

        // Cheap “thickness” → multiple scattering approximation
        float dens  = clamp(densityMul, 0.6, 3.0);
        float thick = 1.0 - exp(-dens * 0.7);
        float ms    = clamp(msLiftK, 0.0, 1.0) * (thick * thick);

        // Optional: tint the ambient lift a touch towards sky blue (Rayleigh bias)
        float3 skyBias = float3(0.55, 0.70, 1.00);

        float3 C = sunTint * (hg * thick)                      // forward light
                 + sunTint * back * alpha                      // back-light lift
                 + skyBias * ms * 0.25;                        // soft multi-scatter

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
        m.shaderModifiers = [.fragment: frag]

        // Sane midday defaults (engine will drive per-frame)
        m.setValue(SCNVector3(0, 0, 1),         forKey: "sunDirView")
        m.setValue(SCNVector3(1.0, 0.97, 0.92), forKey: "sunTint")
        m.setValue(0.06 as CGFloat,             forKey: "edgeSoft")
        m.setValue(1.40 as CGFloat,             forKey: "densityMul")
        m.setValue(0.22 as CGFloat,             forKey: "skyBackK")
        m.setValue(0.35 as CGFloat,             forKey: "msLiftK")
        m.setValue(0.56 as CGFloat,             forKey: "mieG")
        m.setValue(2.4  as CGFloat,             forKey: "turbidity")
        return m
    }
}
