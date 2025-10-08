//
//  CrystalBuilder.swift
//  Glasslands
//
//  Created by . . on 10/4/25.
//

import SceneKit
import UIKit
import GameplayKit

enum CrystalBuilder {
    static func makeCrystalClusterNode(palette: [UIColor], rng: inout RandomAdaptor) -> SCNNode {
        let node = SCNNode()

        let baseTint = palette.indices.contains(1) ? palette[1] : UIColor.systemTeal

        @inline(__always)
        func tint() -> UIColor {
            SceneryCommon.adjust(baseTint,
                                 dH: CGFloat.random(in: -0.02...0.02, using: &rng),
                                 dS: CGFloat.random(in: -0.08...0.10, using: &rng),
                                 dB: CGFloat.random(in: -0.08...0.06, using: &rng))
        }

        let count = Int.random(in: 3...6, using: &rng)
        for _ in 0..<count {
            let w = CGFloat.random(in: 0.05...0.12, using: &rng)
            let d = CGFloat.random(in: 0.05...0.12, using: &rng)
            let h = CGFloat.random(in: 0.18...0.42, using: &rng)

            // Simple low-poly shard
            let g = SCNPyramid(width: w, height: h, length: d)
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = tint()
            m.roughness.contents = 0.35
            m.metalness.contents = 0.05
            g.materials = [m]

            let n = SCNNode(geometry: g)
            n.position = SCNVector3(
                CGFloat.random(in: -0.20...0.20, using: &rng),
                h * 0.5,
                CGFloat.random(in: -0.20...0.20, using: &rng)
            )
            n.eulerAngles.y = Float.random(in: 0...(2 * .pi), using: &rng)
            n.eulerAngles.x = Float.random(in: -0.06...0.06, using: &rng)
            n.castsShadow = true
            node.addChildNode(n)
        }

        node.categoryBitMask = 0x00000002
        node.castsShadow = true
        node.enumerateChildNodes { c, _ in
            c.categoryBitMask |= 0x00000002
            c.castsShadow = true
        }

        SceneryCommon.applyLOD(to: node, far: 120)
        return node
    }
}
