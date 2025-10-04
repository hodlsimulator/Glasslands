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
        let leafBase = palette.indices.contains(2) ? palette[2] : .systemGreen
        let leaf = SceneryCommon.adjust(
            leafBase,
            dH: CGFloat.random(in: -0.03...0.03, using: &rng),
            dS: CGFloat.random(in: -0.10...0.10, using: &rng),
            dB: CGFloat.random(in: -0.06...0.06, using: &rng)
        )

        let node = SCNNode()
        let count = Int.random(in: 3...5, using: &rng)
        for _ in 0..<count {
            let s = CGFloat.random(in: 0.18...0.30, using: &rng)
            let sph = SCNSphere(radius: s)
            sph.segmentCount = 12
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = leaf
            m.roughness.contents = 0.95
            m.metalness.contents = 0.0
            m.shaderModifiers = [.fragment: SceneryCommon.ldrClampDownFrag]
            sph.materials = [m]
            let n = SCNNode(geometry: sph)
            n.position = SCNVector3(
                Float.random(in: -0.18...0.18, using: &rng),
                Float.random(in:  0.05...0.18, using: &rng),
                Float.random(in: -0.18...0.18, using: &rng)
            )
            node.addChildNode(n)
        }
        node.categoryBitMask = 0x00000002
        SceneryCommon.applyLOD(to: node, far: 90)
        return node
    }
}
