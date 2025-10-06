//
//  FirstPersonEngine+SunDiffusion.swift
//  Glasslands
//
//  Created by . . on 10/6/25.
//
//  Sun/shadow diffusion driven by a sun irradiance proxy taken from *actual*
//  billboard puffs that overlap the solar disc in angular space.
//
//  Behaviour:
//  • Clear (no overlap) → irradiance snaps to 1 → bright sun, crisp/dark shadows.
//  • Growing cover → irradiance decays smoothly → softer/lighter shadows, more sky-fill.
//  • Even at max diffusion a gentle shadow remains, never fully flat.
//

import SceneKit
import simd
import UIKit

extension FirstPersonEngine {

    // MARK: - Per-frame driver

    @MainActor
    func updateSunDiffusion() {
        guard let sunNode = sunLightNode, let sun = sunNode.light else { return }

        // 1) Irradiance proxy ∈ [0,1] from real puff overlap.
        let E_now: CGFloat = sunIrradianceProxyEnumeratingPuffs()

        // 2) Smooth: faster when clearing, gentler when clouding over.
        let E_prev = (sunNode.value(forKey: "GL_prevIrradiance") as? CGFloat) ?? E_now
        let k: CGFloat = (E_now >= E_prev) ? 0.50 : 0.15
        let E = E_prev + (E_now - E_prev) * k
        sunNode.setValue(E, forKey: "GL_prevIrradiance")

        // 3) Diffusion (complement).
        let D = max(0.0, 1.0 - E)

        // --- Direct sun: full when clear; never totally zero when covered.
        let baseIntensity: CGFloat = 1500
        sun.intensity = baseIntensity * max(0.06, E)

        // --- Shadows: crisp/dark when clear → softer/lighter under cloud, but never gone.
        let penClear: CGFloat  = 0.35
        let penCloud: CGFloat  = 13.0
        sun.shadowRadius = penClear + (penCloud - penClear) * D
        sun.shadowSampleCount = max(1, Int(round(2 + D * 16)))  // 2…18

        let alphaClear: CGFloat  = 0.82
        let alphaCloudy: CGFloat = 0.22                         // gentle shadow remains
        let a = alphaClear + (alphaCloudy - alphaClear) * D
        sun.shadowColor = UIColor(white: 0.0, alpha: a)

        // --- Directional sky-fill (no shadows): lifts backsides under cloud without flattening.
        if let skyFill = scene.rootNode.childNode(withName: "GL_SkyFill", recursively: false)?.light {
            let minFill: CGFloat = 12
            let maxFill: CGFloat = 560
            skyFill.intensity = minFill + (maxFill - minFill) * pow(D, 0.85)
        }

        // --- HDR halo only when the sun is occluded.
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

    // MARK: - Irradiance proxy from *real* puff overlap (enumerates scene nodes)

    /// Returns 1 if absolutely nothing overlaps the solar disc (true full-sun gate).
    /// Otherwise decays with a Beer–Lambert curve based on tight angular overlap.
    @MainActor
    private func sunIrradianceProxyEnumeratingPuffs() -> CGFloat {
        let cov = estimateBillboardCoverageTightEnumerating()   // 0…1 coverage of the disc
        if cov <= 0.010 { return 1.0 }                          // decisive “clear” state
        let T = expf(-6.0 * cov)                                // optical-depth decay
        return CGFloat(T)
    }

    /// Tight coverage of the solar disc by billboard puffs in *world space*.
    /// Walks the actual `CumulusBillboardLayer` and tests sprite planes directly.
    @MainActor
    private func estimateBillboardCoverageTightEnumerating() -> Float {
        guard let layer = skyAnchor.childNode(withName: "CumulusBillboardLayer", recursively: true) else {
            return 0.0
        }

        // Camera + sun direction in world space.
        let pov = (scnView?.pointOfView ?? camNode).presentation
        let cam = pov.simdWorldPosition
        let sunW = simd_normalize(sunDirWorld)

        // Stylised solar core radius (radians). Authoring uses ~6° diameter.
        let sunR: Float = degreesToRadians(6.0) * 0.5

        // Small feather to avoid “almost touching” registering as covered.
        let feather: Float = 0.15 * (.pi / 180.0)

        var covPeak: Float = 0.0

        layer.enumerateChildNodes { node, _ in
            // Only consider puff sprites (SCNPlane geometry on a node under a billboarded parent).
            guard let plane = node.geometry as? SCNPlane else { return }

            // Puff centre in world space.
            let pw = node.presentation.simdWorldPosition

            // Angular separation between sun direction and puff centre direction.
            let toP = simd_normalize(pw - cam)
            let cosAng = simd_clamp(simd_dot(sunW, toP), -1.0, 1.0)
            let dAngle = acosf(cosAng)

            // Apparent puff *angular radius* from its world size and distance.
            let dist: Float = simd_length(pw - cam)
            if dist <= 1e-3 { return }
            let size: Float = Float(plane.width)
            let puffR: Float = atanf((size * 0.30) / max(1e-3, dist))  // tight factor

            // Overlap test in angular space using radii + feather.
            let overlap = (puffR + sunR + feather) - dAngle
            if overlap <= 0 { return }

            // Normalised overlap [0,1]; emphasise truly central covers.
            let denom = max(1e-3, puffR + sunR + feather)
            var t = max(0.0, min(1.0, overlap / denom))

            // Weight tiny distant puffs down by area vs the sun disc.
            let angArea = min(1.0, (puffR * puffR) / (sunR * sunR))
            t *= angArea

            // Track the maximum (“tight union”), avoids a false “always some cover”.
            covPeak = max(covPeak, t)
            if covPeak >= 1.0 { return }
        }

        // Dead-zone so clear sky truly reads as clear.
        return (covPeak < 0.01) ? 0.0 : covPeak
    }

    @inline(__always)
    private func degreesToRadians(_ deg: Float) -> Float { deg * .pi / 180.0 }
}
