//
//  FirstPersonEngine+SunDiffusion.swift
//  Glasslands
//
//  Created by . . on 10/6/25.
//
//  Drives direct sun, shadow softness/contrast, ambient skylight and halo from cloud occlusion.
//

import SceneKit
import simd
import UIKit

extension FirstPersonEngine {

    /// Per-frame: modulates direct sunlight, shadow softness/contrast, skylight fill, and halo by cloud occlusion.
    @MainActor
    func updateSunDiffusion() {
        guard let sunNode = sunLightNode, let sun = sunNode.light else { return }

        // --- Tunables (clear-sky "full sun" lives at these baselines) ---
        let baseIntensity: CGFloat = 1500           // matches buildLighting()
        let clearShadowRadius: CGFloat = 0.45       // crisp when clear
        let cloudyExtraShadowRadius: CGFloat = 11.0 // added softness under thick cover

        // Estimate occlusion and map to transmittance (1 = clear, 0 = fully blocked).
        let thickness = estimateSunOcclusionThickness()  // 0…1

        // Tiny occlusions count as none; lets full sun actually snap in.
        let eps: CGFloat = 0.015
        let T_now: CGFloat = (CGFloat(thickness) <= eps)
            ? 1.0
            : {
                let tau = simd_clamp(5.0 * thickness, 0.0, 8.0)  // optical depth
                return CGFloat(expf(-tau))
            }()

        // Smooth: faster when clearing, gentler when clouding over.
        let T_prev = (sunNode.value(forKey: "GL_prevTransmittance") as? CGFloat) ?? T_now
        let kUp: CGFloat = 0.40   // when T increases (clearing)
        let kDown: CGFloat = 0.12 // when T decreases (clouding over)
        let k = (T_now >= T_prev) ? kUp : kDown
        let smoothT = T_prev + (T_now - T_prev) * k
        sunNode.setValue(smoothT, forKey: "GL_prevTransmittance")

        // Diffusion [0,1]: 0 = clear, 1 = thick cover.
        let diffusion = max(0.0, 1.0 - smoothT)

        // --- Direct sun: brightness + shadowing ---
        sun.intensity = baseIntensity * smoothT
        sun.shadowRadius = clearShadowRadius + diffusion * cloudyExtraShadowRadius
        sun.shadowSampleCount = max(1, Int(round(2 + diffusion * 14))) // 2…16 samples

        // Dark/crisp when clear → light/washed under cloud.
        // Alpha maps from 0.70 (clear) → 0.06 (cloudy) for a visibly lighter shadow.
        let shadowAlphaClear: CGFloat = 0.70
        let shadowAlphaCloudy: CGFloat = 0.06
        let alpha = shadowAlphaClear + (shadowAlphaCloudy - shadowAlphaClear) * diffusion
        sun.shadowColor = UIColor(white: 0.0, alpha: alpha)

        // --- Skylight (ambient fill) — lifts shadows under cloud, almost zero when clear. ---
        if let skyNode = scene.rootNode.childNode(withName: "GL_Skylight", recursively: false),
           let sky = skyNode.light {
            // Choose a conservative range so it feels natural.
            // Clear: ~0…30; Overcast: up to ~800 (roughly half of "full sun").
            let skyMin: CGFloat = 20.0
            let skyMax: CGFloat = 800.0
            sky.intensity = skyMin + (skyMax - skyMin) * diffusion
        }

        // --- Visible HDR halo only when the sun is actually behind cloud. ---
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

    /// Returns a 0…1 measure of how much cloud overlaps the sun’s core disc from the camera’s POV.
    /// 0 = no cover; 1 = saturated cover based on accumulated billboards with size/opacity weighting.
    @MainActor
    func estimateSunOcclusionThickness() -> Float {
        guard !cloudBillboardNodes.isEmpty else { return 0.0 }

        let cam = yawNode.presentation.simdPosition
        let sunW = simd_normalize(sunDirWorld)

        // Authored core angular size → RADIUS in radians.
        let coreDeg: Float = 6.0
        let sunRadius: Float = degreesToRadians(coreDeg) * 0.5

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

            let size: Float = Float(plane.width)
            let puffRadius: Float = atanf((size * 0.5) / max(1e-3, distance))

            // Overlap test in angular space using radii.
            let overlap = (puffRadius + sunRadius + feather) - dAngle
            if overlap <= 0 { continue }

            // Normalised overlap, scaled by puff size and opacity so big/opaque puffs weigh more.
            let denom = max(1e-3, puffRadius + sunRadius + feather)
            let t = max(0.0, min(1.0, overlap / denom))
            let scaleBig = size / (size + 30.0)
            let weight = Float(bb.opacity) * t * scaleBig

            accum += weight
            if accum >= 1.0 { return 1.0 }
        }

        // Deadzone so full sunlight truly snaps in.
        let v = max(0.0, min(1.0, accum))
        return (v < 0.01) ? 0.0 : v
    }

    @inline(__always)
    private func degreesToRadians(_ deg: Float) -> Float { deg * .pi / 180.0 }
}
