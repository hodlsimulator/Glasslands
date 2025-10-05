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
        root.renderingOrder = -9_990

        let template = CloudBillboardMaterial.makeVolumetricTemplate()

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

                // Independent, no-sampler material per puff.
                let m = template.copy() as! SCNMaterial

                // ALWAYS bind a valid image so SceneKit pre-samples diffuse → _output.color.a
                let count = max(1, atlas.images.count)
                let idx = ((p.atlasIndex % count) + count) % count
                let img = atlas.images.isEmpty ? CloudSpriteTexture.fallbackWhite2x2 : atlas.images[idx]
                m.diffuse.contents = img

                m.transparency = CGFloat(max(0, min(1, p.opacity)))
                if let t = p.tint {
                    m.multiply.contents = UIColor(
                        red:   CGFloat(max(0, min(1, t.x))),
                        green: CGFloat(max(0, min(1, t.y))),
                        blue:  CGFloat(max(0, min(1, t.z))),
                        alpha: 1
                    )
                }

                plane.firstMaterial = m

                let sprite = SCNNode(geometry: plane)
                sprite.eulerAngles.z = p.roll
                sprite.castsShadow = false

                bb.addChildNode(sprite)
                group.addChildNode(bb)
            }

            root.addChildNode(group)
        }

        return root
    }
}
