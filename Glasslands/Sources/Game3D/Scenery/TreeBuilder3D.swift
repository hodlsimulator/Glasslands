//
//  TreeBuilder3D.swift
//  Glasslands
//
//  Created by . . on 10/9/25.
//
//  Procedural 3D trees optimised for mobile.
//  Builds a single *flattened* visual mesh that *casts real shadows*.
//  Materials are simple (Lambert), segment counts are low, and LOD culls far trees.
//

import SceneKit
import GameplayKit
import UIKit
import simd

enum TreeBuilder3D {

    enum Species: CaseIterable { case broadleaf, conifer }

    // Shared base materials (cheap)
    private static let barkMaterial: SCNMaterial = {
        let m = SCNMaterial()
        m.lightingModel = .lambert
        m.diffuse.contents = UIColor(red: 0.50, green: 0.40, blue: 0.33, alpha: 1)
        m.metalness.contents = 0.0
        m.roughness.contents = 1.0
        m.isDoubleSided = false
        return m
    }()

    private static let leafMaterial: SCNMaterial = {
        let m = SCNMaterial()
        m.lightingModel = .lambert
        m.diffuse.contents = UIColor(red: 0.28, green: 0.60, blue: 0.34, alpha: 1)
        m.metalness.contents = 0.0
        m.roughness.contents = 1.0
        m.isDoubleSided = false
        return m
    }()

    // Builds a prototype tree: a *flattened* visual mesh that casts shadows.
    // Clone this node for placements (keeps geometry/materials shared).
    @MainActor
    static func makePrototype(
        palette: [UIColor],
        rng: inout RandomAdaptor,
        prefer speciesHint: Species? = nil
    ) -> (node: SCNNode, hitR: CGFloat) {

        let species = speciesHint ?? (Bool.random(using: &rng) ? .broadleaf : .conifer)

        // Palette tints (copy materials so prototypes vary without adding many materials)
        func tinted(_ base: SCNMaterial, from col: UIColor,
                    dH: ClosedRange<CGFloat>, dS: ClosedRange<CGFloat>, dB: ClosedRange<CGFloat>) -> SCNMaterial {
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
            col.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            var nh = (h + CGFloat.random(in: dH, using: &rng)).truncatingRemainder(dividingBy: 1); if nh < 0 { nh += 1 }
            let ns = max(0, min(1, s + CGFloat.random(in: dS, using: &rng)))
            let nb = max(0, min(1, b + CGFloat.random(in: dB, using: &rng)))
            let c = UIColor(hue: nh, saturation: ns, brightness: nb, alpha: a)
            let m = base.copy() as! SCNMaterial
            m.diffuse.contents = c
            return m
        }

        let barkBase = palette.indices.contains(4) ? palette[4] : (TreeBuilder3D.barkMaterial.diffuse.contents as? UIColor ?? .brown)
        let leafBase = palette.indices.contains(2) ? palette[2] : (TreeBuilder3D.leafMaterial.diffuse.contents as? UIColor ?? .green)
        let barkMat  = tinted(TreeBuilder3D.barkMaterial, from: barkBase, dH: -0.010...0.010, dS: -0.05...0.05, dB: -0.05...0.05)
        let leafMat  = tinted(TreeBuilder3D.leafMaterial, from: leafBase, dH: -0.020...0.020, dS: -0.08...0.08, dB: -0.06...0.06)

        // World size (metres). Tile ≈ 16 m.
        let height: CGFloat = {
            switch species {
            case .broadleaf: return CGFloat.random(in: 8.5...13.5, using: &rng)
            case .conifer:   return CGFloat.random(in: 10.0...16.0, using: &rng)
            }
        }()

        // Build visual hierarchy then flatten into a single mesh
        let buildRoot = SCNNode()
        let hitR: CGFloat
        switch species {
        case .conifer:
            hitR = buildConifer(into: buildRoot, height: height, bark: barkMat, leaf: leafMat, rng: &rng)
        case .broadleaf:
            hitR = buildBroadleaf(into: buildRoot, height: height, bark: barkMat, leaf: leafMat, rng: &rng)
        }

        // Flatten to merge geometry → one draw, then enable shadows on the result
        let visual = buildRoot.flattenedClone()
        visual.name = "Tree3D"
        visual.castsShadow = true
        visual.categoryBitMask = 0x0000_0002
        if let g = visual.geometry {
            g.levelsOfDetail = [SCNLevelOfDetail(geometry: nil, worldSpaceDistance: 180)]
        }

        // Slight random lean/rotation for character
        visual.eulerAngles.y = Float.random(in: 0...(2 * .pi), using: &rng)
        visual.eulerAngles.z = Float.random(in: -0.04...0.04, using: &rng)

        return (visual, hitR)
    }

    // MARK: - Species builders (append parts into `root`, return hit radius)

    // Conifer: trunk + 3–4 cones
    @MainActor
    private static func buildConifer(
        into root: SCNNode,
        height: CGFloat,
        bark: SCNMaterial,
        leaf: SCNMaterial,
        rng: inout RandomAdaptor
    ) -> CGFloat {

        let trunkH = height * CGFloat.random(in: 0.26...0.34, using: &rng)
        let trunkRBase = height * CGFloat.random(in: 0.035...0.048, using: &rng)
        let trunkRTip  = trunkRBase * CGFloat.random(in: 0.42...0.60, using: &rng)

        let trunk = SCNCone(topRadius: trunkRTip, bottomRadius: trunkRBase, height: trunkH)
        trunk.radialSegmentCount = 10
        trunk.materials = [bark]

        let trunkNode = SCNNode(geometry: trunk)
        trunkNode.position = SCNVector3(0, trunkH * 0.5, 0)
        root.addChildNode(trunkNode)

        let tiers = Int.random(in: 3...4, using: &rng)
        var y = trunkH
        var widest: CGFloat = trunkRBase

        for i in 0..<tiers {
            let t = CGFloat(i) / CGFloat(max(1, tiers - 1))
            let segH = (height - trunkH) * (0.28 + 0.20 * (1 - t)) * CGFloat.random(in: 0.95...1.05, using: &rng)
            let rBottom = max(0.10, (height * 0.20) * (1.0 - t) * CGFloat.random(in: 0.90...1.05, using: &rng))
            let rTop = rBottom * CGFloat.random(in: 0.14...0.25, using: &rng)
            widest = max(widest, rBottom)

            let cone = SCNCone(topRadius: rTop, bottomRadius: rBottom, height: segH)
            cone.radialSegmentCount = 10
            cone.materials = [leaf]

            let n = SCNNode(geometry: cone)
            n.position = SCNVector3(0, y + segH * 0.5, 0)
            root.addChildNode(n)
            y += segH * 0.92
        }

        return max(widest * 0.75, trunkRBase * 1.6)
    }

    // Broadleaf: tapered trunk + a few branches + a few leaf blobs
    @MainActor
    private static func buildBroadleaf(
        into root: SCNNode,
        height: CGFloat,
        bark: SCNMaterial,
        leaf: SCNMaterial,
        rng: inout RandomAdaptor
    ) -> CGFloat {

        let trunkH = height * CGFloat.random(in: 0.44...0.56, using: &rng)
        let trunkRBase = height * CGFloat.random(in: 0.045...0.060, using: &rng)
        let trunkRTip  = trunkRBase * CGFloat.random(in: 0.35...0.55, using: &rng)

        let trunk = SCNCone(topRadius: trunkRTip, bottomRadius: trunkRBase, height: trunkH)
        trunk.radialSegmentCount = 12
        trunk.materials = [bark]
        let trunkNode = SCNNode(geometry: trunk)
        trunkNode.position = SCNVector3(0, trunkH * 0.5, 0)
        root.addChildNode(trunkNode)

        let branchCount = Int.random(in: 4...5, using: &rng)
        let crownH = height - trunkH
        let startY = trunkH * CGFloat.random(in: 0.48...0.68, using: &rng)

        var widest: CGFloat = trunkRBase

        for i in 0..<branchCount {
            let ang = (Float(i) / Float(branchCount)) * (2 * .pi) + Float.random(in: -0.35...0.35, using: &rng)
            let tilt = Float.random(in: 0.20...0.40, using: &rng)
            let dir = simd_normalize(SIMD3<Float>(cos(ang), tan(tilt), sin(ang)))

            let len = Float(crownH) * Float.random(in: 0.40...0.58, using: &rng)
            let rBase = trunkRBase * CGFloat.random(in: 0.30...0.40, using: &rng)
            let rTip  = rBase * CGFloat.random(in: 0.20...0.35, using: &rng)

            let base = SIMD3<Float>(0, Float(startY + CGFloat.random(in: -0.15...0.15, using: &rng)), 0)
            let tip  = base + dir * len

            // Branch
            let branchLen = max(0.001, simd_length(tip - base))
            let branchCone = SCNCone(topRadius: rTip, bottomRadius: rBase, height: CGFloat(branchLen))
            branchCone.radialSegmentCount = 8
            branchCone.materials = [bark]
            let bn = SCNNode(geometry: branchCone)
            bn.simdPosition = (base + tip) * 0.5
            bn.simdOrientation = quatAligning(from: SIMD3<Float>(0, 1, 0), to: simd_normalize(tip - base))
            root.addChildNode(bn)

            // Leaf blob
            let blobR = crownH * CGFloat.random(in: 0.24...0.34, using: &rng)
            let sphere = SCNSphere(radius: blobR)
            sphere.segmentCount = 8
            sphere.materials = [leaf]
            let ln = SCNNode(geometry: sphere)
            ln.simdPosition = tip
            root.addChildNode(ln)

            widest = max(widest, CGFloat(len) * 0.55, blobR)
        }

        return max(widest, trunkRBase * 1.8)
    }

    // Quaternion rotating 'from' to 'to'
    private static func quatAligning(from u: SIMD3<Float>, to v: SIMD3<Float>) -> simd_quatf {
        let f = simd_normalize(u)
        let t = simd_normalize(v)
        let c = simd_dot(f, t)
        if c > 0.9999 { return simd_quatf(angle: 0, axis: SIMD3<Float>(0,1,0)) }
        if c < -0.9999 {
            let axis0 = simd_cross(f, SIMD3<Float>(1,0,0))
            let axis = simd_length(axis0) < 1e-4 ? SIMD3<Float>(0,0,1) : simd_normalize(axis0)
            return simd_quatf(angle: .pi, axis: axis)
        }
        let axis = simd_normalize(simd_cross(f, t))
        let s = sqrt((1 + c) * 2)
        let invs = 1 / s
        return simd_quatf(ix: axis.x * invs, iy: axis.y * invs, iz: axis.z * invs, r: s * 0.5)
    }
}
