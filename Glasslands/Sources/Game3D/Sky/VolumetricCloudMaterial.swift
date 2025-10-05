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
        // Minimal fragment-stage shader: sky gradient + HDR sun glow.
        // No scn_frame usage; no per-frame Swift bindings required.
        let fragment = """
        #pragma transparent
        #pragma arguments
        float3 sunDirView;   // unit vector in view space (fed from Swift each frame)
        float3 sunTint;      // e.g. warm white like 1.00,0.94,0.82

        #pragma body
        // View-space: _surface.view points from fragment toward camera.
        // Ray from camera to fragment is the opposite.
        float3 V  = normalize(_surface.view);
        float3 rd = normalize(-V);
        float3 sunV = normalize(sunDirView);

        // Sky gradient
        float tSky     = clamp(rd.y * 0.6 + 0.4, 0.0, 1.0);
        float3 zenith  = float3(0.30, 0.56, 0.96);
        float3 horizon = float3(0.88, 0.93, 0.99);
        float3 col     = horizon + (zenith - horizon) * tSky;

        // HDR sun disc + halos (values > 1.0 on HDR displays)
        float ct   = clamp(dot(rd, sunV), -1.0, 1.0);
        float ang  = acos(ct);
        const float rad = 0.95 * 0.017453292519943295; // ~1°

        float core  = 1.0 - smoothstep(rad*0.75, rad,        ang);
        float halo1 = 1.0 - smoothstep(rad*1.25, rad*3.50,   ang);
        float halo2 = 1.0 - smoothstep(rad*3.50, rad*7.50,   ang);
        float edr   = core * 5.0 + halo1 * 0.90 + halo2 * 0.25;

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

        // Defaults; engine keeps sunDirView updated each frame
        m.setValue(SCNVector3(0, 1, 0), forKey: "sunDirView")
        m.setValue(SCNVector3(1.00, 0.94, 0.82), forKey: "sunTint")
        return m
    }
}
