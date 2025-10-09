//
//  TreeSpriteBuilder.swift
//  Glasslands
//
//  Created by . . on 10/9/25.
//
//  Cross-plane tree sprite that billboards on Y and casts shadows.
//  Uses images from Assets.xcassets; falls back to a procedural PNG if needed.
//

import SceneKit
import UIKit
import GameplayKit

enum TreeSpriteBuilder {

    // Asset names added in your Assets.xcassets
    private static let assetNames = [
        "glasslands_tree_broadleaf_A",
        "glasslands_tree_broadleaf_B",
        "glasslands_tree_conifer_A",
        "glasslands_tree_conifer_B",
        "glasslands_tree_acacia_A",
        "glasslands_tree_winter_A"
    ]

    @MainActor
    static func makeTreeNode(
        palette: [UIColor],
        rng: inout RandomAdaptor
    ) -> (SCNNode, CGFloat) {

        // Pick an image from Assets; if ever nil, fall back to a procedural PNG
        let chosen = assetNames.randomElement(using: &rng) ?? assetNames[0]
        let img: UIImage = UIImage(named: chosen) ?? {
            let leaf = palette.indices.contains(2) ? palette[2] : UIColor(red: 0.32, green: 0.62, blue: 0.34, alpha: 1.0)
            let trunk = UIColor(red: 0.55, green: 0.42, blue: 0.34, alpha: 1.0)
            let seed = UInt32.random(in: 1...UInt32.max, using: &rng)
            return TreeSpriteTexture.make(size: CGSize(width: 320, height: 480), leaf: leaf, trunk: trunk, seed: seed)
        }()

        // World size in metres (tileSize is ~16). Height varies; width preserves image aspect.
        let height: CGFloat = CGFloat.random(in: 8.0...14.0, using: &rng)
        let aspect = max(0.2, img.size.width / max(img.size.height, 1))
        let width: CGFloat = max(0.5, height * aspect)

        func planeNode() -> SCNNode {
            let plane = SCNPlane(width: width, height: height)
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = img
            m.transparent.contents = img     // alpha cut-out
            m.transparencyMode = .aOne
            m.isDoubleSided = true
            m.metalness.contents = 0.0
            m.roughness.contents = 1.0
            plane.firstMaterial = m
            let n = SCNNode(geometry: plane)
            n.castsShadow = true
            return n
        }

        let root = SCNNode()
        root.name = "TreeSprite"

        // Two crossed planes for volume + Y billboarding
        let a = planeNode()
        let b = planeNode()
        b.eulerAngles = SCNVector3(0, .pi * 0.5, 0)

        root.addChildNode(a)
        root.addChildNode(b)

        let bb = SCNBillboardConstraint()
        bb.freeAxes = .Y
        root.constraints = [bb]

        // Mild natural variation
        root.eulerAngles = SCNVector3(0, Float.random(in: -0.25...0.25, using: &rng), 0)

        root.castsShadow = true
        root.categoryBitMask = 0x0000_0401

        // Cull far LOD to save fill-rate
        SceneryCommon.applyLOD(to: root, far: 320)

        // Collision radius used by the obstacle map
        let hitRadius = max(0.20, width * 0.32)
        return (root, hitRadius)
    }
}
