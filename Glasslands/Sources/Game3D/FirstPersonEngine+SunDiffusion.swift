//
//  FirstPersonEngine+SunDiffusion.swift
//  Glasslands
//
//  Created by . . on 10/6/25.
//
//  Stable sun control. Removes projector/compute shadows and strips any
//  ground shadow shader that might be multiplying to black.
//

import SceneKit
import simd
import QuartzCore
import UIKit

extension FirstPersonEngine {

    func updateSunDiffusion() {
        guard let sunNode = sunLightNode, let sun = sunNode.light else { return }

        let cover = measureSunCover()
        let E_now: CGFloat = (cover.peak <= 0.010) ? 1.0 : CGFloat(expf(-6.0 * cover.union))
        let E_prev = (sunNode.value(forKey: "GL_prevIrradiance") as? CGFloat) ?? E_now
        let k: CGFloat = (E_now >= E_prev) ? 0.50 : 0.15
        let E = E_prev + (E_now - E_prev) * k
        sunNode.setValue(E, forKey: "GL_prevIrradiance")

        // Sun is the only illuminant
        sun.intensity = 1500 * max(0.06, E)

        let D = max(0.0, 1.0 - E)
        sun.shadowRadius = 0.35 + (13.0 - 0.35) * D
        sun.shadowSampleCount = max(1, Int(round(2 + D * 16)))
        sun.shadowColor = UIColor(white: 0.0, alpha: 0.65 + 0.2 * D)

        // No sky fill light
        if let skyFill = scene.rootNode.childNode(withName: "GL_SkyFill", recursively: false)?.light {
            skyFill.intensity = 0
        }

        // HDR halo follows cloudiness
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

        // Ensure we are NOT darkening the ground with any leftover shaders
        stripGroundShadowModifiers()
    }

    // Remove the shadow shader we might have installed earlier
    private func stripGroundShadowModifiers() {
        scene.rootNode.enumerateChildNodes { node, _ in
            guard (node.categoryBitMask & 0x0000_0400) != 0,
                  let g = node.geometry else { return }
            for m in g.materials {
                if m.value(forKey: "GL_shadowInstalled") != nil {
                    m.shaderModifiers = nil
                    m.setValue(nil, forKey: "GL_shadowInstalled")
                    m.setValue(nil, forKey: "gl_cloudShadowTex")
                }
            }
        }
    }

    // Same cover estimator as before
    private func measureSunCover() -> (peak: Float, union: Float) {
        guard let layer = skyAnchor.childNode(withName: "CumulusBillboardLayer", recursively: true) else {
            return (0.0, 0.0)
        }
        let pov = (scnView?.pointOfView ?? camNode).presentation
        let cam = pov.simdWorldPosition
        let sunW = simd_normalize(sunDirWorld)
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
            let puffR: Float = atanf((size * 0.30) / max(1e-3, dist))
            let overlap = (puffR + sunR + feather) - dAngle
            if overlap <= 0 { return }
            let denom = max(1e-3, puffR + sunR + feather)
            var t = max(0.0, min(1.0, overlap / denom))
            let angArea = min(1.0, (puffR * puffR) / (sunR * sunR))
            t *= angArea
            peak = max(peak, t)
            oneMinus *= max(0.0, 1.0 - min(0.98, t))
        }

        let union = 1.0 - oneMinus
        return ((peak < 0.01) ? 0.0 : peak, min(1.0, union))
    }

    @inline(__always) private func degreesToRadians(_ deg: Float) -> Float { deg * .pi / 180.0 }
}
