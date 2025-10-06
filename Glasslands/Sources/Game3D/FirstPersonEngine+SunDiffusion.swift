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

    /// Per-frame: modulates direct sunlight and shadow softness by cloud occlusion.
    /// Also gates the HDR sun halo so diffusion appears only when the sun is behind cloud.
    @MainActor
    func updateSunDiffusion() {
        guard let sunNode = sunLightNode, let sun = sunNode.light else { return }

        // Direct light / shadow baselines.
        let baseIntensity: CGFloat = 1500
        let baseShadowRadius: CGFloat = 2.0
        let maxExtraShadowRadius: CGFloat = 10.0
        let minSunFactor: CGFloat = 0.35   // keep some ambient-ish direct term under thick cover

        // Estimate 0…1 “thickness” along the camera→sun direction using cloud billboards.
        let thickness: Float = estimateSunOcclusionThickness()

        // Simple Beer–Lambert style transmittance with a tame optical depth scale.
        let tau: Float = simd_clamp(4.0 * thickness, 0.0, 6.0)
        let T_now: CGFloat = CGFloat(expf(-tau))           // 1 = clear, 0 = fully occluded

        // Ease changes to avoid shimmer when puffs cross the sun.
        let T_prev = (sunNode.value(forKey: "GL_prevTransmittance") as? CGFloat) ?? T_now
        let smoothT = T_prev + (T_now - T_prev) * 0.10     // ~10% per frame at 60 fps
        sunNode.setValue(smoothT, forKey: "GL_prevTransmittance")

        // Direct sun intensity tracks transmittance; clamp to a floor so scenes don’t go pitch black.
        sun.intensity = baseIntensity * max(minSunFactor, smoothT)

        // Shadow softness and samples rise with cloud thickness, crisp again in clear skies.
        let diffusion = (1.0 - smoothT)
        sun.shadowRadius = baseShadowRadius + diffusion * maxExtraShadowRadius
        sun.shadowSampleCount = 4 + max(0, Int((diffusion * 8.0).rounded(.toNearestOrAwayFromZero)))
        sun.shadowColor = UIColor(white: 0.0, alpha: 0.35 + diffusion * 0.35)

        // Visible HDR halo: only show “diffusion” when the sun is actually behind cloud.
        if let sunGroup = sunDiscNode,
           let halo = sunGroup.childNode(withName: "SunHaloHDR", recursively: true),
           let haloMat = halo.geometry?.firstMaterial
        {
            // Remember the original authored halo intensity so we can scale from it.
            let baseHalo = (haloMat.value(forKey: "GL_baseHaloIntensity") as? CGFloat) ?? haloMat.emission.intensity
            if haloMat.value(forKey: "GL_baseHaloIntensity") == nil {
                haloMat.setValue(baseHalo, forKey: "GL_baseHaloIntensity")
            }

            // Scale halo by diffusion; hide entirely when clear (zero diffusion).
            haloMat.emission.intensity = baseHalo * diffusion
            halo.isHidden = diffusion <= 1e-3
        }
    }

    /// Returns a 0…1 measure of how much cloud overlaps the sun from the camera’s point of view.
    /// 0 = no cover; 1 = “max” cover based on accumulated billboards with size/opacity weighting.
    @MainActor
    func estimateSunOcclusionThickness() -> Float {
        guard !cloudBillboardNodes.isEmpty else { return 0.0 }

        let cam = yawNode.presentation.simdPosition
        let sunW = simd_normalize(sunDirWorld)

        // Angular radii in radians (approximate solar disc + a small feather for pleasant roll-in).
        let sunRadius: Float = degreesToRadians(6.0)

        var accum: Float = 0.0
        for bb in cloudBillboardNodes {
            let bp = bb.presentation.simdPosition
            let toP = simd_normalize(bp - cam)

            // Angular separation between sun direction and cloud puff centre.
            let cosAng = simd_clamp(simd_dot(sunW, toP), -1.0, 1.0)
            let dAngle = acosf(cosAng)

            // Each puff is a plane; approximate its apparent angular radius from size and distance.
            guard let sprite = bb.childNodes.first,
                  let plane = sprite.geometry as? SCNPlane else { continue }

            let distance: Float = simd_length(bp - cam)
            if distance <= 1e-3 { continue }

            let size: Float = Float(plane.width)
            let puffRadius: Float = 2.0 * atanf((size * 0.5) / max(1e-3, distance))
            let feather: Float = 0.75 * (.pi / 180.0)     // ~0.75°

            let overlap: Float = (puffRadius + sunRadius + feather) - dAngle
            if overlap <= 0 { continue }

            // Normalised overlap [0,1], scaled by puff size and opacity so big/opaque puffs weigh more.
            let denom: Float = max(1e-3, puffRadius + sunRadius + feather)
            let t: Float = max(0.0, min(1.0, overlap / denom))
            let scaleBig: Float = size / (size + 30.0)
            let weight: Float = Float(bb.opacity) * t * scaleBig

            accum += weight
            if accum >= 1.0 { return 1.0 }
        }
        return max(0.0, min(1.0, accum))
    }

    @inline(__always)
    private func degreesToRadians(_ deg: Float) -> Float { deg * .pi / 180.0 }
}
