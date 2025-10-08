//
//  RockBuilder.swift
//  Glasslands
//
//  Created by . . on 10/4/25.
//

import SceneKit
import UIKit
import simd
import GameplayKit

enum RockBuilder {
    static func makeRockNode(size: CGFloat, palette: [UIColor], rng: inout RandomAdaptor) -> (SCNNode, CGFloat) {
        // Irregular squashed ellipsoid
        let baseR = max(0.05, size)
        let geom = SCNSphere(radius: baseR)
        geom.segmentCount = 18

        let rockBase = palette.indices.contains(3) ? palette[3] : UIColor(white: 0.90, alpha: 1.0)
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = rockBase
        m.roughness.contents = 0.98
        m.metalness.contents = 0.0
        geom.materials = [m]

        let node = SCNNode(geometry: geom)

        // Non-uniform scale to break the sphere silhouette
        let sx = CGFloat.random(in: 0.75...1.25, using: &rng)
        let sy = CGFloat.random(in: 0.55...0.90, using: &rng)
        let sz = CGFloat.random(in: 0.75...1.25, using: &rng)
        node.scale = SCNVector3(sx, sy, sz)

        // Keep original categories (default + terrain) and turn on shadows
        node.categoryBitMask = 0x00000401
        node.castsShadow = true

        SceneryCommon.applyLOD(to: node, far: 120)
        // Keep similar hit radius to previous implementation
        return (node, size * 0.55)
    }
}
