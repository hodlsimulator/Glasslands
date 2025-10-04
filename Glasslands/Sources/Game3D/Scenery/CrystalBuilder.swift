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
        let count = Int.random(in: 3...6, using: &rng)
        let baseTint = (palette.indices.contains(1) ? palette[1] : UIColor.systemTeal)

        for _ in 0..<count {
            var localRng = rng
            let s = CGFloat.random(in: 0.10...0.22, using: &rng)
            var (shard, rad) = RockBuilder.makeRockNode(size: s, palette: palette, rng: &localRng)
            shard.scale = SCNVector3(0.9, Float.random(in: 1.6...2.4, using: &rng), 0.9)
            if let mat = shard.geometry?.firstMaterial {
                let tint = baseTint.adjustingHue(by: CGFloat.random(in: -0.05...0.05, using: &rng),
                                                 satBy: 0.05,
                                                 briBy: 0.02)
                mat.diffuse.contents = tint.withAlphaComponent(0.95)
                mat.emission.contents = tint.withAlphaComponent(0.12)
                mat.roughness.contents = 0.40
                mat.metalness.contents = 0.15
            }
            shard.position = SCNVector3(Float.random(in: -0.18...0.18, using: &rng),
                                        0.0,
                                        Float.random(in: -0.18...0.18, using: &rng))
            shard.setValue(rad, forKey: "hitRadius")
            node.addChildNode(shard)
        }
        node.categoryBitMask = 0x00000401
        SceneryCommon.applyLOD(to: node, far: 110)
        return node
    }
}
