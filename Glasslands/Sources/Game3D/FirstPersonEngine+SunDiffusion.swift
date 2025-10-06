//
//  FirstPersonEngine+SunDiffusion.swift
//  Glasslands
//
//  Created by . . on 10/6/25.
//

import SceneKit
import simd
import UIKit

extension FirstPersonEngine {

    @MainActor
    func updateSunDiffusion() {
        guard let sunNode = sunLightNode, let sun = sunNode.light else { return }

        let baseIntensity: CGFloat = 1500
        let baseShadowRadius: CGFloat = 2
        let maxExtraShadowRadius: CGFloat = 10
        let minSunFactor: CGFloat = 0.35

        let thickness: Float = estimateSunOcclusionThickness() // 0…1
        let tau: Float = simd_clamp(4.0 * thickness, 0.0, 6.0) // effective optical depth
        let T: CGFloat = CGFloat(expf(-tau))                   // transmittance

        let intensity = baseIntensity * max(minSunFactor, T)
        let shadowRadius = baseShadowRadius + (1.0 - T) * maxExtraShadowRadius
        let shadowAlpha: CGFloat = 0.35 + (1.0 - T) * 0.35

        sun.intensity = intensity
        sun.shadowRadius = shadowRadius

        let extraSamples = Int(((1.0 as CGFloat - T) * 8.0).rounded(.toNearestOrAwayFromZero))
        sun.shadowSampleCount = 4 + max(0, extraSamples)

        sun.shadowColor = UIColor(white: 0.0, alpha: shadowAlpha)
    }

    @MainActor
    func estimateSunOcclusionThickness() -> Float {
        guard !cloudBillboardNodes.isEmpty else { return 0.0 }

        let cam = yawNode.presentation.simdPosition
        let sunW = simd_normalize(sunDirWorld)
        let sunRadius: Float = degreesToRadians(6.0)

        var accum: Float = 0.0

        for bb in cloudBillboardNodes {
            let bp = bb.presentation.simdPosition
            let toP = simd_normalize(bp - cam)
            let cosAng = simd_clamp(simd_dot(sunW, toP), -1.0, 1.0)
            let dAngle = acosf(cosAng)

            guard
                let sprite = bb.childNodes.first,
                let plane = sprite.geometry as? SCNPlane
            else { continue }

            let distance: Float = simd_length(bp - cam)
            if distance <= 1e-3 { continue }

            let size: Float = Float(plane.width)
            let puffRadius: Float = Float(2) * atanf((size * Float(0.5)) / Swift.max(Float(1e-3), distance))

            let feather: Float = Float(0.75) * (Float.pi / Float(180)) // ~0.75°
            let overlap: Float = (puffRadius + sunRadius + feather) - dAngle
            if overlap <= 0 { continue }

            let denom: Float = Swift.max(Float(1e-3), puffRadius + sunRadius + feather)
            let t: Float = Swift.max(0.0, Swift.min(1.0, overlap / denom))

            let scaleBig: Float = size / (size + Float(30))
            let weight: Float = Float(bb.opacity) * t * scaleBig

            accum += weight
            if accum >= 1.0 { return 1.0 }
        }

        return Swift.max(0.0, Swift.min(1.0, accum))
    }

    @inline(__always)
    private func degreesToRadians(_ deg: Float) -> Float {
        deg * Float.pi / Float(180)
    }
}
