//
//  VolumetricCloudMaterial.swift
//  Glasslands
//
//  Created by . . on 10/5/25.
//
//  In-scene volumetric cumulus: fast ray-march, height-shaped FBM, domain warping,
//  soft single-scattering, powder effect, wind advection. Fragment-only shader
//  modifier; draws on an inward-facing sphere around the camera.
//

import SceneKit
import UIKit

enum VolumetricCloudMaterial {
    @MainActor
    static func makeMaterial() -> SCNMaterial {
        // Ultra-stable fragment-stage shader: deep sky + HDR sun.
        // No helper functions, no loops, no scn_frame, so it won't pink-screen.
        let fragment = """
        #pragma transparent
        #pragma arguments
        float3 sunDirView;   // view-space unit vector (fed from Swift)
        float3 sunTint;      // e.g. 1.00,0.94,0.82
        float3 skyZenith;    // deep sky blue
        float3 skyHorizon;   // horizon blue (avoid white)
        float  sunEDRCore;   // 5..8: HDR punch for sun core

        #pragma body
        // In fragment stage: _surface.view points from fragment -> camera.
        // Ray from camera to fragment is the opposite.
        float3 V  = normalize(_surface.view);
        float3 rd = normalize(-V);
        float3 sunV = normalize(sunDirView);

        // Cooler, deeper sky; bias reduces 'too white' look
        float tSky = clamp(rd.y * 0.62 + 0.30, 0.0, 1.0);
        float3 col = mix(skyHorizon, skyZenith, tSky);

        // Analytic HDR sun (disc + halos)
        float ct  = clamp(dot(rd, sunV), -1.0, 1.0);
        float ang = acos(ct);
        const float rad = 0.95 * 0.017453292519943295; // ~1°

        float core  = 1.0 - smoothstep(rad*0.75, rad,        ang);
        float halo1 = 1.0 - smoothstep(rad*1.25, rad*3.50,   ang);
        float halo2 = 1.0 - smoothstep(rad*3.50, rad*7.50,   ang);
        float edr   = core * sunEDRCore + halo1 * 0.90 + halo2 * 0.25;

        col += sunTint * edr;

        _output.color = float4(col, 1.0);
        """

        let m = SCNMaterial()
        m.lightingModel = .constant
        m.isDoubleSided = true
        m.blendMode = .alpha
        m.transparencyMode = .aOne
        m.readsFromDepthBuffer = false
        m.writesToDepthBuffer = false
        m.shaderModifiers = [.fragment: fragment]

        // Sensible defaults — engine updates sunDirView every frame.
        m.setValue(SCNVector3(0, 1, 0),          forKey: "sunDirView")
        m.setValue(SCNVector3(1.00, 0.94, 0.82), forKey: "sunTint")
        m.setValue(SCNVector3(0.10, 0.28, 0.65), forKey: "skyZenith")    // deeper
        m.setValue(SCNVector3(0.55, 0.72, 0.94), forKey: "skyHorizon")   // less white
        m.setValue(7.0 as CGFloat,               forKey: "sunEDRCore")   // bright core
        return m
    }
}
