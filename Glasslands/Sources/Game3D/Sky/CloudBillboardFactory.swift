//
//  CloudBillboardFactory.swift
//  Glasslands
//
//  Created by . . on 10/4/25.
//
//  Converts cluster specs + atlas into a SceneKit node.
//

import SceneKit
import UIKit

enum CloudBillboardFactory {

    @MainActor
    static func makeNode(
        from clusters: [CloudClusterSpec],
        atlas: CloudSpriteTexture.Atlas
    ) -> SCNNode {
        let root = SCNNode()
        root.name = "CumulusBillboardLayer"
        root.castsShadow = false

        // Share one material per atlas image.
        let template = CloudBillboardMaterial.makeCurrent()
        var cache: [Int: SCNMaterial] = [:]

        @inline(__always)
        func material(forAtlasIndex i: Int) -> SCNMaterial {
            if let m = cache[i] { return m }
            let m = template.copy() as! SCNMaterial
            let count = atlas.images.count
            if count > 0 {
                let idx = ((i % count) + count) % count
                m.diffuse.contents = atlas.images[idx]
            } else {
                m.diffuse.contents = CloudSpriteTexture.fallbackWhite2x2
            }
            m.multiply.contents = UIColor.white
            cache[i] = m
            return m
        }

        for cl in clusters {
            let group = SCNNode()
            group.castsShadow = false

            for p in cl.puffs {
                let bb = SCNNode()
                bb.position = SCNVector3(p.pos.x, p.pos.y, p.pos.z)

                let bc = SCNBillboardConstraint()
                bc.freeAxes = .all
                bb.constraints = [bc]

                let plane = SCNPlane(width: CGFloat(p.size), height: CGFloat(p.size))
                plane.firstMaterial = material(forAtlasIndex: p.atlasIndex)

                let sprite = SCNNode(geometry: plane)
                sprite.eulerAngles.z = p.roll
                sprite.castsShadow = false

                // Draw clouds AFTER the sun for occlusion-by-order.
                sprite.renderingOrder = -9_000
                bb.renderingOrder = -9_000

                // Per-puff opacity lives on the node so the material stays shared.
                bb.opacity = CGFloat(max(0, min(1, p.opacity)))

                bb.addChildNode(sprite)
                group.addChildNode(bb)
            }

            root.addChildNode(group)
        }

        return root
    }
}
