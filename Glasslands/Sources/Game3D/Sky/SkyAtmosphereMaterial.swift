//
//  SkyAtmosphereMaterial.swift
//  Glasslands
//
//  Created by . . on 10/7/25.
//
//  Lightweight sky dome: simple gradient + horizon haze + sun highlight.
//  No horizon seam; keeps the sky blue by not applying cloud sun-tint to the entire dome.
//

import SceneKit
import UIKit

enum SkyAtmosphereMaterial {

    @MainActor
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

        inline float sat(float x) { return clamp(x, 0.0, 1.0); }

        #pragma body
        float3 V = safeNormalize(_surface.position);
        float3 S = safeNormalize(sunDirWorld);

        // View elevation mapped into a smooth 0..1 zenith factor (0 near horizon, 1 at zenith).
        float tSky = sat(V.y * 0.5 + 0.5);
        float tZen = smoothstep(0.47, 1.0, tSky);

        // Base gradient: deliberately bluer and less "milky" than the previous pass.
        float3 horizonCol = float3(0.58, 0.78, 0.98);
        float3 zenithCol  = float3(0.05, 0.30, 0.90);
        float3 sky = mix(horizonCol, zenithCol, pow(tZen, 0.65));

        float lift = sat(horizonLift);
        float turb = sat((clamp(turbidity, 1.0, 10.0) - 1.0) / 9.0);

        // Horizon haze: bright but still slightly blue.
        float haze = pow(1.0 - tZen, 2.4);
        float3 hazeCol = float3(0.80, 0.88, 0.99);
        float hazeAmt = (0.16 + 0.18 * lift) + turb * 0.08;
        sky = mix(sky, hazeCol, haze * hazeAmt);

        // Sun highlight: use sunTint ONLY for the highlight so cloud tint doesn't grey-out the whole sky.
        float mu = sat(dot(V, S));
        float g = clamp(mieG, 0.0, 0.95);

        float corePow = mix(520.0, 900.0, g);
        float haloPow = mix(22.0, 55.0, g);

        float sunCore = pow(mu, corePow);
        float sunHalo = pow(mu, haloPow) * 0.18;

        float3 tint = clamp(sunTint, 0.0, 10.0);
        float maxC = max(tint.x, max(tint.y, tint.z));
        float3 tintHue = (maxC > 1.0e-5) ? (tint / maxC) : float3(1.0, 1.0, 1.0);
        float sunGain = maxC;

        float3 sunCol = float3(1.00, 0.96, 0.88) * tintHue;
        sky += sunCol * (sunCore * 1.10 + sunHalo * 0.22) * sunGain;

        // Simple exposure tone-map.
        float e = max(skyExposure, 0.0);
        sky = 1.0 - exp(-sky * e);

        _output.color = float4(clamp(sky, 0.0, 1.0), 1.0);
        """

        let m = SCNMaterial()
        m.lightingModel = .constant
        m.isDoubleSided = false
        m.cullMode = .front

        m.blendMode = .replace
        m.transparencyMode = .aOne
        m.readsFromDepthBuffer = false
        m.writesToDepthBuffer = false
        m.isLitPerPixel = false

        m.shaderModifiers = [.fragment: frag]

        // Defaults (sunDirWorld + sunTint are overridden by applySkySunUniforms()).
        m.setValue(NSValue(scnVector3: SCNVector3(0, 1, 0)), forKey: "sunDirWorld")
        m.setValue(NSValue(scnVector3: SCNVector3(1.0, 1.0, 1.0)), forKey: "sunTint")
        m.setValue(NSNumber(value: Float(3.0)), forKey: "turbidity")
        m.setValue(NSNumber(value: Float(0.70)), forKey: "mieG")
        m.setValue(NSNumber(value: Float(1.25)), forKey: "skyExposure")
        m.setValue(NSNumber(value: Float(0.30)), forKey: "horizonLift")

        return m
    }
}
