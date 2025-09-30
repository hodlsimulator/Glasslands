//
//  VegetationPlacer3D.swift
//  Glasslands
//
//  Created by . . on 9/30/25.
//
//  Places LOTS of trees with per-tree variation and static physics.
//  Each tree reports a "hitRadius" via KVC for collision.
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

        // Stable per-chunk seed
        let ux = UInt64(bitPattern: Int64(ci.x))
        let uy = UInt64(bitPattern: Int64(ci.y))
        let seed = recipe.seed64
            ^ (ux &* 0x9E3779B97F4A7C15)
            ^ (uy &* 0xBF58476D1CE4E5B9)
        let rng = GKMersenneTwisterRandomSource(seed: seed)
        var ra = RandomAdaptor(rng)

        var nodes: [SCNNode] = []

        // More trees: roughly every ~2 tiles, jittered.
        let step = 2

        for tz in stride(from: 0, to: cfg.tilesZ, by: step) {
            for tx in stride(from: 0, to: cfg.tilesX, by: step) {
                let tileX = originTile.x + tx
                let tileZ = originTile.y + tz

                let h = noise.sampleHeight(Double(tileX), Double(tileZ)) / max(0.0001, recipe.height.amplitude)
                let m = noise.sampleMoisture(Double(tileX), Double(tileZ)) / max(0.0001, recipe.moisture.amplitude)
                let slope = noise.slope(Double(tileX), Double(tileZ))
                let r = noise.riverMask(Double(tileX), Double(tileZ))

                // Only place on land, gentle slopes; avoid river channels
                if h < 0.34 { continue }
                if slope > 0.18 { continue }
                if r > 0.50 { continue }

                let isForest = (h < 0.66) && (m > 0.52) && (slope < 0.12)

                // Density: forests heavy, open grass sparse
                let baseChance: Double = isForest ? 0.85 : 0.45
                if Double.random(in: 0...1, using: &ra) > baseChance { continue }

                // Position jitter ±0.45 tiles
                let jx = (rng.nextUniform() - 0.5) * 0.9
                let jz = (rng.nextUniform() - 0.5) * 0.9
                let wx = (Float(tileX) + Float(jx)) * cfg.tileSize
                let wz = (Float(tileZ) + Float(jz)) * cfg.tileSize
                let wy = TerrainMath.heightWorld(x: wx, z: wz, cfg: cfg, noise: noise)

                // Tree variation (size/shape/colour/lean)
                let (tree, hitRadius, treeHeight) = makeTreeNode(
                    palette: AppColours.uiColors(from: recipe.paletteHex),
                    rng: rng
                )
                tree.position = SCNVector3(wx, wy, wz)

                // Static physics via a simple capsule; radius matches canopy spread.
                let shape = SCNPhysicsShape(geometry: SCNCapsule(capRadius: CGFloat(hitRadius), height: treeHeight), options: nil)
                let body = SCNPhysicsBody.static()
                body.physicsShape = shape
                tree.physicsBody = body
                tree.setValue(CGFloat(hitRadius), forKey: "hitRadius")

                nodes.append(tree)
            }
        }

        return nodes
    }

    // MARK: - Varied low-poly tree
    private static func makeTreeNode(palette: [UIColor], rng: GKMersenneTwisterRandomSource) -> (SCNNode, Float, CGFloat) {
        var r = RandomAdaptor(rng)

        // Random dimensions
        let tall = rng.nextUniform() > 0.35
        let trunkH: CGFloat = tall ? CGFloat.random(in: 0.9...1.4, using: &r) : CGFloat.random(in: 0.6...1.0, using: &r)
        let trunkR: CGFloat = tall ? CGFloat.random(in: 0.06...0.10, using: &r) : CGFloat.random(in: 0.05...0.08, using: &r)
        let canopyH: CGFloat = tall ? CGFloat.random(in: 1.4...2.1, using: &r) : CGFloat.random(in: 1.1...1.6, using: &r)
        let canopyR: CGFloat = tall ? CGFloat.random(in: 0.55...0.85, using: &r) : CGFloat.random(in: 0.45...0.70, using: &r)

        // Materials with slight colour variance
        let barkBase = palette.indices.contains(4) ? palette[4] : UIColor.brown
        let leafBase = palette.indices.contains(2) ? palette[2] : UIColor.systemGreen
        let bark = barkBase.adjustingHue(by: CGFloat.random(in: -0.02...0.02, using: &r),
                                         satBy: CGFloat.random(in: -0.08...0.08, using: &r),
                                         briBy: CGFloat.random(in: -0.05...0.05, using: &r))
        let leaf = leafBase.adjustingHue(by: CGFloat.random(in: -0.03...0.03, using: &r),
                                         satBy: CGFloat.random(in: -0.10...0.10, using: &r),
                                         briBy: CGFloat.random(in: -0.06...0.06, using: &r))

        // Trunk: cylinder
        let trunk = SCNCylinder(radius: trunkR, height: trunkH)
        let trunkMat = SCNMaterial()
        trunkMat.diffuse.contents = bark
        trunkMat.roughness.contents = 1.0
        trunk.materials = [trunkMat]

        // Canopy: randomly cone or low-poly sphere
        let canopyGeom: SCNGeometry
        if rng.nextBool() {
            let cone = SCNCone(topRadius: 0.0, bottomRadius: canopyR, height: canopyH)
            canopyGeom = cone
        } else {
            let sphere = SCNSphere(radius: canopyR * 0.88)
            sphere.segmentCount = 10
            canopyGeom = sphere
        }
        let leafMat = SCNMaterial()
        leafMat.diffuse.contents = leaf
        leafMat.roughness.contents = 0.85
        canopyGeom.materials = [leafMat]

        let node = SCNNode()
        let trunkNode = SCNNode(geometry: trunk)
        trunkNode.position = SCNVector3(0, Float(trunkH/2), 0)

        let canopyNode = SCNNode(geometry: canopyGeom)
        canopyNode.position = SCNVector3(0, Float(trunkH + canopyH*0.5 - 0.05), 0)

        node.addChildNode(trunkNode)
        node.addChildNode(canopyNode)
        node.castsShadow = true

        // Random rotation and lean for variety
        node.eulerAngles.y = Float.random(in: 0...(2 * .pi), using: &r)
        node.eulerAngles.z = Float.random(in: -0.05...0.05, using: &r)

        let treeHeight = trunkH + canopyH
        let hitRadius = Float(max(canopyR * 0.65, trunkR * 1.6))

        return (node, hitRadius, treeHeight)
    }
}

private extension UIColor {
    func adjustingHue(by dH: CGFloat, satBy dS: CGFloat, briBy dB: CGFloat) -> UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        h = (h + dH).truncatingRemainder(dividingBy: 1); if h < 0 { h += 1 }
        s = max(0, min(1, s + dS))
        b = max(0, min(1, b + dB))
        return UIColor(hue: h, saturation: s, brightness: b, alpha: a)
    }
}
