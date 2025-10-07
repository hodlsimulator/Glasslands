//
//  SkyAtmosphereMaterial.swift
//  Glasslands
//
//  Created by . . on 10/7/25.
//
//  Robust sky gradient as a fragment shader-modifier (no SCNProgram/binders).
//  Lit only by the sun; uses world position only so it cannot fail on device.
//

import SceneKit
import UIKit

enum SkyAtmosphereMaterial {
    static func make() -> SCNMaterial {
        let frag = """
        #pragma transparent
        #pragma arguments
        float3 sunDirWorld;
        float3 sunTint;
        float  horizonLift;   // 0..1 (small lift near horizon)
        #pragma body

        // Normalised "up" from world origin gives us a stable elevation
        float3 P = normalize(_surface.position);
        float elev = clamp(P.y * 0.5 + 0.5, 0.0, 1.0);

        // Very light-weight Rayleigh-ish gradient
        float3 zenith  = float3(0.10, 0.30, 0.68);
        float3 horizon = float3(0.72, 0.85, 0.98);
        float t = pow(elev, 1.25);
        float3 sky = mix(horizon, zenith, t);

        // Tiny sun halo (helps readability; cheap and safe)
        float s = clamp(dot(normalize(_surface.position), normalize(sunDirWorld)), 0.0, 1.0);
        sky += sunTint * pow(s, 240.0) * 0.85;

        // Horizon lift for legibility
        sky += float3(0.06, 0.08, 0.10) * clamp(horizonLift, 0.0, 1.0) * (1.0 - t);

        _output.color = float4(clamp(sky, 0.0, 1.0), 1.0);
        """

        let m = SCNMaterial()
        m.lightingModel = .constant
        m.cullMode = .front            // inside of the skydome
        m.readsFromDepthBuffer = false
        m.writesToDepthBuffer = false
        m.blendMode = .alpha
        m.shaderModifiers = [.fragment: frag]

        // Defaults; applyCloudSunUniforms updates each frame
        m.setValue(SCNVector3(0, 1, 0), forKey: "sunDirWorld")
        m.setValue(SCNVector3(1, 1, 1), forKey: "sunTint")
        m.setValue(0.12 as CGFloat,     forKey: "horizonLift")
        return m;
    }
}
