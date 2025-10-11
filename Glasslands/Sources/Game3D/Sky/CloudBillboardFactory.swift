//
//  CloudBillboardFactory.swift
//  Glasslands
//
//  Created by . . on 10/4/25.
//
//  Builds the cloud billboard layer using the volumetric impostor material.
//  One SCNBillboardConstraint per *cluster* (children are plain quads).
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

        // Single shared material – volumetric impostor (correct look).
        let sharedMat = CloudBillboardMaterial.makeCurrent()

        // Keep puff sizes identical to before.
        let GLOBAL_SIZE_SCALE: CGFloat = 0.58

        for cl in clusters {
            // Anchor at the cluster centroid so children can be relative.
            var ax: Float = 0, ay: Float = 0, az: Float = 0
            if !cl.puffs.isEmpty {
                for p in cl.puffs { ax += p.pos.x; ay += p.pos.y; az += p.pos.z }
                let inv = 1.0 / Float(cl.puffs.count)
                ax *= inv; ay *= inv; az *= inv
            }
            let anchor = SCNVector3(ax, ay, az)

            // One billboard constraint on the group (keep .all for the same look).
            let group = SCNNode()
            group.castsShadow = false
            group.position = anchor
            let bc = SCNBillboardConstraint()
            bc.freeAxes = .all
            group.constraints = [bc]

            // Children: simple planes with the shared volumetric material.
            for p in cl.puffs {
                let size = max(0.01, CGFloat(p.size) * GLOBAL_SIZE_SCALE)
                let plane = SCNPlane(width: size, height: size)
                plane.firstMaterial = sharedMat

                let sprite = SCNNode(geometry: plane)
                sprite.castsShadow = false
                sprite.opacity = CGFloat(max(0, min(1, p.opacity)))

                // Position relative to the anchor.
                sprite.position = SCNVector3(p.pos.x - ax, p.pos.y - ay, p.pos.z - az)

                // Roll inside the billboarded plane.
                var ea = sprite.eulerAngles
                ea.z = Float(p.roll)
                sprite.eulerAngles = ea

                // Optional tint.
                if let t = p.tint {
                    sprite.geometry?.firstMaterial?.multiply.contents =
                        UIColor(red: CGFloat(t.x), green: CGFloat(t.y), blue: CGFloat(t.z), alpha: 1.0)
                }

                group.addChildNode(sprite)
            }

            root.addChildNode(group)
        }

        return root
    }
}
