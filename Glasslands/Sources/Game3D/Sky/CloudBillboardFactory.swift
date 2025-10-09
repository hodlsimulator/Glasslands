//
//  CloudBillboardFactory.swift
//  Glasslands
//
//  Created by . . on 10/4/25.
//
//  Builds the cloud billboard layer using volumetric impostor materials.
//  Global size scale reduces puff size so clusters feel smaller and puffier.
//

import SceneKit
import UIKit

enum CloudBillboardFactory {

    @MainActor
    static func makeNode(from clusters: [CloudClusterSpec],
                         atlas: CloudSpriteTexture.Atlas) -> SCNNode {

        let root = SCNNode()
        root.name = "CumulusBillboardLayer"
        root.castsShadow = false

        struct SizeKey: Hashable { let w: Int, h: Int }
        var materialCache: [SizeKey: SCNMaterial] = [:]
        let quant: CGFloat = 0.05

        @inline(__always)
        func materialFor(halfW: CGFloat, halfH: CGFloat) -> SCNMaterial {
            let key = SizeKey(w: Int(round(halfW / quant)),
                              h: Int(round(halfH / quant)))
            if let m = materialCache[key] { return m }

            let m = CloudImpostorProgram.makeMaterial(halfWidth: halfW, halfHeight: halfH)
            m.diffuse.contents = UIColor.white
            m.multiply.contents = UIColor.white
            m.isDoubleSided = false
            m.cullMode = .back
            m.readsFromDepthBuffer = false
            m.writesToDepthBuffer = false
            m.blendMode = .alpha

            materialCache[key] = m
            return m
        }

        // Smaller puffs → smaller, fluffier clouds (keeps look but reduces fill)
        let GLOBAL_SIZE_SCALE: CGFloat = 0.58

        for cl in clusters {
            // One billboard **per cluster** (instead of per puff)
            let group = SCNNode()
            group.castsShadow = false
            group.renderingOrder = 9_000

            let bc = SCNBillboardConstraint()
            bc.freeAxes = .all
            group.constraints = [bc]

            for p in cl.puffs {
                let size = max(0.01, CGFloat(p.size) * GLOBAL_SIZE_SCALE)
                let half = max(0.001, size * 0.5)

                let plane = SCNPlane(width: size, height: size)
                plane.firstMaterial = materialFor(halfW: half, halfH: half)

                let sprite = SCNNode(geometry: plane)
                sprite.position = SCNVector3(p.pos.x, p.pos.y, p.pos.z)
                if p.roll != 0 {
                    var ea = sprite.eulerAngles
                    ea.z = Float(p.roll)
                    sprite.eulerAngles = ea
                }
                sprite.castsShadow = false
                sprite.opacity = CGFloat(max(0.0, min(1.0, p.opacity)))
                sprite.renderingOrder = 9_000

                group.addChildNode(sprite)
            }

            root.addChildNode(group)
        }

        return root
    }
}
