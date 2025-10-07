//
//  SkyAtmosphereMaterial.swift
//  Glasslands
//
//  Created by . . on 10/7/25.
//
//  Sky as a fragment shader-modifier (Rayleigh + Mie), no SCNProgram/binders.
//  Lit only by the sun. Designed for an inside-out sphere (cull .front).
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
        float  turbidity;
        float  mieG;
        float  exposure;
        float  horizonLift;
        #pragma body

        float3 V = normalize(_surface.view);                 // view dir
        float3 S = normalize(sunDirWorld);
        float  mu = clamp(dot(V, S), -1.0, 1.0);

        // Coefficients (approximate)
        float3 betaR = float3(5.802e-6, 13.558e-6, 33.1e-6); // Rayleigh
        float  betaM = 3.996e-6 * clamp(turbidity, 1.0, 10.0);

        // Elevation proxy (0 at horizon, 1 at zenith)
        float elev = clamp((V.y * 0.5) + 0.5, 0.0, 1.0);

        // Path length proxies (km-ish)
        float hr = mix(2.5, 0.8, elev);
        float hm = mix(1.2, 0.3, elev);

        float3 Tr = exp(-betaR * hr * 1.0e4);
        float3 Tm = exp(-betaM * hm * 1.0e4);

        // Phase functions
        float PR = (3.0 / (16.0 * 3.14159265)) * (1.0 + mu*mu);
        float g  = clamp(mieG, 0.0, 0.95);
        float g2 = g*g;
        float PM = (3.0 / (8.0 * 3.14159265)) * ((1.0 - g2) * (1.0 + mu*mu)) / ((2.0 + g2) * pow(1.0 + g2 - 2.0*g*mu, 1.5));

        float3 sunRGB = clamp(sunTint, 0.0, 10.0);
        float3 Lr = sunRGB * PR * (1.0 - Tr);
        float3 Lm = sunRGB * PM * (1.0 - Tm) * 0.9;

        float3 sky = Lr + Lm;

        // Horizon readability + slight blue bias
        float horizon = pow(1.0 - elev, 2.0) * clamp(horizonLift, 0.0, 1.0) * 0.6;
        sky += float3(0.05, 0.08, 0.16) * horizon;

        // Tone map
        float expK = max(exposure, 0.0);
        sky = 1.0 - exp(-sky * expK);

        _output.color = float4(clamp(sky, 0.0, 1.0), 1.0);
        """

        let m = SCNMaterial()
        m.lightingModel = .constant
        m.cullMode = .front          // inside of the skydome
        m.readsFromDepthBuffer = false
        m.writesToDepthBuffer = false
        m.blendMode = .alpha
        m.shaderModifiers = [.fragment: frag]

        // Defaults; engine drives these every frame via applyCloudSunUniforms()
        m.setValue(SCNVector3(0, 1, 0), forKey: "sunDirWorld")
        m.setValue(SCNVector3(1, 1, 1), forKey: "sunTint")
        m.setValue(2.5 as CGFloat,      forKey: "turbidity")
        m.setValue(0.60 as CGFloat,     forKey: "mieG")
        m.setValue(1.25 as CGFloat,     forKey: "exposure")
        m.setValue(0.12 as CGFloat,     forKey: "horizonLift")
        return m
    }
}
