//
//  CloudBillboardFactory.swift
//  Glasslands
//
//  Created by . . on 10/4/25.
//
//  Builds the cloud billboard layer using volumetric impostor materials.
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

        struct SizeKey: Hashable { let w: Int, h: Int }
        var materialCache: [SizeKey: SCNMaterial] = [:]
        let quant: CGFloat = 0.05

        @inline(__always)
        func materialFor(halfW: CGFloat, halfH: CGFloat) -> SCNMaterial {
            let key = SizeKey(w: Int(round(halfW / quant)), h: Int(round(halfH / quant)))
            if let m = materialCache[key] { return m }
            let m = CloudImpostorProgram.makeMaterial(halfWidth: halfW, halfHeight: halfH)
            m.diffuse.contents  = UIColor.white
            m.multiply.contents = UIColor.white
            materialCache[key] = m
            return m
        }

        for cl in clusters {
            let group = SCNNode()
            group.castsShadow = false

            for p in cl.puffs {
                let size = CGFloat(p.size)
                let half = max(0.001, size * 0.5)
                let plane = SCNPlane(width: size, height: size)
                plane.firstMaterial = materialFor(halfW: half, halfH: half)

                let sprite = SCNNode(geometry: plane)
                var ea = sprite.eulerAngles
                ea.z = Float(p.roll)
                sprite.eulerAngles = ea
                sprite.castsShadow = false
                sprite.renderingOrder = 9_000 // draw AFTER sky/volumetric

                let bb = SCNNode()
                bb.position = SCNVector3(p.pos.x, p.pos.y, p.pos.z)
                let bc = SCNBillboardConstraint(); bc.freeAxes = .all
                bb.constraints = [bc]
                bb.opacity = CGFloat(max(0, min(1, p.opacity)))
                bb.renderingOrder = 9_000
                bb.addChildNode(sprite)

                group.addChildNode(bb)
            }
            root.addChildNode(group)
        }

        return root
    }
}
