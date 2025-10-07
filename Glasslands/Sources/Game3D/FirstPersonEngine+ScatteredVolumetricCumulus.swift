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

    /// Use true volumetric vapour, scattered into fluffy cumulus "islands".
    /// Call once after the sky is built (e.g. at the end of resetWorld/buildSky).
    @MainActor
    func useScatteredVolumetricCumulus(
        baseY: CGFloat = 400,          // cloud base altitude
        topY: CGFloat = 1400,          // cloud top altitude
        coverage: CGFloat = 0.34,      // global fill (kept modest so blue breaks through)
        densityMul: CGFloat = 1.10,    // thickness
        stepMul: CGFloat = 0.70,       // quality↔speed (lower = faster)
        horizonLift: CGFloat = 0.10,   // subtle lift near horizon for readability
        detailMul: CGFloat = 0.90,     // erosion detail
        puffScale: CGFloat = 0.0048,   // micro-puff size (smaller → finer cauliflower)
        puffStrength: CGFloat = 0.62,  // micro-puff influence
        // Scatter controls: very low-frequency "macro islands" that gate where vapour exists
        macroScale: CGFloat = 0.00035, // larger islands when smaller value; tune per taste
        macroThreshold: CGFloat = 0.58 // higher → fewer islands (more blue sky)
    ) {
        // Ensure the volumetric layer (inside-out sky slab) exists.
        installVolumetricCloudsIfMissing(baseY: baseY, topY: topY, coverage: coverage)

        // Make sure any billboard impostors are disabled.
        enableVolumetricCloudImpostors(false)

        // Configure the live uniform buffer the Metal shader reads each frame.
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

        // Push current sun direction into billboard fallback materials too (harmless if none).
        applyCloudSunUniforms()
    }
}
