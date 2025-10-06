//
//  FirstPersonEngine+SunDiffusion.swift
//  Glasslands
//
//  Created by . . on 10/6/25.
//
//  Full sun when nothing touches the disc. Under cloud, shadows soften/lighten,
//  but a gentle shadow remains unless the cover is truly thick.
//

import SceneKit
import simd
import UIKit

extension FirstPersonEngine {

    // MARK: - Per-frame driver

    @MainActor
    func updateSunDiffusion() {
        guard let sunNode = sunLightNode, let sun = sunNode.light else { return }

        // Measure cover of the sun: peak (touching) and union (thickness proxy).
        let cover = measureSunCover()                 // peak ∈ [0,1], union ∈ [0,1]

        // Irradiance proxy E: decisive full-sun gate on PEAK, smooth decay by UNION.
        let E_now: CGFloat = (cover.peak <= 0.010) ? 1.0
            : CGFloat(expf(-6.0 * cover.union))       // stronger optical depth so cloud reads clearly

        // Smooth quickly when clearing, gently when clouding over.
        let E_prev = (sunNode.value(forKey: "GL_prevIrradiance") as? CGFloat) ?? E_now
        let k: CGFloat = (E_now >= E_prev) ? 0.50 : 0.15
        let E = E_prev + (E_now - E_prev) * k
        sunNode.setValue(E, forKey: "GL_prevIrradiance")

        // Diffusion and a “thickness” factor (0 = thin cover, 1 = really thick).
        let D = max(0.0, 1.0 - E)
        let thickF = CGFloat(smoothstep(0.82, 0.97, cover.union))

        // --- Direct sun ---
        let baseIntensity: CGFloat = 1500
        sun.intensity = baseIntensity * max(0.06, E)

        // --- Shadows: crisp when clear; soft/light under cloud; gentle shadow floor unless very thick ---
        let penClear: CGFloat  = 0.35
        let penCloudBase: CGFloat = 13.0
        let penCloud = penCloudBase + 3.0 * thickF                // thicker cover → even softer edge
        sun.shadowRadius = penClear + (penCloud - penClear) * D
        sun.shadowSampleCount = max(1, Int(round(2 + D * 16)))    // 2…18

        let alphaClear: CGFloat   = 0.82
        let alphaSoftFloor: CGFloat = 0.20                        // normal overcast keeps a gentle shadow
        let alphaThickFloor: CGFloat = 0.06                       // only under really thick cover
        let floorA = mix(alphaSoftFloor, alphaThickFloor, thickF)
        let a = alphaClear + (floorA - alphaClear) * D
        sun.shadowColor = UIColor(white: 0.0, alpha: a)

        // --- Directional sky-fill (no shadows): lifts backsides under cloud without flattening ---
        if let skyFill = scene.rootNode.childNode(withName: "GL_SkyFill", recursively: false)?.light {
            let minFill: CGFloat = 12
            let maxFillSoft: CGFloat = 380                         // normal overcast
            let maxFillThick: CGFloat = 560                        // really thick
            let maxFill = mix(maxFillSoft, maxFillThick, thickF)
            skyFill.intensity = minFill + (maxFill - minFill) * pow(D, 0.85)
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

    // MARK: - Sun cover (peak + union)

    /// Returns (peak, union) coverage of the solar disc by billboard puffs.
    /// peak  = strongest single overlap (drives the “clear-sky” gate)
    /// union = 1 − ∏(1 − t_i) across puffs (proxy for thickness)
    @MainActor
    private func measureSunCover() -> (peak: Float, union: Float) {
        guard let layer = skyAnchor.childNode(withName: "CumulusBillboardLayer", recursively: true) else {
            return (0.0, 0.0)
        }

        // Camera + sun direction in world space.
        let pov = (scnView?.pointOfView ?? camNode).presentation
        let cam = pov.simdWorldPosition
        let sunW = simd_normalize(sunDirWorld)

        // Stylised solar core radius (radians).
        let sunR: Float = degreesToRadians(6.0) * 0.5
        let feather: Float = 0.15 * (.pi / 180.0)

        var peak: Float = 0.0
        var oneMinus: Float = 1.0

        layer.enumerateChildNodes { node, _ in
            guard let plane = node.geometry as? SCNPlane else { return }

            let pw = node.presentation.simdWorldPosition
            let toP = simd_normalize(pw - cam)
            let cosAng = simd_clamp(simd_dot(sunW, toP), -1.0, 1.0)
            let dAngle = acosf(cosAng)

            let dist: Float = simd_length(pw - cam)
            if dist <= 1e-3 { return }

            let size: Float = Float(plane.width)
            let puffR: Float = atanf((size * 0.30) / max(1e-3, dist)) // tight factor

            let overlap = (puffR + sunR + feather) - dAngle
            if overlap <= 0 { return }

            let denom = max(1e-3, puffR + sunR + feather)
            var t = max(0.0, min(1.0, overlap / denom))

            // Weight tiny distant puffs down by area vs the sun disc.
            let angArea = min(1.0, (puffR * puffR) / (sunR * sunR))
            t *= angArea

            peak = max(peak, t)
            oneMinus *= max(0.0, 1.0 - min(0.98, t))  // union product
        }

        let union = 1.0 - oneMinus
        return ((peak < 0.01) ? 0.0 : peak, min(1.0, union))
    }

    @inline(__always)
    private func degreesToRadians(_ deg: Float) -> Float { deg * .pi / 180.0 }

    @inline(__always)
    private func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
        if e0 == e1 { return x >= e1 ? 1 : 0 }
        let t = max(0, min(1, (x - e0) / (e1 - e0)))
        return t * t * (3 - 2 * t)
    }

    @inline(__always)
    private func mix(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
}
