//
//  FirstPersonEngine+ScatteredVolumetricCumulus.swift
//  Glasslands
//
//  Created by . . on 10/7/25.
//
//  Keeps the volumetric vapour path and configures it for scattered cumulus.
//  No billboards; no circular impostors; all clouds are true vapour.
//

import SceneKit
import simd
import UIKit

extension FirstPersonEngine {
    @MainActor
    func useScatteredVolumetricCumulus(
        baseY: CGFloat = 400,
        topY: CGFloat = 1400,

        // ↓ Roughly halves overall vapour vs your current commit
        coverage: CGFloat = 0.44,        // was 0.62

        // ↓ Keeps puffs chunky but not “solid overcast”
        densityMul: CGFloat = 1.20,      // was 1.40

        // ↓ Small step count reduction for extra headroom
        stepMul: CGFloat = 0.88,         // was 1.00

        // ↓ Slightly more blue near the horizon
        horizonLift: CGFloat = 0.08,     // was 0.10

        // ↓ Preserve cauliflower edges; a touch less erosion than 0.85
        detailMul: CGFloat = 0.90,       // was 0.85

        // ↓ Similar micro-cell size and influence as before
        puffScale: CGFloat = 0.0043,     // was 0.0042
        puffStrength: CGFloat = 0.74,    // was 0.78

        // ↓ More, smaller “islands” with a stricter gate → scattered cumulus
        macroScale: CGFloat = 0.00044,   // was 0.00030
        macroThreshold: CGFloat = 0.62   // was 0.49
    ) {
        installVolumetricCloudsIfMissing(baseY: baseY, topY: topY, coverage: coverage)
        enableVolumetricCloudImpostors(false)

        VolCloudUniformsStore.shared.configure(
            baseY: Float(baseY),
            topY: Float(topY),
            coverage: Float(coverage),
            densityMul: Float(densityMul),
            stepMul: Float(stepMul),
            horizonLift: Float(horizonLift),
            detailMul: Float(detailMul),
            puffScale: Float(puffScale),
            puffStrength: Float(puffStrength),
            macroScale: Float(macroScale),
            macroThreshold: Float(macroThreshold)
        )

        applyCloudSunUniforms()
    }
}
