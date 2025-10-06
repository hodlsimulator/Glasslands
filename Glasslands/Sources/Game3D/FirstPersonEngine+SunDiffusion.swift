//
//  FirstPersonEngine+SunDiffusion.swift
//  Glasslands
//
//  Created by . . on 10/6/25.
//
//  Sun/shadow diffusion driven by a *sun irradiance proxy*:
//  – If nothing overlaps the sun disc → irradiance snaps to 1.0 (full sun).
//  – As cloud overlaps grow → irradiance decays smoothly (Beer–Lambert).
//  – Diffusion = 1 − irradiance, used to soften/lighten shadows and add sky-fill.
//
//  Notes:
//  • Only billboard overlap is used here (tight angular test). This avoids a non-zero floor
//    that could prevent full-sun states.
//  • A faint shadow always remains under full diffusion.
//

import SceneKit
import simd
import UIKit

extension FirstPersonEngine {

    // MARK: - Per-frame driver

    @MainActor
    func updateSunDiffusion() {
        guard let sunNode = sunLightNode, let sun = sunNode.light else { return }

        // Irradiance proxy ∈ [0,1]: 1 = full sun on the disc, 0 = fully covered.
        let E_now = sunIrradianceProxy()

        // Smooth quickly when clearing (so full sun returns decisively), gently when clouding.
        let E_prev = (sunNode.value(forKey: "GL_prevIrradiance") as? CGFloat) ?? E_now
        let k: CGFloat = (E_now >= E_prev) ? 0.50 : 0.15
        let E = E_prev + (E_now - E_prev) * k
        sunNode.setValue(E, forKey: "GL_prevIrradiance")

        // Diffusion is the complement.
        let D = max(0.0, 1.0 - E)

        // --- Direct sun: full when clear; falls with coverage but never zero.
        let baseIntensity: CGFloat = 1500
        sun.intensity = baseIntensity * max(0.06, E)

        // --- Shadows: crisp & dark when clear → softer & lighter under cloud, but never gone.
        let penClear: CGFloat  = 0.35
        let penCloud: CGFloat  = 13.0
        sun.shadowRadius = penClear + (penCloud - penClear) * D
        sun.shadowSampleCount = max(1, Int(round(2 + D * 16)))  // 2…18

        let alphaClear: CGFloat  = 0.82
        let alphaCloudy: CGFloat = 0.22                         // gentle shadow remains
        let a = alphaClear + (alphaCloudy - alphaClear) * D
        sun.shadowColor = UIColor(white: 0.0, alpha: a)

        // --- Directional sky fill (no shadows): lifts “back sides” under cloud without flattening.
        if let skyFill = scene.rootNode.childNode(withName: "GL_SkyFill", recursively: false)?.light {
            let minFill: CGFloat = 12
            let maxFill: CGFloat = 560
            skyFill.intensity = minFill + (maxFill - minFill) * pow(D, 0.85)
        }

        // --- HDR halo: only when the sun is actually behind cloud.
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

    // MARK: - Sun irradiance proxy (tight angular overlap on the sun disc)

    /// Returns 1 if absolutely nothing overlaps the solar disc; otherwise applies a smooth
    /// Beer–Lambert decay based on *tight* overlap. This produces decisive full-sun states.
    @MainActor
    private func sunIrradianceProxy() -> CGFloat {
        let cov = estimateBillboardCoverageTight()  // 0…1 coverage of the disc
        if cov <= 0.010 { return 1.0 }              // true “clear” gate
        // Stronger optical depth so cloud actually dims convincingly.
        let T = expf(-6.0 * cov)                    // 0…1
        return CGFloat(T)
    }

    /// Tight coverage of the solar disc by billboards in angular space.
    /// – Uses smaller feather and smaller puff radius factor to avoid false positives.
    /// – Weights by apparent angular size so far, tiny puffs barely contribute.
    @MainActor
    private func estimateBillboardCoverageTight() -> Float {
        guard !cloudBillboardNodes.isEmpty else { return 0.0 }

        let cam = yawNode.presentation.simdPosition
        let sunW = simd_normalize(sunDirWorld)

        // Stylised sun core radius (radians). Authoring uses ~6° diameter.
        let sunR: Float = degreesToRadians(6.0) * 0.5

        // Smaller feather to avoid “nearly touching” reading as covered.
        let feather: Float = 0.15 * (.pi / 180.0)

        var covPeak: Float = 0.0

        for bb in cloudBillboardNodes {
            let bp = bb.presentation.simdPosition
            let toP = simd_normalize(bp - cam)

            // Angular separation between sun direction and puff centre.
            let cosAng = simd_clamp(simd_dot(sunW, toP), -1.0, 1.0)
            let dAngle = acosf(cosAng)

            guard let sprite = bb.childNodes.first,
                  let plane  = sprite.geometry as? SCNPlane else { continue }

            let dist: Float = simd_length(bp - cam)
            if dist <= 1e-3 { continue }

            // Apparent puff *radius* (tighter than before: 0.30 factor).
            let size: Float = Float(plane.width)
            let puffR: Float = atanf((size * 0.30) / max(1e-3, dist))

            // Overlap in angular space using radii + small feather.
            let overlap = (puffR + sunR + feather) - dAngle
            if overlap <= 0 { continue }

            // Normalised overlap [0,1], emphasise truly central covers.
            let denom = max(1e-3, puffR + sunR + feather)
            var t = max(0.0, min(1.0, overlap / denom))

            // Weight by apparent angular size so far, tiny puffs don’t dominate.
            let angArea = min(1.0, (puffR * puffR) / (sunR * sunR)) // rough area ratio clamp
            t *= angArea

            // Track the peak (tight union). Avoids “always some cover” accumulation.
            covPeak = max(covPeak, t)
            if covPeak >= 1.0 { return 1.0 }
        }

        // Dead-zone so full sun truly happens.
        return (covPeak < 0.01) ? 0.0 : covPeak
    }

    @inline(__always)
    private func degreesToRadians(_ deg: Float) -> Float { deg * .pi / 180.0 }
}
