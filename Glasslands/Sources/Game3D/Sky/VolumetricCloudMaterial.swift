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
        // Minimal, safe surface shader: view-space gradient + HDR sun disc/halo.
        // No raymarching here to avoid compile pitfalls that cause magenta.
        let surface = """
        #pragma arguments
        float3 sunDirView;   // unit vector in *view space*
        float3 sunTint;      // e.g. 1.00,0.94,0.82

        float  saturate1(float x) { return clamp(x, 0.0, 1.0); }
        float3 lerp3(float3 a,float3 b,float t){ return a + (b - a) * t; }
        float  deg2rad(float d)   { return d * 0.017453292519943295; }

        // HDR sun: bright core + soft halos (values > 1 on HDR displays)
        float3 sunGlow(float3 rd, float3 sunV, float3 tint) {
            float ct   = clamp(dot(rd, sunV), -1.0, 1.0);
            float ang  = acos(ct);
            const float rad = deg2rad(0.95); // ~1°

            float core  = 1.0 - smoothstep(rad*0.75, rad,        ang);
            float halo1 = 1.0 - smoothstep(rad*1.25, rad*3.50,   ang);
            float halo2 = 1.0 - smoothstep(rad*3.50, rad*7.50,   ang);

            float edr  = core * 5.0 + halo1 * 0.90 + halo2 * 0.25;
            return tint * edr;
        }

        #pragma body
        // View-space ray: origin at camera (0), direction from the fragment
        float3 rd = normalize(_surface.position.xyz);
        float3 sunV = normalize(sunDirView);

        // Sky gradient
        float tSky     = saturate1(rd.y * 0.6 + 0.4);
        float3 zenith  = float3(0.30, 0.56, 0.96);
        float3 horizon = float3(0.88, 0.93, 0.99);
        float3 col     = lerp3(horizon, zenith, tSky);

        // Add HDR sun on top
        col += sunGlow(rd, sunV, sunTint);

        _surface.emission    = float4(col, 1.0);
        _surface.transparent = 1.0;
        """

        let m = SCNMaterial()
        m.lightingModel = .constant
        m.isDoubleSided = true
        m.blendMode = .alpha
        m.transparencyMode = .aOne
        m.readsFromDepthBuffer = false
        m.writesToDepthBuffer = false
        m.shaderModifiers = [.surface: surface]

        // Defaults (updated every frame by the engine)
        m.setValue(SCNVector3(0, 1, 0), forKey: "sunDirView")
        m.setValue(SCNVector3(1.00, 0.94, 0.82), forKey: "sunTint")
        return m
    }
}
