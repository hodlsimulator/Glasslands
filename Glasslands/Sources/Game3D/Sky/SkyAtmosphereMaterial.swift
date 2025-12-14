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
        // Convert the view direction into model space so the horizon haze stays stable against camera pitch.
        float3 Vv = safeNormalize(_surface.position);
        float3 V  = safeNormalize((scn_node.inverseModelViewTransform * float4(Vv, 0.0)).xyz);

        // Convert world sun direction into the same space as V.
        float3 S  = safeNormalize((scn_node.inverseModelTransform * float4(sunDirWorld, 0.0)).xyz);

        float mu = clamp(dot(V, S), -1.0, 1.0);

        // Coefficients (approximate, in 1/m)
        float3 betaR = float3(5.802e-6, 13.558e-6, 33.1e-6);
        float3 betaM = float3(3.996e-6 * clamp(turbidity, 1.0, 10.0));

        // Elevation above horizon (0=horizon, 1=zenith).
        // Shape the ramp so haze collapses towards the horizon instead of
        // washing the whole upper sky.
        float elev = clamp(V.y, 0.0, 1.0);
        float e = pow(elev, 0.35);

        // Optical depth proxies.
        // - Rayleigh stays present up high for a deep blue.
        // - Mie collapses hard at zenith so the top sky stays clear.
        float hr = mix(3.0, 1.0, e);
        float hm = mix(6.5, 0.06, e);

        float3 Tr = exp(-betaR * hr * 1.0e4);
        float3 Tm = exp(-betaM * hm * 1.0e4);

        // Phase functions
        float PR = (3.0 / (16.0 * 3.14159265)) * (1.0 + mu * mu);

        float g = clamp(mieG, 0.0, 0.95);
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
        float hazeK = clamp(horizonLift, 0.0, 1.0) * hazeBand;
        float turb01 = clamp((clamp(turbidity, 1.0, 10.0) - 1.0) / 9.0, 0.0, 1.0);
        float hazeAmp = (0.10 + 0.22 * turb01);
        sky += float3(0.85, 0.90, 1.00) * (hazeK * hazeAmp);

        // Tone mapping (black sky if skyExposure == 0)
        sky = 1.0 - exp(-sky * max(skyExposure, 0.0));

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
        m.setValue(NSValue(scnVector3: SCNVector3(0, 1, 0)), forKey: "sunDirWorld")
        m.setValue(NSValue(scnVector3: SCNVector3(1.0, 0.97, 0.92)), forKey: "sunTint")
        m.setValue(NSNumber(value: Float(3.5)), forKey: "turbidity")
        m.setValue(NSNumber(value: Float(0.46)), forKey: "mieG")
        m.setValue(NSNumber(value: Float(3.25)), forKey: "skyExposure")
        m.setValue(NSNumber(value: Float(0.70)), forKey: "horizonLift")

        return m
    }
}
