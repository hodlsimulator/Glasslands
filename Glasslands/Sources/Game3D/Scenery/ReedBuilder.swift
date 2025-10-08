//
//  ReedBuilder.swift
//  Glasslands
//
//  Created by . . on 10/4/25.
//

import SceneKit
import UIKit
import GameplayKit

enum ReedBuilder {
    static func makeReedPatchNode(palette: [UIColor], rng: inout RandomAdaptor) -> SCNNode {
        let node = SCNNode()

        let base = palette.indices.contains(2) ? palette[2] : .systemGreen
        let reedColour = SceneryCommon.adjust(base,
                                              dH: CGFloat.random(in: -0.03...0.03, using: &rng),
                                              dS: -0.08,
                                              dB: -0.04)

        let count = Int.random(in: 5...9, using: &rng)

        for _ in 0..<count {
            let h = CGFloat.random(in: 0.35...0.70, using: &rng)
            let r = CGFloat.random(in: 0.006...0.012, using: &rng)

            let stalk = SCNCylinder(radius: r, height: h)
            let mat = SCNMaterial()
            mat.lightingModel = .physicallyBased
            mat.diffuse.contents = reedColour
            mat.roughness.contents = 0.95
            mat.metalness.contents = 0.0
            stalk.materials = [mat]

            let n = SCNNode(geometry: stalk)
            n.position = SCNVector3(
                CGFloat.random(in: -0.15...0.15, using: &rng),
                h * 0.5,
                CGFloat.random(in: -0.15...0.15, using: &rng)
            )

            // Gentle lean
            n.eulerAngles.x = Float.random(in: -0.10...0.10, using: &rng)
            n.eulerAngles.z = Float.random(in: -0.10...0.10, using: &rng)

            n.castsShadow = true
            node.addChildNode(n)
        }

        node.categoryBitMask = 0x00000002
        node.castsShadow = true
        node.enumerateChildNodes { c, _ in
            c.categoryBitMask |= 0x00000002
            c.castsShadow = true
        }

        SceneryCommon.applyLOD(to: node, far: 100)
        return node
    }
}
