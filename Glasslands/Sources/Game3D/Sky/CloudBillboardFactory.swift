//
//  CloudBillboardFactory.swift
//  Glasslands
//
//  Created by . . on 10/4/25.
//
//  Builds the cloud billboard layer using volumetric impostor materials.
//  Each cluster is a single billboarded group; individual puffs are plain nodes.
//  This eliminates hundreds of per-puff SCNBillboardConstraints while keeping the look.

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

        struct SizeKey: Hashable { let w: Int; let h: Int }
        var materialCache: [SizeKey: SCNMaterial] = [:]

        // Quantise half-sizes a bit so we reuse materials aggressively.
        let quant: CGFloat = 0.05

        @inline(__always)
        func materialFor(halfW: CGFloat, halfH: CGFloat) -> SCNMaterial {
            let key = SizeKey(w: Int(round(halfW / quant)), h: Int(round(halfH / quant)))
            if let m = materialCache[key] { return m }

            let m = CloudImpostorProgram.makeMaterial(halfWidth: halfW, halfHeight: halfH)

            // Keep blending (for soft vapour), but avoid extra work.
            m.isDoubleSided = false
            m.cullMode = .back
            m.blendMode = .alpha
            m.readsFromDepthBuffer = true
            m.writesToDepthBuffer = false       // keep transparent sorting correct
            m.lightingModel = .constant
            m.diffuse.contents = UIColor.white
            m.multiply.contents = UIColor.white
            materialCache[key] = m
            return m
        }

        // Global scale keeps puffs visually identical to previous builds.
        let GLOBAL_SIZE_SCALE: CGFloat = 0.58

        for cl in clusters {
            // Compute a stable anchor so puffs can be positioned relatively.
            var ax: Float = 0, ay: Float = 0, az: Float = 0
            if !cl.puffs.isEmpty {
                for p in cl.puffs { ax += p.pos.x; ay += p.pos.y; az += p.pos.z }
                let inv = 1.0 / Float(cl.puffs.count)
                ax *= inv; ay *= inv; az *= inv
            }
            let anchor = SCNVector3(ax, ay, az)

            // Cluster group: single billboard constraint (replaces per-puff constraints).
            let group = SCNNode()
            group.castsShadow = false
            group.position = anchor
            // No SCNBillboardConstraint: orientation is set manually each frame (see FirstPersonEngine+Clouds).

            // Build sprites under the group.
            for p in cl.puffs {
                let size = max(0.01, CGFloat(p.size) * GLOBAL_SIZE_SCALE)
                let half = max(0.001, size * 0.5)

                let plane = SCNPlane(width: size, height: size)
                plane.firstMaterial = materialFor(halfW: half, halfH: half)

                let sprite = SCNNode(geometry: plane)
                sprite.castsShadow = false
                sprite.opacity = CGFloat(max(0, min(1, p.opacity)))

                // Relative offset from the group’s anchor.
                sprite.position = SCNVector3(p.pos.x - ax, p.pos.y - ay, p.pos.z - az)

                // Roll within the billboarded plane.
                var ea = sprite.eulerAngles
                ea.z = Float(p.roll)
                sprite.eulerAngles = ea

                // Optional subtle tint (kept as multiply to preserve premultiplied look).
                if let t = p.tint {
                    sprite.geometry?.firstMaterial?.multiply.contents =
                        UIColor(red: CGFloat(t.x), green: CGFloat(t.y), blue: CGFloat(t.z), alpha: 1.0)
                }

                // Let SceneKit choose ordering; do not force renderingOrder here.
                group.addChildNode(sprite)
            }

            root.addChildNode(group)
        }

        return root
    }
}
