//
//  BushBuilder.swift
//  Glasslands
//
//  Created by . . on 10/4/25.
//

import SceneKit
import UIKit
import GameplayKit

enum BushBuilder {
    static func makeBushNode(palette: [UIColor], rng: inout RandomAdaptor) -> SCNNode {
        let node = SCNNode()

        let leafBase = palette.indices.contains(2) ? palette[2] : .systemGreen
        let leaf = SceneryCommon.adjust(
            leafBase,
            dH: CGFloat.random(in: -0.03...0.03, using: &rng),
            dS: CGFloat.random(in: -0.10...0.10, using: &rng),
            dB: CGFloat.random(in: -0.06...0.06, using: &rng)
        )

        let count = Int.random(in: 3...5, using: &rng)
        for _ in 0..<count {
            let r = CGFloat.random(in: 0.10...0.18, using: &rng)
            let g = SCNSphere(radius: r)
            g.segmentCount = 16

            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = leaf
            m.roughness.contents = 0.95
            m.metalness.contents = 0.0
            g.materials = [m]

            let n = SCNNode(geometry: g)
            n.position = SCNVector3(
                CGFloat.random(in: -0.15...0.15, using: &rng),
                r * CGFloat.random(in: 0.2...0.5, using: &rng),
                CGFloat.random(in: -0.15...0.15, using: &rng)
            )
            n.eulerAngles.y = Float.random(in: 0...(2 * .pi), using: &rng)
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
