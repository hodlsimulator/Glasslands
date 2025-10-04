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

    @MainActor static func makeNode(
        from clusters: [CloudClusterSpec],
        atlas: CloudSpriteTexture.Atlas
    ) -> SCNNode {

        let root = SCNNode()
        root.name = "CumulusBillboardLayer"
        root.renderingOrder = -9_990

        let template = CloudBillboardMaterial.makeTemplate()

        for cl in clusters {
            let group = SCNNode()
            for p in cl.puffs {
                // Parent that faces the camera…
                let bb = SCNNode()
                bb.position = SCNVector3(p.pos.x, p.pos.y, p.pos.z)
                let bc = SCNBillboardConstraint()
                bc.freeAxes = .all
                bb.constraints = [bc]

                // …child plane rotated around Z for roll.
                let plane = SCNPlane(width: CGFloat(p.size), height: CGFloat(p.size))
                let sprite = SCNNode(geometry: plane)
                sprite.eulerAngles.z = p.roll
                sprite.castsShadow = false

                // Per‑instance material (copy the immutable template).
                let m = template.copy() as! SCNMaterial
                if atlas.images.isEmpty == false {
                    m.diffuse.contents = atlas.images[p.atlasIndex % atlas.images.count]
                }
                m.transparency = CGFloat(max(0, min(1, p.opacity)))
                plane.firstMaterial = m

                bb.addChildNode(sprite)
                group.addChildNode(bb)
            }
            root.addChildNode(group)
        }
        return root
    }
}
