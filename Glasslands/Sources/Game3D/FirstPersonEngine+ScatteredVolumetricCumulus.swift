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
        coverage: CGFloat = 0.62,
        densityMul: CGFloat = 1.40,
        stepMul: CGFloat = 1.00,
        horizonLift: CGFloat = 0.10,
        detailMul: CGFloat = 0.85,
        puffScale: CGFloat = 0.0042,
        puffStrength: CGFloat = 0.78,
        macroScale: CGFloat = 0.00030,
        macroThreshold: CGFloat = 0.49
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
