//
//  VegetationPlacer3D.swift
//  Glasslands
//
//  Created by . . on 9/30/25.
//
//  Places trees with per-tree variation.
//  Trees now cast reliable shadows: castsShadow set on root and every geometry child.
//

import SceneKit
import GameplayKit
import UIKit

struct VegetationPlacer3D {

    @MainActor
    static func place(
        inChunk ci: IVec2,
        cfg: FirstPersonEngine.Config,
        noise: NoiseFields,
        recipe: BiomeRecipe
    ) -> [SCNNode] {
        let originTile = IVec2(ci.x * cfg.tilesX, ci.y * cfg.tilesZ)

        let ux = UInt64(bitPattern: Int64(ci.x))
        let uy = UInt64(bitPattern: Int64(ci.y))
        let seed = recipe.seed64 ^ (ux &* 0x9E3779B97F4A7C15) ^ (uy &* 0xBF58476D1CE4E5B9)
        let rng = GKMersenneTwisterRandomSource(seed: seed)
        var ra = RandomAdaptor(rng)

        var nodes: [SCNNode] = []
        let step = 4

        for tz in stride(from: 0, to: cfg.tilesZ, by: step) {
            for tx in stride(from: 0, to: cfg.tilesX, by: step) {

                let tileX = originTile.x + tx
                let tileZ = originTile.y + tz

                let h = noise.sampleHeight(Double(tileX), Double(tileZ)) / max(0.0001, recipe.height.amplitude)
                let m = noise.sampleMoisture(Double(tileX), Double(tileZ)) / max(0.0001, recipe.moisture.amplitude)
                let slope = noise.slope(Double(tileX), Double(tileZ))
                let r = noise.riverMask(Double(tileX), Double(tileZ))

                if h < 0.34 { continue }
                if slope > 0.18 { continue }
                if r > 0.50 { continue }

                let isForest = (h < 0.66) && (m > 0.52) && (slope < 0.12)
                let baseChance: Double = isForest ? 0.34 : 0.12
                if Double.random(in: 0...1, using: &ra) > baseChance { continue }

                let jx = (rng.nextUniform() - 0.5) * 0.9
                let jz = (rng.nextUniform() - 0.5) * 0.9
                let wx = (Float(tileX) + Float(jx)) * cfg.tileSize
                let wz = (Float(tileZ) + Float(jz)) * cfg.tileSize
                let wy = TerrainMath.heightWorld(x: wx, z: wz, cfg: cfg, noise: noise)

                let palette = AppColours.uiColors(from: recipe.paletteHex)
                let (tree, hitRadius, _) = makeTreeNode(palette: palette, rng: rng)

                tree.position = SCNVector3(wx, wy, wz)
                tree.setValue(CGFloat(hitRadius), forKey: "hitRadius")

                // Important: ensure the **root** casts
                tree.castsShadow = true

                applyLOD(to: tree)
                nodes.append(tree)
            }
        }
        return nodes
    }

    // MARK: - Varied low-poly conifer (no round spheres)

    private static func makeTreeNode(
        palette: [UIColor],
        rng: GKMersenneTwisterRandomSource
    ) -> (SCNNode, Float, CGFloat) {

        var r = RandomAdaptor(rng)

        let tall = rng.nextUniform() > 0.35
        let trunkH: CGFloat = tall ? CGFloat.random(in: 1.00...1.55, using: &r) : CGFloat.random(in: 0.75...1.15, using: &r)
        let trunkR: CGFloat = tall ? CGFloat.random(in: 0.06...0.10, using: &r) : CGFloat.random(in: 0.05...0.08, using: &r)

        let canopyH1: CGFloat = tall ? CGFloat.random(in: 1.50...2.10, using: &r) : CGFloat.random(in: 1.10...1.60, using: &r)
        let canopyR1: CGFloat = tall ? CGFloat.random(in: 0.55...0.80, using: &r) : CGFloat.random(in: 0.45...0.70, using: &r)
        let canopyTopR1: CGFloat = CGFloat.random(in: 0.06...0.16, using: &r)

        let twoStage = rng.nextUniform() > 0.55
        let canopyH2: CGFloat = twoStage ? canopyH1 * CGFloat.random(in: 0.55...0.75, using: &r) : 0
        let canopyR2: CGFloat = twoStage ? canopyR1 * CGFloat.random(in: 0.75...0.95, using: &r) : 0
        let canopyTopR2: CGFloat = twoStage ? canopyTopR1 * CGFloat.random(in: 0.55...0.85, using: &r) : 0

        let barkBase = palette.indices.contains(4) ? palette[4] : .brown
        let leafBase = palette.indices.contains(2) ? palette[2] : .systemGreen

        func adjust(_ c: UIColor, dH: ClosedRange<CGFloat>, dS: ClosedRange<CGFloat>, dB: ClosedRange<CGFloat>) -> UIColor {
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
            c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            h = (h + CGFloat.random(in: dH, using: &r)).truncatingRemainder(dividingBy: 1); if h < 0 { h += 1 }
            s = max(0, min(1, s + CGFloat.random(in: dS, using: &r)))
            b = max(0, min(1, b + CGFloat.random(in: dB, using: &r)))
            return UIColor(hue: h, saturation: s, brightness: b, alpha: a)
        }

        let bark = adjust(barkBase, dH: -0.02...0.02, dS: -0.08...0.08, dB: -0.05...0.05)
        let leaf = adjust(leafBase, dH: -0.03...0.03, dS: -0.10...0.10, dB: -0.06...0.06)

        // Clamp ONLY downward-facing fragments to SDR so flat undersides don’t bloom.
        let ldrClampDownFrag = """
        #pragma body
        if (_surface.normal.y < 0.05) {
            _output.color.rgb = min(_output.color.rgb, float3(0.98)) * 0.92;
        }
        """

        // Trunk
        let trunk = SCNCylinder(radius: trunkR, height: trunkH)
        let trunkMat = SCNMaterial()
        trunkMat.lightingModel = .physicallyBased
        trunkMat.diffuse.contents = bark
        trunkMat.roughness.contents = 0.95
        trunkMat.metalness.contents = 0.0
        trunk.materials = [trunkMat]

        // Canopy 1
        let canopy1 = SCNCone(topRadius: canopyTopR1, bottomRadius: canopyR1, height: canopyH1)
        canopy1.radialSegmentCount = 12
        let leafMat = SCNMaterial()
        leafMat.lightingModel = .physicallyBased
        leafMat.diffuse.contents = leaf
        leafMat.roughness.contents = 0.95
        leafMat.metalness.contents = 0.0
        leafMat.isDoubleSided = false
        leafMat.shaderModifiers = [.fragment: ldrClampDownFrag]
        canopy1.materials = [leafMat]

        // Optional second canopy
        let canopy2Geom: SCNGeometry? = twoStage ? {
            let g = SCNCone(topRadius: canopyTopR2, bottomRadius: canopyR2, height: canopyH2)
            g.radialSegmentCount = 10
            g.materials = [leafMat]   // share material
            return g
        }() : nil

        // Assemble
        let node = SCNNode()

        let trunkNode = SCNNode(geometry: trunk)
        trunkNode.position = SCNVector3(0, trunkH / 2.0, 0)
        trunkNode.castsShadow = true

        let canopyNode1 = SCNNode(geometry: canopy1)
        canopyNode1.position = SCNVector3(0, trunkH + canopyH1 * 0.5 - 0.02, 0)
        canopyNode1.castsShadow = true

        node.addChildNode(trunkNode)
        node.addChildNode(canopyNode1)

        if let g2 = canopy2Geom {
            let cn2 = SCNNode(geometry: g2)
            cn2.position = SCNVector3(0, trunkH + canopyH1 + canopyH2 * 0.45, 0)
            cn2.castsShadow = true
            node.addChildNode(cn2)
        }

        node.eulerAngles.y = Float.random(in: 0...(2 * .pi), using: &r)
        node.eulerAngles.z = Float.random(in: -0.04...0.04, using: &r)

        let treeHeight = trunkH + canopyH1 + canopyH2
        let hitRadius = Float(max(canopyR1 * 0.65, trunkR * 1.6))

        // Vegetation-only lighting category; sun includes this (0x00000403).
        node.categoryBitMask = 0x00000002

        // Also mark the root as a caster (children set above too).
        node.castsShadow = true

        return (node, hitRadius, treeHeight)
    }

    private static func applyLOD(to tree: SCNNode) {
        let far: CGFloat = 120
        for child in tree.childNodes {
            if let g = child.geometry {
                g.levelsOfDetail = [SCNLevelOfDetail(geometry: nil, worldSpaceDistance: far)]
            }
        }
    }
}
