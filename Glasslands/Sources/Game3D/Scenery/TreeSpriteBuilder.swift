//
//  TreeSpriteBuilder.swift
//  Glasslands
//
//  Created by . . on 10/9/25.
//
// Cross-plane tree sprite that billboards on Y and casts shadows.
//

import SceneKit
import UIKit
import GameplayKit

enum TreeSpriteBuilder {
    @MainActor
    static func makeTreeNode(palette: [UIColor], rng: inout RandomAdaptor) -> (SCNNode, CGFloat) {
        let root = SCNNode()
        root.name = "TreeSprite"

        // Size in world metres (tileSize is 16, so 8–14m feels tree-like)
        let height: CGFloat = CGFloat.random(in: 8.0...14.0, using: &rng)
        let aspect: CGFloat = CGFloat.random(in: 0.55...0.80, using: &rng) // width/height
        let width:  CGFloat = max(0.5, height * aspect)

        // Palette
        let leafBase = palette.indices.contains(2) ? palette[2] : UIColor(red: 0.32, green: 0.62, blue: 0.34, alpha: 1.0)
        let trunkCol = UIColor(red: 0.55, green: 0.42, blue: 0.34, alpha: 1.0)

        // Procedural PNG
        let seed: UInt32 = UInt32.random(in: 1...UInt32.max, using: &rng)
        let img = TreeSpriteTexture.make(size: CGSize(width: 320, height: 480), leaf: leafBase, trunk: trunkCol, seed: seed)

        @inline(__always)
        func makePlaneNode() -> SCNNode {
            let plane = SCNPlane(width: width, height: height)
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = img
            m.transparent.contents = img          // use alpha for cut-out
            m.metalness.contents = 0.0
            m.roughness.contents = 1.0
            m.isDoubleSided = true
            m.transparencyMode = .aOne             // correct blending for alpha PNGs
            plane.firstMaterial = m
            let n = SCNNode(geometry: plane)
            n.castsShadow = true                   // each plane contributes to the shadow
            return n
        }

        // Two crossed planes for volume, then billboard the root on Y
        let a = makePlaneNode()
        let b = makePlaneNode()
        b.eulerAngles = SCNVector3(0, .pi * 0.5, 0)

        // Mild natural variation
        root.eulerAngles = SCNVector3(0, Float.random(in: -0.25...0.25, using: &rng), 0)
        root.castsShadow = true
        root.categoryBitMask = 0x0000_0401         // keep consistent with rocks/terrain
        let bb = SCNBillboardConstraint()
        bb.freeAxes = .Y
        root.constraints = [bb]

        root.addChildNode(a)
        root.addChildNode(b)

        // Cull far LOD to save fill-rate
        SceneryCommon.applyLOD(to: root, far: 320)

        // Collision radius similar to bushes/rocks (used by your obstacle map)
        let hitRadius = max(0.20, width * 0.32)
        return (root, hitRadius)
    }
}
