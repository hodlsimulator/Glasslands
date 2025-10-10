//
//  TreeBuilder3D.swift
//  Glasslands
//
//  Created by . . on 10/9/25.
//
//  Orchestrates real 3D trees (bark tubes + alpha-test leaf cards).
//  Draw calls per tree: 2 (bark, leaves). Leaves hidden at far LOD.
//

import SceneKit
import GameplayKit
import UIKit
import simd

enum TreeBuilder3D {

    enum Species: CaseIterable { case broadleaf, conifer }

    private static var poolBroadleaf: [SCNNode] = []
    private static var poolConifer:   [SCNNode] = []

    /// Optional: call once at scene start to avoid any rotation hitch.
    @MainActor
    static func prewarm(palette: [UIColor], countPerSpecies: Int = 4) {
        var rng = RandomAdaptor(GKMersenneTwisterRandomSource(seed: 12345))
        for _ in 0..<countPerSpecies {
            let b = buildOnce(species: .broadleaf,
                              barkCol: palette.indices.contains(4) ? palette[4] : UIColor.brown,
                              leafCol: palette.indices.contains(2) ? palette[2] : UIColor.green,
                              rng: &rng).node
            poolBroadleaf.append(b)
            let c = buildOnce(species: .conifer,
                              barkCol: palette.indices.contains(4) ? palette[4] : UIColor.brown,
                              leafCol: palette.indices.contains(2) ? palette[2] : UIColor.green,
                              rng: &rng).node
            poolConifer.append(c)
        }
    }

    @MainActor
    static func makePrototype(
        palette: [UIColor],
        rng: inout RandomAdaptor,
        prefer speciesHint: Species? = nil
    ) -> (node: SCNNode, hitR: CGFloat) {

        let species: Species = speciesHint ?? (Bool.random(using: &rng) ? .broadleaf : .conifer)

        func jitter(_ base: UIColor,
                    dH: ClosedRange<CGFloat>,
                    dS: ClosedRange<CGFloat>,
                    dB: ClosedRange<CGFloat>) -> UIColor
        {
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
            base.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            var nh = (h + CGFloat.random(in: dH, using: &rng)).truncatingRemainder(dividingBy: 1)
            if nh < 0 { nh += 1 }
            let ns = max(0, min(1, s + CGFloat.random(in: dS, using: &rng)))
            let nb = max(0, min(1, b + CGFloat.random(in: dB, using: &rng)))
            return UIColor(hue: nh, saturation: ns, brightness: nb, alpha: a)
        }

        let barkBase = palette.indices.contains(4) ? palette[4] : UIColor(red: 0.50, green: 0.40, blue: 0.33, alpha: 1)
        let leafBase = palette.indices.contains(2) ? palette[2] : UIColor(red: 0.28, green: 0.60, blue: 0.34, alpha: 1)
        let barkCol  = jitter(barkBase, dH: -0.010...0.010, dS: -0.05...0.05, dB: -0.05...0.05)
        let leafCol  = jitter(leafBase, dH: -0.020...0.020, dS: -0.08...0.08, dB: -0.06...0.06)

        if let clone = cloneFromPool(species: species) {
            tintMaterials(on: clone, bark: barkCol)
            return (clone, estimatedHitRadius(for: clone))
        }

        // Build a few and pool them, then clone
        let built = buildOnce(species: species, barkCol: barkCol, leafCol: leafCol, rng: &rng)
        addToPool(species: species, node: built.node)
        let out = cloneFromPool(species: species) ?? built.node.clone()
        return (out, estimatedHitRadius(for: out))
    }

    // MARK: - Build

    @MainActor
    private static func buildOnce(
        species: Species,
        barkCol: UIColor,
        leafCol: UIColor,
        rng: inout RandomAdaptor
    ) -> (node: SCNNode, hitR: CGFloat) {

        let totalH: CGFloat = {
            switch species {
            case .broadleaf: return CGFloat.random(in: 8.5...13.5, using: &rng)
            case .conifer:   return CGFloat.random(in: 10.0...16.0, using: &rng)
            }
        }()

        let trunkH: CGFloat
        let trunkR: CGFloat
        let primaryCount: Int
        let secondaryPerPrimary: ClosedRange<Int>
        let branchTilt: ClosedRange<CGFloat>
        let crownRatio: ClosedRange<CGFloat>
        let leafCount: Int
        let leafSize: ClosedRange<CGFloat>

        switch species {
        case .broadleaf:
            trunkH               = totalH * CGFloat.random(in: 0.44...0.52, using: &rng)
            trunkR               = totalH * CGFloat.random(in: 0.024...0.032, using: &rng)
            primaryCount         = Int.random(in: 5...7, using: &rng)
            secondaryPerPrimary  = 2...3
            branchTilt           = (.pi/180*18)...(.pi/180*34)
            crownRatio           = 0.60...0.80
            leafCount            = Int(CGFloat.random(in: 140...200, using: &rng))
            leafSize             = 0.16...0.26
        case .conifer:
            trunkH               = totalH * CGFloat.random(in: 0.30...0.38, using: &rng)
            trunkR               = totalH * CGFloat.random(in: 0.020...0.028, using: &rng)
            primaryCount         = Int.random(in: 6...8, using: &rng)
            secondaryPerPrimary  = 1...2
            branchTilt           = (.pi/180*10)...(.pi/180*22)
            crownRatio           = 0.68...0.92
            leafCount            = Int(CGFloat.random(in: 180...260, using: &rng))
            leafSize             = 0.12...0.20
        }

        let barkMat = TreeMaterials.barkMaterial(colour: barkCol)
        let bark = BarkMeshBuilder.build(
            species: species,
            totalHeight: totalH,
            trunkHeight: trunkH,
            trunkRadius: trunkR,
            primaryCount: primaryCount,
            secondaryPerPrimary: secondaryPerPrimary,
            branchTilt: branchTilt,
            crownRatio: crownRatio,
            material: barkMat,
            rng: &rng
        )

        let leafTex = TreeMaterials.makeLeafTexture(colour: leafCol)
        var rngCopy = rng
        let leavesGeom = LeafCardMesh.build(
            anchors: bark.leafAnchors,
            totalCount: leafCount,
            sizeRange: SIMD2<Float>(Float(leafSize.lowerBound), Float(leafSize.upperBound)),
            rng: &rngCopy
        )
        let leavesMat = TreeMaterials.leafMaterial(texture: leafTex, alphaCutoff: 0.30)
        leavesGeom.materials = [leavesMat]
        let leavesNode = SCNNode(geometry: leavesGeom)
        leavesNode.name = "TreeLeaves"
        leavesNode.castsShadow = true
        leavesGeom.levelsOfDetail = [SCNLevelOfDetail(geometry: nil, worldSpaceDistance: 180)]

        let root = SCNNode()
        root.name = "Tree3D"
        root.addChildNode(bark.node)
        root.addChildNode(leavesNode)

        root.eulerAngles.y = Float.random(in: 0...(2 * .pi), using: &rng)
        root.eulerAngles.z = Float.random(in: -0.03...0.03, using: &rng)
        root.castsShadow = true

        return (root, estimatedHitRadius(for: root))
    }

    // MARK: - Pool helpers

    @MainActor
    private static func addToPool(species: Species, node: SCNNode) {
        switch species {
        case .broadleaf: poolBroadleaf.append(node)
        case .conifer:   poolConifer.append(node)
        }
    }

    @MainActor
    private static func cloneFromPool(species: Species) -> SCNNode? {
        let src: SCNNode? = {
            switch species {
            case .broadleaf: return poolBroadleaf.randomElement()
            case .conifer:   return poolConifer.randomElement()
            }
        }()
        guard let base = src else { return nil }
        let clone = base.clone()
        clone.castsShadow = true
        let s = Float.random(in: 0.94...1.06)
        clone.scale = SCNVector3(s, s, s)
        clone.eulerAngles.y += Float.random(in: 0...(2 * .pi))
        return clone
    }

    @MainActor
    private static func tintMaterials(on node: SCNNode, bark: UIColor) {
        node.enumerateChildNodes { n, _ in
            if let g = n.geometry {
                for m in g.materials where m.shaderModifiers == nil {
                    m.diffuse.contents = bark
                }
            }
        }
    }

    private static func estimatedHitRadius(for node: SCNNode) -> CGFloat {
        var r: Float = 0
        node.enumerateChildNodes { n, _ in
            let p = n.simdWorldPosition
            r = max(r, hypot(p.x, p.z))
        }
        return CGFloat(max(1, r))
    }
}
