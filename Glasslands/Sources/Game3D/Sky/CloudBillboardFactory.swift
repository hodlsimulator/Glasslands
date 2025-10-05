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
                let m = template.copy() as! SCNMaterial

                // ALWAYS bind a valid image; clamp atlas index to non-negative.
                let count = max(1, atlas.images.count)
                let safeIndex = ((p.atlasIndex % count) + count) % count
                var img = atlas.images.isEmpty ? CloudSpriteTexture.fallbackWhite2x2 : atlas.images[safeIndex]
                // Ensure CGImage-backed; otherwise fallback.
                if img.cgImage == nil && img.ciImage == nil {
                    img = CloudSpriteTexture.fallbackWhite2x2
                }

                // Bind to standard diffuse (for SceneKit’s own sampling)
                m.diffuse.contents = img
                // CRITICAL: also bind to the shader-argument name used in the modifier.
                let prop = SCNMaterialProperty(contents: img)
                prop.wrapS = .clamp
                prop.wrapT = .clamp
                prop.mipFilter = .linear
                prop.minificationFilter = .linear
                prop.magnificationFilter = .linear
                prop.maxAnisotropy = 4.0
                m.setValue(prop, forKey: "u_diffuseTexture")

                // Optional per-puff tint/opacity
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
