//
//  MushroomBuilder.swift
//  Glasslands
//
//  Created by . . on 10/4/25.
//

import SceneKit
import UIKit
import GameplayKit

enum MushroomBuilder {
    static func makeMushroomPatchNode(palette: [UIColor], rng: inout RandomAdaptor) -> SCNNode {
        let node = SCNNode()

        let count = Int.random(in: 3...6, using: &rng)

        let stemColour = UIColor(white: 0.90, alpha: 1.0)
        let capBase = palette.indices.contains(0) ? palette[0] : UIColor(red: 0.90, green: 0.30, blue: 0.30, alpha: 1.0)

        @inline(__always)
        func capTint() -> UIColor {
            SceneryCommon.adjust(capBase,
                                 dH: CGFloat.random(in: -0.03...0.03, using: &rng),
                                 dS: CGFloat.random(in: -0.08...0.08, using: &rng),
                                 dB: CGFloat.random(in: -0.05...0.05, using: &rng))
        }

        for _ in 0..<count {
            let stemH = CGFloat.random(in: 0.10...0.18, using: &rng)
            let stemR = CGFloat.random(in: 0.012...0.022, using: &rng)

            let capR = CGFloat.random(in: 0.06...0.12, using: &rng)
            let capH = CGFloat.random(in: 0.040...0.080, using: &rng)

            let stemGeom = SCNCylinder(radius: stemR, height: stemH)
            let stemMat = SCNMaterial()
            stemMat.lightingModel = .physicallyBased
            stemMat.diffuse.contents = stemColour
            stemMat.roughness.contents = 0.95
            stemMat.metalness.contents = 0.0
            stemGeom.materials = [stemMat]

            // Slightly rounded cap
            let capGeom = SCNCone(topRadius: CGFloat.random(in: 0.002...0.006, using: &rng),
                                  bottomRadius: capR,
                                  height: capH)
            capGeom.radialSegmentCount = 16
            let capMat = SCNMaterial()
            capMat.lightingModel = .physicallyBased
            capMat.diffuse.contents = capTint()
            capMat.roughness.contents = 0.92
            capMat.metalness.contents = 0.0
            capGeom.materials = [capMat]

            let stemNode = SCNNode(geometry: stemGeom)
            stemNode.position = SCNVector3(0, stemH * 0.5, 0)
            stemNode.castsShadow = true

            let capNode = SCNNode(geometry: capGeom)
            capNode.position = SCNVector3(0, stemH + capH * 0.45, 0)
            capNode.castsShadow = true

            let m = SCNNode()
            m.addChildNode(stemNode)
            m.addChildNode(capNode)

            let r = CGFloat.random(in: 0.08...0.26, using: &rng)
            let a = CGFloat.random(in: 0...(2 * .pi), using: &rng)
            m.position = SCNVector3(r * cos(a), 0, r * sin(a))
            m.eulerAngles.y = Float.random(in: 0...(2 * .pi), using: &rng)
            m.castsShadow = true

            node.addChildNode(m)
        }

        // Vegetation category; ensure everything casts.
        node.categoryBitMask = 0x00000002
        node.castsShadow = true
        node.enumerateChildNodes { c, _ in
            c.categoryBitMask |= 0x00000002
            c.castsShadow = true
        }

        SceneryCommon.applyLOD(to: node, far: 80)
        return node
    }
}
