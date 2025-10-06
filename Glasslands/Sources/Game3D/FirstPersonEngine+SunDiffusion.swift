//
//  FirstPersonEngine+SunDiffusion.swift
//  Glasslands
//
//  Created by . . on 10/6/25.
//
//  Sun/sky lighting driven by cloud occlusion.
//

import SceneKit
import simd
import UIKit

extension FirstPersonEngine {

    @MainActor
    func updateSunDiffusion() {
        guard let sunNode = sunLightNode, let sun = sunNode.light else { return }

        // Coverage ∈ [0,1]: 0 = clear, 1 = fully behind cloud.
        let coverage = estimateSunOcclusionCoverage()

        // Smooth transmittance T = 1−coverage, faster on clearing.
        let T_now: CGFloat = max(0.0, 1.0 - CGFloat(coverage))
        let T_prev = (sunNode.value(forKey: "GL_prevTransmittance") as? CGFloat) ?? T_now
        let k = (T_now >= T_prev) ? 0.40 : 0.12
        let T = T_prev + (T_now - T_prev) * k
        sunNode.setValue(T, forKey: "GL_prevTransmittance")

        // Diffusion = 1−T.
        let D = max(0.0, 1.0 - T)

        // --- Sun: brightness + shadow shape/contrast ---
        let baseIntensity: CGFloat = 1500
        sun.intensity = baseIntensity * T

        let clearRadius: CGFloat = 0.40
        let cloudyRadius: CGFloat = 9.0
        sun.shadowRadius = clearRadius + (cloudyRadius - clearRadius) * D
        sun.shadowSampleCount = max(1, Int(round(2 + D * 12))) // 2…14

        // Keep shadows clearly visible when clear; lighter under cloud, but never gone.
        let alphaClear: CGFloat = 0.72
        let alphaCloudy: CGFloat = 0.30
        let a = alphaClear + (alphaCloudy - alphaClear) * D
        sun.shadowColor = UIColor(white: 0.0, alpha: a)

        // --- Sky fill: directional, no shadows. Gives “overcast bounce” without flattening.
        if let skyFill = scene.rootNode.childNode(withName: "GL_SkyFill", recursively: false)?.light {
            // Slight curve so it ramps in smoothly under cloud.
            let Dp = pow(D, 0.85)
            let minFill: CGFloat = 15   // clear
            let maxFill: CGFloat = 420  // thick cloud
            skyFill.intensity = minFill + (maxFill - minFill) * Dp
        }

        // --- HDR halo only when occluded ---
        if let sunGroup = sunDiscNode,
           let halo = sunGroup.childNode(withName: "SunHaloHDR", recursively: true),
           let haloMat = halo.geometry?.firstMaterial {
            let baseHalo = (haloMat.value(forKey: "GL_baseHaloIntensity") as? CGFloat) ?? haloMat.emission.intensity
            if haloMat.value(forKey: "GL_baseHaloIntensity") == nil {
                haloMat.setValue(baseHalo, forKey: "GL_baseHaloIntensity")
            }
            haloMat.emission.intensity = baseHalo * D
            halo.isHidden = D <= 1e-3
        }
    }

    /// Returns cloud *coverage* of the solar disc, ∈ [0,1], using a non-saturating union.
    /// Union model: coverage = 1 − ∏(1 − c_i), where c_i is each puff’s overlap weight.
    @MainActor
    func estimateSunOcclusionCoverage() -> Float {
        guard !cloudBillboardNodes.isEmpty else { return 0.0 }

        let cam = yawNode.presentation.simdPosition
        let sunW = simd_normalize(sunDirWorld)

        // Authored solar core size → radius.
        let coreDeg: Float = 6.0
        let sunR: Float = degreesToRadians(coreDeg) * 0.5
        let feather: Float = 0.25 * (.pi / 180.0)

        var oneMinus: Float = 1.0

        for bb in cloudBillboardNodes {
            let bp = bb.presentation.simdPosition
            let toP = simd_normalize(bp - cam)

            let cosAng = simd_clamp(simd_dot(sunW, toP), -1.0, 1.0)
            let dAngle = acosf(cosAng)

            guard let sprite = bb.childNodes.first,
                  let plane = sprite.geometry as? SCNPlane else { continue }

            let dist: Float = simd_length(bp - cam)
            if dist <= 1e-3 { continue }

            // Apparent *radius*. Use a conservative core factor so near puffs don’t dominate.
            let size: Float = Float(plane.width)
            let puffR: Float = atanf((size * 0.35) / max(1e-3, dist))

            // Overlap in angular space.
            let overlap = (puffR + sunR + feather) - dAngle
            if overlap <= 0 { continue }

            // Normalised edge-soft overlap [0,1].
            let denom = max(1e-3, puffR + sunR + feather)
            var t = max(0.0, min(1.0, overlap / denom))

            // Weight by puff opacity and a gentle size emphasis; soften with a curve.
            let sizeW = size / (size + 60.0)
            t = powf(t, 0.85) * Float(bb.opacity) * sizeW

            // Non-saturating union: c = 1 − ∏(1 − t_i).
            oneMinus *= max(0.0, 1.0 - min(0.98, t))
            if oneMinus <= 1e-4 { return 1.0 }
        }

        let cov = 1.0 - oneMinus
        // Dead-zone so clear sky truly reads as clear.
        return (cov < 0.01) ? 0.0 : min(1.0, cov)
    }

    @inline(__always)
    private func degreesToRadians(_ deg: Float) -> Float { deg * .pi / 180.0 }
}
