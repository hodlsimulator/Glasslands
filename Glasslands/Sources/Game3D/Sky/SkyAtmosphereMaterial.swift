//
//  SkyAtmosphereMaterial.swift
//  Glasslands
//
//  Created by . . on 10/7/25.
//
//  Physics-inspired sky (Rayleigh + Mie) as a fragment shader-modifier.
//  Single-scatter + a cheap horizon-haze band so the horizon reads milky
//  while the zenith stays clean.
//

import SceneKit
import UIKit

enum SkyAtmosphereMaterial {

    @MainActor
    static func make() -> SCNMaterial {

        // Simple single-scatter approximation.
        // This version avoids the model-space transform path that can collapse into black
        // if the modifier variables/matrices end up invalid on-device.
        let frag = """
        #pragma arguments
        float3 sunDirWorld;
        float3 sunTint;
        float turbidity;
        float mieG;
        float skyExposure;
        float horizonLift;

        #pragma declaration
        inline float3 safeNormalize(float3 v) {
            float l = length(v);
            return (l > 1.0e-6) ? (v / l) : float3(0.0, 1.0, 0.0);
        }

        #pragma body

        // In SceneKit shader modifiers, _surface.position is in view space (camera at origin).
        // Normalising it gives a view ray direction.
        float3 V = safeNormalize(_surface.position);

        // Sun direction is provided in world space; normalise defensively.
        float3 S = safeNormalize(sunDirWorld);

        float mu = clamp(dot(V, S), -1.0, 1.0);

        // Mie phase function parameter.
        float g = clamp(mieG, 0.0, 0.99);
        float g2 = g * g;

        // Rayleigh coefficients (approx).
        float3 betaR = float3(5.8e-6, 13.5e-6, 33.1e-6);

        // Mie coefficients scaled by turbidity.
        float3 betaM = float3(3.996e-6 * clamp(turbidity, 1.0, 10.0));

        // Approximate optical depth by elevation.
        float elev = clamp(V.y, 0.0, 1.0);
        float e = pow(elev, 0.35);

        float rayHeight = mix(3.0, 1.0, e);
        float mieHeight = mix(6.5, 0.06, e);

        float3 Tr = exp(-betaR * rayHeight * 1.0e4);
        float3 Tm = exp(-betaM * mieHeight * 1.0e4);

        // Phase terms (constants chosen for decent-looking results).
        float PR = 0.05968310365946075 * (1.0 + mu * mu);
        float PM = 0.1193662073189215 * ((1.0 - g2) / pow(1.0 + g2 - 2.0 * g * mu, 1.5));

        float3 sunRGB = clamp(sunTint, 0.0, 10.0);

        float3 sky = sunRGB * (PR * (1.0 - Tr) + 0.9 * PM * mieHeight * (1.0 - Tm));

        // Simple horizon haze + optional lift.
        float horizon = 1.0 - elev;
        float haze = pow(horizon, 5.0);

        float lift = clamp(horizonLift, 0.0, 1.0);
        sky += haze * float3(0.03, 0.04, 0.06) * (0.6 + 0.4 * lift);

        // Tone mapping. skyExposure <= 0 yields black by design.
        sky = 1.0 - exp(-sky * max(skyExposure, 0.0));

        _output.color = float4(clamp(sky, 0.0, 1.0), 1.0);
        """

        let m = SCNMaterial()
        m.lightingModel = .constant
        m.isDoubleSided = false
        m.cullMode = .front

        // Treat as opaque to avoid transparency sorting overhead.
        m.blendMode = .replace
        m.transparencyMode = .aOne

        // Sky should not participate in depth.
        m.readsFromDepthBuffer = false
        m.writesToDepthBuffer = false

        m.isLitPerPixel = false
        m.shaderModifiers = [.fragment: frag]

        // Defaults (kept non-zero to avoid black output).
        m.setValue(NSValue(scnVector3: SCNVector3(0, 1, 0)), forKey: "sunDirWorld")
        m.setValue(NSValue(scnVector3: SCNVector3(1.0, 0.97, 0.92)), forKey: "sunTint")

        m.setValue(NSNumber(value: Float(3.5)), forKey: "turbidity")
        m.setValue(NSNumber(value: Float(0.76)), forKey: "mieG")

        // Non-zero exposure is critical; zero here makes the sky black.
        m.setValue(NSNumber(value: Float(2.8)), forKey: "skyExposure")

        m.setValue(NSNumber(value: Float(0.15)), forKey: "horizonLift")

        return m
    }
}
