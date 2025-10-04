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
        let base = palette.indices.contains(2) ? palette[2] : .systemGreen
        let reedColour = SceneryCommon.adjust(base,
                                              dH: CGFloat.random(in: -0.03...0.03, using: &rng),
                                              dS: -0.08,
                                              dB: -0.04)

        let node = SCNNode()
        let count = Int.random(in: 5...9, using: &rng)
        for _ in 0..<count {
            let h: CGFloat = CGFloat.random(in: 0.22...0.38, using: &rng)
            let r: CGFloat = CGFloat.random(in: 0.004...0.008, using: &rng)
            let cap = SCNCapsule(capRadius: r, height: h)
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = reedColour
            m.roughness.contents = 0.95
            cap.materials = [m]
            let n = SCNNode(geometry: cap)
            n.position = SCNVector3(
                Float.random(in: -0.20...0.20, using: &rng),
                Float(h * 0.5),
                Float.random(in: -0.20...0.20, using: &rng)
            )
            n.eulerAngles.y = Float.random(in: 0...(2 * .pi), using: &rng)
            node.addChildNode(n)
        }
        node.categoryBitMask = 0x00000002
        SceneryCommon.applyLOD(to: node, far: 80)
        return node
    }
}
