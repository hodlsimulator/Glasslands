//
//  VegetationPlacer3D.swift
//  Glasslands
//
//  Created by . . on 9/30/25.
//

import SceneKit
import GameplayKit
import UIKit

struct VegetationPlacer3D {

    static func place(inChunk ci: IVec2,
                      cfg: FirstPersonEngine.Config,
                      noise: NoiseFields,
                      recipe: BiomeRecipe) -> [SCNNode] {
        let originTile = IVec2(ci.x * cfg.tilesX, ci.y * cfg.tilesZ)

        // Stable per-chunk seed (use UInt64 mixing to avoid Int64 overflow)
        let ux = UInt64(bitPattern: Int64(ci.x))
        let uy = UInt64(bitPattern: Int64(ci.y))
        let seed = recipe.seed64
            ^ (ux &* (0x9E3779B97F4A7C15 as UInt64))
            ^ (uy &* (0xBF58476D1CE4E5B9 as UInt64))
        let rng = GKMersenneTwisterRandomSource(seed: seed)
        var ra = RandomAdaptor(rng) // for Swift RNG APIs

        var nodes: [SCNNode] = []

        // Tree spacing roughly every ~3–4 tiles, jittered
        let step = 3
        for tz in stride(from: 0, to: cfg.tilesZ, by: step) {
            for tx in stride(from: 0, to: cfg.tilesX, by: step) {
                let tileX = originTile.x + tx
                let tileZ = originTile.y + tz

                // Classify locally from noise fields
                let h = noise.sampleHeight(Double(tileX), Double(tileZ)) / max(0.0001, recipe.height.amplitude)
                let m = noise.sampleMoisture(Double(tileX), Double(tileZ)) / max(0.0001, recipe.moisture.amplitude)
                let slope = noise.slope(Double(tileX), Double(tileZ))
                let r = noise.riverMask(Double(tileX), Double(tileZ))

                // Only place on land, gentle slopes; avoid river channels
                if h < 0.34 { continue }    // beach+water excluded
                if slope > 0.16 { continue }
                if r > 0.45 { continue }

                let isForest = (h < 0.62) && (m > 0.55) && (slope < 0.12)

                // Density: forests > grass
                let baseChance: Double = isForest ? 0.8 : 0.35
                // Small probability jitter using uniform RNG
                let jitter = 0.10 * Double(rng.nextUniform() - 0.5) * 2.0
                if Double.random(in: 0...1, using: &ra) > (baseChance + jitter) { continue }

                // Positional jitter ±0.3 tiles
                let jx = (rng.nextUniform() - 0.5) * 0.6
                let jz = (rng.nextUniform() - 0.5) * 0.6

                let wx = (Float(tileX) + Float(jx)) * cfg.tileSize
                let wz = (Float(tileZ) + Float(jz)) * cfg.tileSize
                let wy = Float(noise.sampleHeight(Double(tileX), Double(tileZ))) * cfg.heightScale

                let tree = makeTreeNode(palette: AppColours.uiColors(from: recipe.paletteHex), tall: isForest)
                tree.position = SCNVector3(wx, wy, wz)
                nodes.append(tree)
            }
        }

        return nodes
    }

    // Simple low-poly tree (cylinder trunk + cone canopy)
    private static func makeTreeNode(palette: [UIColor], tall: Bool) -> SCNNode {
        let trunkH: CGFloat = tall ? 1.0 : 0.7
        let trunkR: CGFloat = tall ? 0.07 : 0.06
        let canopyH: CGFloat = tall ? 1.6 : 1.2
        let canopyR: CGFloat = tall ? 0.65 : 0.52

        let trunk = SCNCylinder(radius: trunkR, height: trunkH)
        let trunkMat = SCNMaterial()
        let bark = palette.indices.contains(4) ? palette[4] : UIColor.brown
        trunkMat.diffuse.contents = bark
        trunkMat.roughness.contents = 1.0
        trunk.materials = [trunkMat]

        let cone = SCNCone(topRadius: 0.0, bottomRadius: canopyR, height: canopyH)
        let leaf = SCNMaterial()
        let green = palette.indices.contains(2) ? palette[2] : UIColor.systemGreen
        leaf.diffuse.contents = green
        leaf.roughness.contents = 0.8
        cone.materials = [leaf]

        let node = SCNNode()
        let trunkNode = SCNNode(geometry: trunk)
        trunkNode.position = SCNVector3(0, Float(trunkH/2), 0)

        let canopyNode = SCNNode(geometry: cone)
        canopyNode.position = SCNVector3(0, Float(trunkH + canopyH/2 - 0.05), 0)

        node.addChildNode(trunkNode)
        node.addChildNode(canopyNode)
        node.castsShadow = true
        return node
    }
}
