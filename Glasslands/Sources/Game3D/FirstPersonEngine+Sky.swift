//
//  FirstPersonEngine+Sky.swift
//  Glasslands
//
//  Created by . . on 10/5/25.
//
//  Sun + sky helpers, plus cloud-material uniform updates (billboards + volumetrics).
//  Makes impostors white under sun with no ambient/self-light.
//

//
//  FirstPersonEngine+Sky.swift
//  Glasslands
//
//  Created by . . on 10/7/25.
//

import SceneKit
import simd
import UIKit

extension FirstPersonEngine {

    // MARK: - Sky anchor + sun

    @MainActor
    func buildSky() {
        // Sky anchor stays centred on the camera so sky elements feel infinite.
        if skyAnchor.parent == nil {
            root.addChildNode(skyAnchor)
        }
        skyAnchor.simdPosition = camNode.simdPosition

        // Base sky sphere (pure atmosphere shader)
        if skyNode.parent == nil {
            skyNode = SceneKitHelpers.makeSkySphereNode(radius: 10000)
            skyNode.name = "SkySphere"
            skyNode.renderingOrder = -100_000
            skyAnchor.addChildNode(skyNode)
        }

        // Sun sprite (HDR-ish)
        if sunNode.parent == nil {
            sunNode = SceneKitHelpers.makeSunNode(radius: 140)
            sunNode.name = "Sun"
            sunNode.renderingOrder = -20_000
            skyAnchor.addChildNode(sunNode)
        }

        applySunDirection()
    }

    @MainActor
    func applySunDirection() {
        let dir = simd_normalize(sunDirWorld)
        skyNode.simdWorldOrientation = simd_quatf(angle: 0, axis: simd_float3(0, 1, 0))

        // Place sun far away along direction.
        let sunDist: Float = 9000
        sunNode.simdPosition = dir * sunDist

        applyCloudSunUniforms()
    }

    // MARK: - Cloud uniforms

    @MainActor
    func applyCloudSunUniforms() {
        let sunW = simd_normalize(sunDirWorld)
        let pov = (scnView?.pointOfView ?? camNode).presentation
        let invView = simd_inverse(pov.simdWorldTransform)
        let sunView4 = invView * simd_float4(sunW, 0)
        let sunView = simd_normalize(simd_float3(sunView4.x, sunView4.y, sunView4.z))
        let sunViewV = SCNVector3(sunView.x, sunView.y, sunView.z)

        guard let layer = skyAnchor.childNode(withName: "CumulusBillboardLayer", recursively: true) else { return }

        layer.enumerateChildNodes { node, _ in
            guard let g = node.geometry else { return }
            for m in g.materials {
                // Sun direction is in view space so camera-facing impostors behave consistently.
                m.setValue(sunViewV, forKey: "sunDirView")

                // Phase / highlight response.
                m.setValue(0.62 as CGFloat, forKey: "hgG")
                m.setValue(1.00 as CGFloat, forKey: "baseWhite")
                m.setValue(1.65 as CGFloat, forKey: "lightGain")
                m.setValue(1.00 as CGFloat, forKey: "hiGain")

                // Rich scattered cumulus:
                // - thicker cores
                // - airy translucent edges
                // - strong internal breakup (blue gaps)
                m.setValue(14.00 as CGFloat, forKey: "densityMul")
                m.setValue(5.60 as CGFloat, forKey: "thickness")
                m.setValue(-0.02 as CGFloat, forKey: "densBias")
                m.setValue(0.86 as CGFloat, forKey: "coverage")
                m.setValue(0.0036 as CGFloat, forKey: "puffScale")

                // Silhouette shaping.
                m.setValue(0.16 as CGFloat, forKey: "edgeFeather")
                m.setValue(0.07 as CGFloat, forKey: "edgeCut")
                m.setValue(0.18 as CGFloat, forKey: "edgeNoiseAmp")
                m.setValue(2.10 as CGFloat, forKey: "rimFeatherBoost")
                m.setValue(2.80 as CGFloat, forKey: "rimFadePow")

                // Macro breakup inside each puff.
                m.setValue(1.05 as CGFloat, forKey: "shapeScale")
                m.setValue(0.42 as CGFloat, forKey: "shapeLo")
                m.setValue(0.70 as CGFloat, forKey: "shapeHi")
                m.setValue(2.15 as CGFloat, forKey: "shapePow")

                // Higher = sun is more “covered” through thick cores.
                m.setValue(0.78 as CGFloat, forKey: "occK")

                // Compatibility knobs (safe even if the shader ignores them).
                m.setValue(0.50 as CGFloat, forKey: "stepMul")
                m.setValue(0.62 as CGFloat, forKey: "edgeErode")
                m.setValue(0.78 as CGFloat, forKey: "centreFill")
                m.setValue(0.28 as CGFloat, forKey: "microAmp")
            }
        }
    }

    // MARK: - HDR sun sprites (unchanged)

    @MainActor
    func setSunBloom(intensity: CGFloat) {
        guard let mat = sunNode.geometry?.firstMaterial else { return }
        mat.setValue(intensity, forKey: "bloomIntensity")
    }
}
