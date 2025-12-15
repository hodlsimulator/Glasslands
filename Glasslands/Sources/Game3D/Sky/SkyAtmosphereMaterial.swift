//
//  SkyAtmosphereMaterial.swift
//  Glasslands
//
//  Created by . . on 10/7/25.
//
//  Lightweight sky dome: world-anchored gradient + horizon haze + sun highlight.
//  Important: _surface.position is view-space in SceneKit shader modifiers, so we
//  convert to a world-space ray before computing haze. This keeps haze on the horizon.
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
        inline float sat(float x) { return clamp(x, 0.0, 1.0); }

        inline float3 safeNormalize(float3 v) {
            float l = length(v);
            return (l > 1.0e-6) ? (v / l) : float3(0.0, 1.0, 0.0);
        }

        #pragma body
        // SceneKit shader modifiers: _surface.position is in VIEW space.
        // Convert to a WORLD-space view ray so haze is anchored to the world horizon.
        float3 rdView  = safeNormalize(_surface.position);
        float3 rdLocal = safeNormalize((scn_node.inverseModelViewTransform * float4(rdView, 0.0)).xyz);
        float3 rdWorld = safeNormalize((scn_node.modelTransform * float4(rdLocal, 0.0)).xyz);

        float h = sat(rdWorld.y);                 // 0 at horizon, 1 at zenith
        float tZen = pow(h, 0.58);

        // Base sky gradient (blue zenith, brighter horizon).
        float3 horizonCol = float3(0.68, 0.84, 0.99);
        float3 zenithCol  = float3(0.06, 0.34, 0.94);
        float3 sky = mix(horizonCol, zenithCol, tZen);

        float lift = sat(horizonLift);
        float turb = sat((clamp(turbidity, 1.0, 10.0) - 1.0) / 9.0);

        // Narrow horizon haze band that does NOT follow camera tilt.
        // Wider haze when lift/turbidity are higher, but still confined near the horizon.
        float hazeWidth = 0.14 + 0.10 * lift + 0.06 * turb;
        float hazeEdge = 1.0 - smoothstep(0.00, hazeWidth, h);
        float haze = pow(hazeEdge, 2.35);

        float3 hazeCol = float3(0.90, 0.94, 1.00);
        float hazeAmt = 0.22 + 0.10 * lift + 0.06 * turb;
        sky = mix(sky, hazeCol, haze * hazeAmt);

        // Sun highlight (world-anchored). Apply sunTint only to the highlight.
        float3 S = safeNormalize(sunDirWorld);
        float mu = sat(dot(rdWorld, S));
        float g = clamp(mieG, 0.0, 0.95);

        float corePow = mix(520.0, 900.0, g);
        float haloPow = mix(22.0, 55.0, g);

        float sunCore = pow(mu, corePow);
        float sunHalo = pow(mu, haloPow) * 0.16;

        float3 tint = clamp(sunTint, 0.0, 10.0);
        float maxC = max(tint.x, max(tint.y, tint.z));
        float3 tintHue = (maxC > 1.0e-5) ? (tint / maxC) : float3(1.0, 1.0, 1.0);
        float sunGain = maxC;

        float3 sunCol = float3(1.00, 0.96, 0.88) * tintHue;
        sky += sunCol * (sunCore * 1.05 + sunHalo * 0.25) * sunGain;

        // Exposure tone-map (cheap).
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

        m.setValue(NSValue(scnVector3: SCNVector3(0, 1, 0)), forKey: "sunDirWorld")
        m.setValue(NSValue(scnVector3: SCNVector3(1.0, 1.0, 1.0)), forKey: "sunTint")
        m.setValue(NSNumber(value: Float(3.0)), forKey: "turbidity")
        m.setValue(NSNumber(value: Float(0.70)), forKey: "mieG")
        m.setValue(NSNumber(value: Float(1.25)), forKey: "skyExposure")
        m.setValue(NSNumber(value: Float(0.30)), forKey: "horizonLift")

        return m
    }
}
