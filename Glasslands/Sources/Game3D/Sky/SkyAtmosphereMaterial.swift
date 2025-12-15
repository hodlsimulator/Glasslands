//
//  SkyAtmosphereMaterial.swift
//  Glasslands
//
//  Created by . . on 10/7/25.
//
//  Lightweight sky dome: simple gradient + horizon haze + sun highlight.
//  Designed to be stable (no horizon seam) and cheap on-device.
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

        // Map view elevation smoothly into a zenith factor (0 near horizon, 1 at zenith).
        // Using smoothstep avoids a hard seam/band around V.y == 0.
        float tSky = sat(V.y * 0.5 + 0.5);
        float tZen = smoothstep(0.47, 1.0, tSky);

        // Base gradient (sRGB-ish constants; final output remains SDR 0..1).
        float3 horizonCol = float3(0.88, 0.93, 0.99);
        float3 zenithCol  = float3(0.30, 0.56, 0.96);

        float3 sky = mix(horizonCol, zenithCol, pow(tZen, 0.85));

        // Milky horizon haze, fading out towards zenith.
        float haze = pow(1.0 - tZen, 2.8);

        float lift = sat(horizonLift);
        float turb = sat((clamp(turbidity, 1.0, 10.0) - 1.0) / 9.0);

        float3 hazeCol = float3(0.96, 0.97, 1.00);
        float hazeAmt = (0.28 + 0.22 * lift) + turb * 0.10;
        sky = mix(sky, hazeCol, haze * hazeAmt);

        // Sun highlight (warm), controlled a little by mieG (higher g = tighter forward peak).
        float mu = sat(dot(V, S));
        float g = clamp(mieG, 0.0, 0.95);

        float corePow = mix(520.0, 900.0, g);
        float haloPow = mix(22.0, 55.0, g);

        float sunCore = pow(mu, corePow);
        float sunHalo = pow(mu, haloPow) * 0.18;

        sky += float3(1.00, 0.96, 0.88) * (sunCore * 1.15 + sunHalo);

        float3 tint = clamp(sunTint, 0.0, 10.0);
        sky *= tint;

        // Tone map (single exp is fine here; much cheaper than multiple optical-depth exp calls).
        float e = max(skyExposure, 0.0);
        sky = 1.0 - exp(-sky * e);

        _output.color = float4(clamp(sky, 0.0, 1.0), 1.0);
        """

        let m = SCNMaterial()
        m.lightingModel = .constant
        m.isDoubleSided = false
        m.cullMode = .front

        // Sky is a background pass: opaque, no depth interactions.
        m.blendMode = .replace
        m.transparencyMode = .aOne
        m.readsFromDepthBuffer = false
        m.writesToDepthBuffer = false
        m.isLitPerPixel = false

        m.shaderModifiers = [.fragment: frag]

        // Defaults (non-zero exposure; otherwise sky can go black).
        m.setValue(NSValue(scnVector3: SCNVector3(0, 1, 0)), forKey: "sunDirWorld")
        m.setValue(NSValue(scnVector3: SCNVector3(1.0, 1.0, 1.0)), forKey: "sunTint")
        m.setValue(NSNumber(value: Float(3.0)), forKey: "turbidity")
        m.setValue(NSNumber(value: Float(0.70)), forKey: "mieG")
        m.setValue(NSNumber(value: Float(1.10)), forKey: "skyExposure")
        m.setValue(NSNumber(value: Float(0.35)), forKey: "horizonLift")

        return m
    }
}
