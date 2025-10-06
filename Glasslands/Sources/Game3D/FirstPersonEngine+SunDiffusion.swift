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

    /// Per-frame: modulates direct sunlight, shadow softness/contrast, and halo by cloud occlusion.
    @MainActor
    func updateSunDiffusion() {
        guard let sunNode = sunLightNode, let sun = sunNode.light else { return }

        // --- Tunables (clear-sky "full sun" lives at these baselines) ---
        let baseIntensity: CGFloat = 1500            // matches buildLighting()
        let clearShadowRadius: CGFloat = 0.45        // crisp when clear
        let cloudyExtraShadowRadius: CGFloat = 10.0  // softness added under thick cover

        // Estimate occlusion and map to transmittance (1 = clear, 0 = fully blocked).
        let thickness = estimateSunOcclusionThickness()  // 0…1

        // Treat a tiny occlusion as "none" so full sun actually snaps in.
        let eps: CGFloat = 0.015
        let T_now: CGFloat = (CGFloat(thickness) <= eps)
            ? 1.0
            : {
                // Beer–Lambert with a modest optical depth; tweak 4–6 for stronger dimming.
                let tau = simd_clamp(5.0 * thickness, 0.0, 8.0)
                return CGFloat(expf(-tau))
            }()

        // Smooth: faster when clearing (so full sunlight returns quickly), gentler when clouding over.
        let T_prev = (sunNode.value(forKey: "GL_prevTransmittance") as? CGFloat) ?? T_now
        let kUp: CGFloat = 0.35   // when T_now > T_prev
        let kDown: CGFloat = 0.10 // when T_now <= T_prev
        let k = (T_now >= T_prev) ? kUp : kDown
        let smoothT = T_prev + (T_now - T_prev) * k
        sunNode.setValue(smoothT, forKey: "GL_prevTransmittance")

        // Direct sun intensity follows transmittance exactly (full sun when clear).
        sun.intensity = baseIntensity * smoothT

        // Diffusion drives softness/contrast. 0 = clear, 1 = thick cover.
        let diffusion = max(0.0, 1.0 - smoothT)

        // Shadow softness rises under cloud; crisp again when clear.
        sun.shadowRadius = clearShadowRadius + diffusion * cloudyExtraShadowRadius
        sun.shadowSampleCount = max(1, Int(round(2 + diffusion * 10))) // 2…12 samples

        // IMPORTANT: darker, crisper shadows when clear; lighter, washed-out when cloudy.
        // Alpha maps from 0.65 (clear) → 0.18 (cloudy).
        let shadowAlphaClear: CGFloat = 0.65
        let shadowAlphaCloudy: CGFloat = 0.18
        let alpha = shadowAlphaClear + (shadowAlphaCloudy - shadowAlphaClear) * diffusion
        sun.shadowColor = UIColor(white: 0.0, alpha: alpha)

        // Visible HDR halo only when the sun is actually behind cloud.
        if let sunGroup = sunDiscNode,
           let halo = sunGroup.childNode(withName: "SunHaloHDR", recursively: true),
           let haloMat = halo.geometry?.firstMaterial
        {
            let baseHalo = (haloMat.value(forKey: "GL_baseHaloIntensity") as? CGFloat) ?? haloMat.emission.intensity
            if haloMat.value(forKey: "GL_baseHaloIntensity") == nil {
                haloMat.setValue(baseHalo, forKey: "GL_baseHaloIntensity")
            }

            haloMat.emission.intensity = baseHalo * diffusion
            halo.isHidden = diffusion <= 1e-3
        }
    }

    /// Returns a 0…1 measure of how much cloud overlaps the *sun’s core disc* from the camera’s POV.
    /// 0 = no cover; 1 = "max" cover based on accumulated billboards with size/opacity weighting.
    @MainActor
    func estimateSunOcclusionThickness() -> Float {
        guard !cloudBillboardNodes.isEmpty else { return 0.0 }

        let cam = yawNode.presentation.simdPosition
        let sunW = simd_normalize(sunDirWorld)

        // Use the authored core angular SIZE and convert to *radius*.
        let coreDeg: Float = 6.0 // fallback; matches buildSky() coreAngularSizeDeg
        let sunRadius: Float = degreesToRadians(coreDeg) * 0.5

        // Small feather purely to avoid hard popping at exact tangency.
        let feather: Float = 0.25 * (.pi / 180.0) // ~0.25°

        var accum: Float = 0.0

        for bb in cloudBillboardNodes {
            let bp = bb.presentation.simdPosition
            let toP = simd_normalize(bp - cam)

            // Angular separation between sun direction and puff centre.
            let cosAng = simd_clamp(simd_dot(sunW, toP), -1.0, 1.0)
            let dAngle = acosf(cosAng)

            // Apparent *angular radius* of the puff from its size and distance.
            guard let sprite = bb.childNodes.first,
                  let plane = sprite.geometry as? SCNPlane else { continue }

            let distance: Float = simd_length(bp - cam)
            if distance <= 1e-3 { continue }

            // Correct: radius = atan( (width/2) / distance )
            let size: Float = Float(plane.width)
            let puffRadius: Float = atanf((size * 0.5) / max(1e-3, distance))

            // Overlap test in angular space using radii.
            let overlap = (puffRadius + sunRadius + feather) - dAngle
            if overlap <= 0 { continue }

            // Normalised overlap [0,1], scaled by puff size and opacity so big/opaque puffs weigh more.
            let denom = max(1e-3, puffRadius + sunRadius + feather)
            let t = max(0.0, min(1.0, overlap / denom))

            // Weight bigger puffs a bit more, but saturate to avoid runaway accumulation.
            let scaleBig = size / (size + 30.0)
            let weight = Float(bb.opacity) * t * scaleBig

            accum += weight
            if accum >= 1.0 { return 1.0 }
        }

        // Gentle deadzone: treat near-zero as zero so full sunlight can truly happen.
        let v = max(0.0, min(1.0, accum))
        return (v < 0.01) ? 0.0 : v
    }

    @inline(__always)
    private func degreesToRadians(_ deg: Float) -> Float { deg * .pi / 180.0 }
}
