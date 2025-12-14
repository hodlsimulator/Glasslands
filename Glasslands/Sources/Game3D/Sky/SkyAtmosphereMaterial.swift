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
    static func make() -> SCNMaterial {
        let frag = """
        #pragma arguments
        float3 sunDirWorld;
        float3 sunTint;
        float  turbidity;
        float  mieG;
        float  exposure;
        float  horizonLift;
        #pragma body

        float3 V = normalize(-_surface.view);     // inside-out skydome
        float3 S = normalize(sunDirWorld);
        float  mu = clamp(dot(V, S), -1.0, 1.0);

        // Coefficients (approximate, in 1/m)
        float3 betaR = float3(5.802e-6, 13.558e-6, 33.1e-6);
        float3 betaM = float3(3.996e-6 * clamp(turbidity, 1.0, 10.0));

        // Elevation above horizon (0=horizon, 1=zenith).
        // Shape the ramp so haze collapses towards the horizon instead of
        // washing the whole upper sky.
        float elev = clamp(V.y, 0.0, 1.0);
        float e    = pow(elev, 0.35);

        // Optical depth proxies.
        // - Rayleigh stays present up high for a deep blue.
        // - Mie collapses hard at zenith so the top sky stays clear.
        float hr = mix(3.0, 1.0, e);
        float hm = mix(6.5, 0.06, e);

        float3 Tr = exp(-betaR * hr * 1.0e4);
        float3 Tm = exp(-betaM * hm * 1.0e4);

        // Phase functions
        float PR = (3.0 / (16.0 * 3.14159265)) * (1.0 + mu * mu);
        float g  = clamp(mieG, 0.0, 0.95);
        float g2 = g * g;
        float PM = (3.0 / (8.0 * 3.14159265)) * ((1.0 - g2) * (1.0 + mu * mu))
                 / ((2.0 + g2) * pow(1.0 + g2 - 2.0 * g * mu, 1.5));

        float3 sunRGB = clamp(sunTint, 0.0, 10.0);

        // Reduce Mie contribution as elevation rises (keeps zenith clean).
        float mieHeight = mix(1.0, 0.12, e);

        float3 sky = sunRGB * (PR * (1.0 - Tr) + 0.9 * PM * mieHeight * (1.0 - Tm));

        // Horizon haze band: bright + slightly desaturated, confined low.
        // horizonLift becomes a strength knob (0..1).
        float hazeBand = pow(1.0 - elev, 6.0);
        float hazeK    = clamp(horizonLift, 0.0, 1.0) * hazeBand;
        float turb01   = clamp((clamp(turbidity, 1.0, 10.0) - 1.0) / 9.0, 0.0, 1.0);
        float hazeAmp  = (0.10 + 0.22 * turb01);
        sky += float3(0.85, 0.90, 1.00) * (hazeK * hazeAmp);

        // Tone mapping
        sky = 1.0 - exp(-sky * max(exposure, 0.0));

        _output.color = float4(clamp(sky, 0.0, 1.0), 1.0);
        """

        let m = SCNMaterial()
        m.lightingModel = .constant
        m.cullMode = .front
        m.readsFromDepthBuffer = false
        m.writesToDepthBuffer = false
        m.blendMode = .replace
        m.shaderModifiers = [.fragment: frag]

        // Defaults tuned for a clear-ish day with visible horizon haze.
        m.setValue(SCNVector3(0, 1, 0),          forKey: "sunDirWorld")
        m.setValue(SCNVector3(1.0, 0.97, 0.92),  forKey: "sunTint")
        m.setValue(3.5  as CGFloat,              forKey: "turbidity")
        m.setValue(0.46 as CGFloat,              forKey: "mieG")
        m.setValue(3.25 as CGFloat,              forKey: "exposure")
        m.setValue(0.70 as CGFloat,              forKey: "horizonLift")
        return m
    }
}
