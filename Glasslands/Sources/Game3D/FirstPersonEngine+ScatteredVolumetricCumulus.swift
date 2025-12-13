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

        // Balanced scattered cumulus: plenty of clouds with clear blue gaps.
        coverage: CGFloat = 0.52,

        // Chunky puffs without turning into an overcast sheet.
        densityMul: CGFloat = 1.30,

        // Moderate march budget (keeps softness without being heavy).
        stepMul: CGFloat = 0.92,

        // Slight lift keeps the horizon from becoming too grey under cloud.
        horizonLift: CGFloat = 0.10,

        // Cauliflower edges with enough breakup to avoid flat layers.
        detailMul: CGFloat = 0.94,

        // Micro-cell scale and strength.
        puffScale: CGFloat = 0.0043,
        puffStrength: CGFloat = 0.76,

        // Macro “islands” to keep clouds scattered rather than uniform.
        macroScale: CGFloat = 0.00042,
        macroThreshold: CGFloat = 0.63
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
