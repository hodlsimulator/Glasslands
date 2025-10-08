//
//  SceneryPlacer3D.swift
//  Glasslands
//
//  Created by . . on 10/4/25.
//
//  Placement orchestrator for non-tree props.
//  Keeps flower-sprite helpers here; other shapes live under Scenery.
//

import SceneKit
import GameplayKit
import UIKit
import simd

struct SceneryPlacer3D {
    static func place(inChunk ci: IVec2,
                      cfg: FirstPersonEngine.Config,
                      noise: NoiseFields,
                      recipe: BiomeRecipe) -> [SCNNode] {
        let originTile = IVec2(ci.x * cfg.tilesX, ci.y * cfg.tilesZ)
        let seed = recipe.seed64
            ^ (UInt64(bitPattern: Int64(ci.x)) &* 0x9E3779B97F4A7C15)
            ^ (UInt64(bitPattern: Int64(ci.y)) &* 0xBF58476D1CE4E5B9)
        let rng = GKMersenneTwisterRandomSource(seed: seed)
        var ra = RandomAdaptor(rng)
        var nodes: [SCNNode] = []
        let palette = AppColours.uiColors(from: recipe.paletteHex)

        let step = 4
        for tz in stride(from: 0, to: cfg.tilesZ, by: step) {
            for tx in stride(from: 0, to: cfg.tilesX, by: step) {
                let tileX = originTile.x + tx
                let tileZ = originTile.y + tz

                let h = noise.sampleHeight(Double(tileX), Double(tileZ)) / max(0.0001, recipe.height.amplitude)
                let m = noise.sampleMoisture(Double(tileX), Double(tileZ)) / max(0.0001, recipe.moisture.amplitude)
                let s = noise.slope(Double(tileX), Double(tileZ))
                let r = noise.riverMask(Double(tileX), Double(tileZ))
                if h < 0.30 { continue }

                let jx = (rng.nextUniform() - 0.5) * 0.9
                let jz = (rng.nextUniform() - 0.5) * 0.9
                let wx = (Float(tileX) + Float(jx)) * cfg.tileSize
                let wz = (Float(tileZ) + Float(jz)) * cfg.tileSize
                let wy = TerrainMath.heightWorld(x: wx, z: wz, cfg: cfg, noise: noise)

                // Rocks
                if (s > 0.18 || h > 0.80), Double.random(in: 0...1, using: &ra) < 0.18 {
                    let group = SCNNode()
                    let count = Int.random(in: 1...3, using: &ra)
                    for i in 0..<count {
                        let off = SIMD2(Float.random(in: -0.8...0.8, using: &ra),
                                        Float.random(in: -0.8...0.8, using: &ra))
                        let px = wx + off.x, pz = wz + off.y
                        let py = TerrainMath.heightWorld(x: px, z: pz, cfg: cfg, noise: noise)
                        let size = CGFloat.random(in: 0.25...0.55, using: &ra) * CGFloat(1 + 0.35 * Float(i))
                        let (rock, rad) = RockBuilder.makeRockNode(size: size, palette: palette, rng: &ra)
                        rock.position = SCNVector3(px, py, pz)
                        rock.setValue(rad, forKey: "hitRadius")
                        group.addChildNode(rock)
                    }
                    group.position.y += 0.01
                    group.name = "rocks"
                    enableShadowsRecursively(group)   // ← enable casting for all rocks in the group
                    nodes.append(group); continue
                }

                // Flowers (sprites) — no casting
                if (m > 0.40 && m < 0.75) && s < 0.12 && r < 0.50,
                   Double.random(in: 0...1, using: &ra) < 0.14 {
                    let patch = makeFlowerPatchNode(palette: palette, rng: &ra)
                    patch.position = SCNVector3(wx, wy + 0.02, wz)
                    patch.setValue(CGFloat(0.20), forKey: "hitRadius")
                    nodes.append(patch); continue
                }

                // Mushrooms
                if (m > 0.62 && h < 0.70) && s < 0.12 && r < 0.50,
                   Double.random(in: 0...1, using: &ra) < 0.10 {
                    let patch = MushroomBuilder.makeMushroomPatchNode(palette: palette, rng: &ra)
                    patch.position = SCNVector3(wx, wy, wz)
                    patch.setValue(CGFloat(0.18), forKey: "hitRadius")
                    enableShadowsRecursively(patch)   // ← mushrooms cast
                    nodes.append(patch); continue
                }

                // Reeds
                if r > 0.58 && s < 0.18,
                   Double.random(in: 0...1, using: &ra) < 0.16 {
                    let patch = ReedBuilder.makeReedPatchNode(palette: palette, rng: &ra)
                    patch.position = SCNVector3(wx, wy, wz)
                    patch.setValue(CGFloat(0.22), forKey: "hitRadius")
                    enableShadowsRecursively(patch)   // ← reeds cast
                    nodes.append(patch); continue
                }

                // Crystals
                if (m < 0.30 && h > 0.50 && s < 0.16),
                   Double.random(in: 0...1, using: &ra) < 0.06 {
                    let cluster = CrystalBuilder.makeCrystalClusterNode(palette: palette, rng: &ra)
                    cluster.position = SCNVector3(wx, wy, wz)
                    cluster.setValue(CGFloat(0.22), forKey: "hitRadius")
                    enableShadowsRecursively(cluster) // ← crystals cast
                    nodes.append(cluster); continue
                }

                // Bushes
                if (m > 0.50 && h < 0.75 && s < 0.16 && r < 0.50),
                   Double.random(in: 0...1, using: &ra) < 0.16 {
                    let bush = BushBuilder.makeBushNode(palette: palette, rng: &ra)
                    bush.position = SCNVector3(wx, wy, wz)
                    bush.setValue(CGFloat(0.28), forKey: "hitRadius")
                    enableShadowsRecursively(bush)    // ← bushes cast
                    nodes.append(bush); continue
                }
            }
        }

        return nodes
    }

    // MARK: - Flower sprites kept local

    private static func makeFlowerPatchNode(palette: [UIColor], rng: inout RandomAdaptor) -> SCNNode {
        let node = SCNNode()
        let count = Int.random(in: 4...8, using: &rng)
        for _ in 0..<count {
            let size = CGFloat.random(in: 0.10...0.18, using: &rng)
            let plane = SCNPlane(width: size, height: size)
            plane.cornerRadius = size * 0.5

            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = flowerSpriteImage(
                diameter: Int(ceil(size * 128)),
                tint: randomFlowerTint(palette: palette, rng: &rng)
            )
            m.isDoubleSided = true
            m.writesToDepthBuffer = false
            plane.materials = [m]

            let n = SCNNode(geometry: plane)
            n.constraints = [SCNBillboardConstraint()]
            n.position = SCNVector3(
                Float.random(in: -0.25...0.25, using: &rng),
                0.01,
                Float.random(in: -0.25...0.25, using: &rng)
            )
            node.addChildNode(n)
        }
        node.categoryBitMask = 0x00000002
        SceneryCommon.applyLOD(to: node, far: 70)
        return node
    }

    private static func flowerSpriteImage(diameter: Int, tint: UIColor) -> UIImage {
        let d = max(8, diameter)
        let size = CGSize(width: d, height: d)
        let r = min(size.width, size.height) * 0.5
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.opaque = false
        fmt.scale = 0
        let renderer = UIGraphicsImageRenderer(size: size, format: fmt)
        return renderer.image { ctx in
            let cg = ctx.cgContext
            let cs = CGColorSpaceCreateDeviceRGB()
            var tR: CGFloat = 1, tG: CGFloat = 1, tB: CGFloat = 1, tA: CGFloat = 1
            tint.getRed(&tR, green: &tG, blue: &tB, alpha: &tA)
            let inner = CGColor(colorSpace: cs, components: [tR, tG, tB, 1.0])!
            let outer = CGColor(colorSpace: cs, components: [tR, tG, tB, 0.0])!
            let grad = CGGradient(colorsSpace: cs, colors: [inner, outer] as CFArray, locations: [0.0, 1.0])!
            cg.drawRadialGradient(
                grad,
                startCenter: CGPoint(x: r, y: r), startRadius: 0,
                endCenter: CGPoint(x: r, y: r), endRadius: r,
                options: []
            )
            cg.setFillColor(UIColor(white: 1.0, alpha: 0.85).cgColor)
            let core = CGRect(x: size.width*0.5 - r*0.18, y: size.height*0.5 - r*0.18,
                              width: r*0.36, height: r*0.36)
            cg.fillEllipse(in: core)
        }
    }

    private static func randomFlowerTint(palette: [UIColor], rng: inout RandomAdaptor) -> UIColor {
        let bank: [UIColor] = [
            .systemYellow, .systemPink, .systemRed, .systemPurple, .systemOrange,
            palette.indices.contains(0) ? palette[0] : .systemTeal
        ]
        let base = bank[Int.random(in: 0..<bank.count, using: &rng)]
        return SceneryCommon.adjust(
            base,
            dH: CGFloat.random(in: -0.04...0.04, using: &rng),
            dS: CGFloat.random(in: -0.08...0.08, using: &rng),
            dB: CGFloat.random(in: -0.04...0.06, using: &rng)
        )
    }

    // MARK: - Shadow casting toggle (recursively turns on casting for a node and all children)

    @inline(__always)
    private static func enableShadowsRecursively(_ node: SCNNode) {
        node.castsShadow = true
        node.enumerateChildNodes { child, _ in child.castsShadow = true }
    }
}
