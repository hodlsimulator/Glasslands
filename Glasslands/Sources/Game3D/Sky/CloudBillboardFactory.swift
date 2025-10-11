//
//  CloudBillboardFactory.swift
//  Glasslands
//
//  Created by . . on 10/4/25.
//
//  Builds the cloud billboard layer using a two-pass approach per puff:
//  1) Depth-mask pass: exact silhouette, writes DEPTH only (no colour).
//  2) Volumetric pass: your existing impostor shader, reads depth.
//  Keeps quality and .all billboarding, but removes full-screen cloud stalls.
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

        let GLOBAL_SIZE_SCALE: CGFloat = 0.58

        for cl in clusters {
            for p in cl.puffs {
                let size = max(0.01, CGFloat(p.size) * GLOBAL_SIZE_SCALE)

                let plane = SCNPlane(width: size, height: size)
                let mat = CloudBillboardMaterial.makeCurrent()
                mat.blendMode = .alpha
                mat.readsFromDepthBuffer = false
                mat.writesToDepthBuffer = false
                mat.isDoubleSided = true
                plane.firstMaterial = mat

                // Pad the bounds so frustum culling never drops an edge-on sprite
                let pad = Float(size) * 0.75
                plane.boundingBox = (
                    min: SCNVector3(-pad, -pad, -pad),
                    max: SCNVector3( pad,  pad,  pad)
                )

                let node = SCNNode(geometry: plane)
                node.name = "CloudPuff"
                node.castsShadow = false
                node.opacity = CGFloat(max(0, min(1, p.opacity)))
                node.position = SCNVector3(p.pos.x, p.pos.y, p.pos.z)

                // NOTE: no SCNBillboardConstraint — we’ll face the camera manually each frame
                var ea = node.eulerAngles
                ea.z = Float(p.roll) // keep in-plane roll from spec
                node.eulerAngles = ea

                if let t = p.tint {
                    node.geometry?.firstMaterial?.multiply.contents =
                        UIColor(red: CGFloat(t.x), green: CGFloat(t.y), blue: CGFloat(t.z), alpha: 1.0)
                }

                node.renderingOrder = 0
                root.addChildNode(node)
            }
        }
        return root
    }
}
