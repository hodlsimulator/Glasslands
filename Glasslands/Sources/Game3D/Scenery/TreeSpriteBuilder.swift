//
//  TreeSpriteBuilder.swift
//  Glasslands
//
//  Created by . . on 10/9/25.
//
//  Builds a layered cross-plane canopy with correct alpha handling and a simple
//  3D trunk. No billboarding needed: multiple intersecting planes look like a tree
//  from any angle. Materials are set to avoid white fringes and to cast shadows.
//

import SceneKit
import UIKit
import GameplayKit

enum TreeSpriteBuilder {

    // Alpha-cutout canopy material: no white fringes, no Z fighting with itself/trunk.
    @MainActor
    static func canopyMaterial(image: UIImage, tint: UIColor?) -> SCNMaterial {
        let mat = SCNMaterial()
        mat.lightingModel = .lambert
        mat.isDoubleSided = true
        mat.blendMode = .alpha
        mat.transparencyMode = .aOne
        mat.writesToDepthBuffer = false
        mat.readsFromDepthBuffer = true

        // Texture setup (mip & clamp reduce haloing at edges)
        mat.diffuse.contents = image
        mat.diffuse.mipFilter = .linear
        mat.diffuse.minificationFilter = .linear
        mat.diffuse.magnificationFilter = .linear
        mat.diffuse.wrapS = .clamp
        mat.diffuse.wrapT = .clamp

        if let tint { mat.multiply.contents = tint }
        return mat
    }

    @MainActor
    static func barkMaterial(colour: UIColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .lambert
        m.diffuse.contents = colour
        m.metalness.contents = 0.0
        m.roughness.contents = 1.0
        m.isDoubleSided = false
        return m
    }

    // Layered cross-planes for a volumetric canopy.
    @MainActor
    static func makeCrossCanopy(image: UIImage,
                                height: CGFloat,
                                rng: inout RandomAdaptor,
                                tint: UIColor?) -> (node: SCNNode, hitR: CGFloat)
    {
        let aspect = image.size.width > 0 ? (image.size.width / max(1, image.size.height)) : 0.75
        let width  = height * CGFloat(aspect)
        let mat    = canopyMaterial(image: image, tint: tint)
        let planes = Int.random(in: 2...3, using: &rng)

        let canopy = SCNNode()
        for i in 0..<planes {
            let p = SCNPlane(width: width, height: height)
            p.cornerRadius = height * 0.02
            p.materials = [mat]
            let n = SCNNode(geometry: p)
            let step = (planes == 2) ? (.pi / 2.0) : (2.0 * .pi / 3.0)
            n.eulerAngles.y = Float(step) * Float(i)
            let s = CGFloat.random(in: 0.92...1.06, using: &rng)
            n.scale = SCNVector3(s, s, 1)
            // Render after trunk so it isn’t hidden by depth ordering.
            n.renderingOrder = 10
            canopy.addChildNode(n)
        }

        canopy.eulerAngles.y = Float.random(in: 0...(2 * .pi), using: &rng)
        let hitR = max(0.5, width * 0.55)
        return (canopy, hitR)
    }

    @MainActor
    static func makeTrunk(height: CGFloat,
                          radius: CGFloat,
                          colour: UIColor) -> SCNNode
    {
        let cyl = SCNCylinder(radius: radius, height: height)
        cyl.radialSegmentCount = 12
        cyl.heightSegmentCount = 1
        cyl.materials = [barkMaterial(colour: colour)]

        let n = SCNNode(geometry: cyl)
        n.position = SCNVector3(0, height * 0.5, 0)
        n.castsShadow = true
        return n
    }

    // Assemble trunk + canopy.
    @MainActor
    static func assembleTree(trunkHeight: CGFloat,
                             trunkRadius: CGFloat,
                             trunkColour: UIColor,
                             canopyImage: UIImage,
                             canopyHeight: CGFloat,
                             rng: inout RandomAdaptor,
                             tint: UIColor?) -> (node: SCNNode, hitR: CGFloat)
    {
        let root = SCNNode()

        let trunk = makeTrunk(height: trunkHeight, radius: trunkRadius, colour: trunkColour)
        root.addChildNode(trunk)

        let primary = makeCrossCanopy(image: canopyImage, height: canopyHeight, rng: &rng, tint: tint)
        let canopyY = trunkHeight + (canopyHeight * 0.5)
        primary.node.position = SCNVector3(0, canopyY, 0)
        root.addChildNode(primary.node)

        var hitR = max(primary.hitR, trunkRadius * 1.6)

        if Bool.random(using: &rng) {
            let s = CGFloat.random(in: 0.70...0.88, using: &rng)
            let (sec, _) = makeCrossCanopy(image: canopyImage, height: canopyHeight * s, rng: &rng, tint: tint)
            sec.position = SCNVector3(0, canopyY + canopyHeight * CGFloat.random(in: -0.10...0.10, using: &rng), 0)
            root.addChildNode(sec)
            hitR = max(hitR, primary.hitR * 0.9)
        }

        root.eulerAngles.y = Float.random(in: 0...(2 * .pi), using: &rng)
        root.eulerAngles.z = Float.random(in: -0.04...0.04, using: &rng)
        root.castsShadow = true

        return (root, hitR)
    }
}
