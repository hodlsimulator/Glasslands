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
import QuartzCore

struct SceneryPlacer3D {
    @MainActor
    static func place(inChunk ci: IVec2,
                      cfg: FirstPersonEngine.Config,
                      noise: NoiseFields,
                      recipe: BiomeRecipe) -> [SCNNode] {
        let originTile = SIMD2<Int>(ci.x * cfg.tilesX, ci.y * cfg.tilesZ)
        let seed = UInt64(bitPattern: Int64(ci.x) << 32 ^ Int64(ci.y))
        let rng = GKARC4RandomSource(seed: Data(bytes: [UInt8(seed & 0xff)], count: 1))
        let ra = GKRandomDistribution(randomSource: rng, lowestValue: 0, highestValue: 1_000_000)

        let sampler = NoiseSampler(noise: noise, recipe: recipe)

        var nodes: [SCNNode] = []
        nodes.reserveCapacity(128)

        let step = 4
        let ampH = Float(cfg.heightScale)
        let ampM = 1.0 as Float
        let tileSize = Float(cfg.tileSize)

        for tz in stride(from: 0, to: cfg.tilesZ, by: step) {
            for tx in stride(from: 0, to: cfg.tilesX, by: step) {
                let gx = originTile.x + tx
                let gz = originTile.y + tz

                let h = sampler.heightNorm(gx, gz, ampH)
                let m = sampler.moisture(gx, gz, ampM)
                let s = sampler.slope(gx, gz, ampH)
                let r = sampler.riverMask(gx, gz, ampM)

                if h < 0.30 { continue }

                // Slight jitter within the cell.
                let jx = Float.random(in: -0.35...0.35, using: &ra)
                let jz = Float.random(in: -0.35...0.35, using: &ra)

                let wx = (Float(gx) + jx) * tileSize
                let wz = (Float(gz) + jz) * tileSize
                let wy = TerrainMath.heightWorld(x: wx, z: wz, cfg: cfg, noise: noise, recipe: recipe)

                // Rocks on steeper / higher ground.
                if (s > 0.18 || h > 0.80), Double.random(in: 0...1, using: &ra) < 0.18 {
                    let group = SCNNode()
                    let count = Int.random(in: 1...3, using: &ra)
                    for i in 0..<count {
                        let off = SIMD2(Float.random(in: -0.8...0.8, using: &ra),
                                        Float.random(in: -0.8...0.8, using: &ra))
                        let x = wx + off.x
                        let z = wz + off.y
                        let y = TerrainMath.heightWorld(x: x, z: z, cfg: cfg, noise: noise, recipe: recipe)
                        let size = CGFloat.random(in: 0.25...0.55, using: &ra) * CGFloat(1 + 0.35 * Float(i))
                        let rock = RockBuilder.makeRockNode(size: size, palette: recipe.palette, rng: ra)
                        rock.position = SCNVector3(x, y, z)
                        group.addChildNode(rock)
                    }
                    group.setValue(NSNumber(value: 0.9), forKey: "hitRadius")
                    enableShadowsRecursively(group)
                    nodes.append(group)
                    continue
                }

                // Flowers on flatter, non-river ground.
                if s < 0.14, r < 0.55, m > 0.35,
                   Double.random(in: 0...1, using: &ra) < 0.14 {
                    let patch = makeFlowerPatchNode(palette: recipe.palette, rng: ra)
                    patch.position = SCNVector3(wx, wy, wz)
                    patch.setValue(NSNumber(value: 0.6), forKey: "hitRadius")
                    patch.castsShadow = false
                    nodes.append(patch)
                    continue
                }

                // Mushrooms in damp, shady-ish spots.
                if m > 0.55, h < 0.65, r < 0.55,
                   Double.random(in: 0...1, using: &ra) < 0.10 {
                    let mush = MushroomBuilder.makeMushroomNode(palette: recipe.palette, rng: ra)
                    mush.position = SCNVector3(wx, wy, wz)
                    mush.setValue(NSNumber(value: 0.5), forKey: "hitRadius")
                    enableShadowsRecursively(mush)
                    nodes.append(mush)
                    continue
                }

                // Reeds near rivers on low-ish heights.
                if r > 0.55, h < 0.55,
                   Double.random(in: 0...1, using: &ra) < 0.16 {
                    let reeds = ReedBuilder.makeReedClusterNode(palette: recipe.palette, rng: ra)
                    reeds.position = SCNVector3(wx, wy, wz)
                    reeds.setValue(NSNumber(value: 0.55), forKey: "hitRadius")
                    enableShadowsRecursively(reeds)
                    nodes.append(reeds)
                    continue
                }

                // Crystals in drier, higher areas.
                if m < 0.30, h > 0.70,
                   Double.random(in: 0...1, using: &ra) < 0.06 {
                    let crystal = CrystalBuilder.makeCrystalNode(palette: recipe.palette, rng: ra)
                    crystal.position = SCNVector3(wx, wy, wz)
                    crystal.setValue(NSNumber(value: 0.55), forKey: "hitRadius")
                    enableShadowsRecursively(crystal)
                    nodes.append(crystal)
                    continue
                }

                // Bushes as general filler.
                if s < 0.18, r < 0.55,
                   Double.random(in: 0...1, using: &ra) < 0.16 {
                    let bush = BushBuilder.makeBushNode(palette: recipe.palette, rng: ra)
                    bush.position = SCNVector3(wx, wy, wz)
                    bush.setValue(NSNumber(value: 0.75), forKey: "hitRadius")
                    enableShadowsRecursively(bush)
                    nodes.append(bush)
                    continue
                }
            }
        }

        return nodes
    }

    /// Async variant that time-slices work to prevent frame hitches while chunks stream in.
    /// Final visuals and placement logic are identical to `place(...)`.
    @MainActor
    static func placeAsync(inChunk ci: IVec2,
                           cfg: FirstPersonEngine.Config,
                           noise: NoiseFields,
                           recipe: BiomeRecipe,
                           frameBudgetSeconds: Double = 0.0035) async -> [SCNNode] {
        let originTile = SIMD2<Int>(ci.x * cfg.tilesX, ci.y * cfg.tilesZ)
        let seed = UInt64(bitPattern: Int64(ci.x) << 32 ^ Int64(ci.y))
        let rng = GKARC4RandomSource(seed: Data(bytes: [UInt8(seed & 0xff)], count: 1))
        let ra = GKRandomDistribution(randomSource: rng, lowestValue: 0, highestValue: 1_000_000)

        let sampler = NoiseSampler(noise: noise, recipe: recipe)

        var nodes: [SCNNode] = []
        nodes.reserveCapacity(128)

        var budget = FrameBudget(seconds: frameBudgetSeconds)

        let step = 4
        let ampH = Float(cfg.heightScale)
        let ampM = 1.0 as Float
        let tileSize = Float(cfg.tileSize)

        for tz in stride(from: 0, to: cfg.tilesZ, by: step) {
            for tx in stride(from: 0, to: cfg.tilesX, by: step) {
                if Task.isCancelled { return nodes }

                let gx = originTile.x + tx
                let gz = originTile.y + tz

                let h = sampler.heightNorm(gx, gz, ampH)
                let m = sampler.moisture(gx, gz, ampM)
                let s = sampler.slope(gx, gz, ampH)
                let r = sampler.riverMask(gx, gz, ampM)

                if h < 0.30 {
                    await budget.yieldIfNeeded()
                    continue
                }

                // Slight jitter within the cell.
                let jx = Float.random(in: -0.35...0.35, using: &ra)
                let jz = Float.random(in: -0.35...0.35, using: &ra)

                let wx = (Float(gx) + jx) * tileSize
                let wz = (Float(gz) + jz) * tileSize
                let wy = TerrainMath.heightWorld(x: wx, z: wz, cfg: cfg, noise: noise, recipe: recipe)

                // Rocks on steeper / higher ground.
                if (s > 0.18 || h > 0.80), Double.random(in: 0...1, using: &ra) < 0.18 {
                    let group = SCNNode()
                    let count = Int.random(in: 1...3, using: &ra)
                    for i in 0..<count {
                        if Task.isCancelled { return nodes }

                        let off = SIMD2(Float.random(in: -0.8...0.8, using: &ra),
                                        Float.random(in: -0.8...0.8, using: &ra))
                        let x = wx + off.x
                        let z = wz + off.y
                        let y = TerrainMath.heightWorld(x: x, z: z, cfg: cfg, noise: noise, recipe: recipe)
                        let size = CGFloat.random(in: 0.25...0.55, using: &ra) * CGFloat(1 + 0.35 * Float(i))
                        let rock = RockBuilder.makeRockNode(size: size, palette: recipe.palette, rng: ra)
                        rock.position = SCNVector3(x, y, z)
                        group.addChildNode(rock)
                        await budget.yieldIfNeeded()
                    }
                    group.setValue(NSNumber(value: 0.9), forKey: "hitRadius")
                    enableShadowsRecursively(group)
                    nodes.append(group)
                    await budget.yieldIfNeeded()
                    continue
                }

                // Flowers on flatter, non-river ground.
                if s < 0.14, r < 0.55, m > 0.35,
                   Double.random(in: 0...1, using: &ra) < 0.14 {
                    let patch = makeFlowerPatchNode(palette: recipe.palette, rng: ra)
                    patch.position = SCNVector3(wx, wy, wz)
                    patch.setValue(NSNumber(value: 0.6), forKey: "hitRadius")
                    patch.castsShadow = false
                    nodes.append(patch)
                    await budget.yieldIfNeeded()
                    continue
                }

                // Mushrooms in damp, shady-ish spots.
                if m > 0.55, h < 0.65, r < 0.55,
                   Double.random(in: 0...1, using: &ra) < 0.10 {
                    let mush = MushroomBuilder.makeMushroomNode(palette: recipe.palette, rng: ra)
                    mush.position = SCNVector3(wx, wy, wz)
                    mush.setValue(NSNumber(value: 0.5), forKey: "hitRadius")
                    enableShadowsRecursively(mush)
                    nodes.append(mush)
                    await budget.yieldIfNeeded()
                    continue
                }

                // Reeds near rivers on low-ish heights.
                if r > 0.55, h < 0.55,
                   Double.random(in: 0...1, using: &ra) < 0.16 {
                    let reeds = ReedBuilder.makeReedClusterNode(palette: recipe.palette, rng: ra)
                    reeds.position = SCNVector3(wx, wy, wz)
                    reeds.setValue(NSNumber(value: 0.55), forKey: "hitRadius")
                    enableShadowsRecursively(reeds)
                    nodes.append(reeds)
                    await budget.yieldIfNeeded()
                    continue
                }

                // Crystals in drier, higher areas.
                if m < 0.30, h > 0.70,
                   Double.random(in: 0...1, using: &ra) < 0.06 {
                    let crystal = CrystalBuilder.makeCrystalNode(palette: recipe.palette, rng: ra)
                    crystal.position = SCNVector3(wx, wy, wz)
                    crystal.setValue(NSNumber(value: 0.55), forKey: "hitRadius")
                    enableShadowsRecursively(crystal)
                    nodes.append(crystal)
                    await budget.yieldIfNeeded()
                    continue
                }

                // Bushes as general filler.
                if s < 0.18, r < 0.55,
                   Double.random(in: 0...1, using: &ra) < 0.16 {
                    let bush = BushBuilder.makeBushNode(palette: recipe.palette, rng: ra)
                    bush.position = SCNVector3(wx, wy, wz)
                    bush.setValue(NSNumber(value: 0.75), forKey: "hitRadius")
                    enableShadowsRecursively(bush)
                    nodes.append(bush)
                    await budget.yieldIfNeeded()
                    continue
                }

                await budget.yieldIfNeeded()
            }
        }

        return nodes
    }

    private struct FrameBudget {
        private let seconds: Double
        private var lastYield: Double

        init(seconds: Double) {
            self.seconds = max(0.0005, seconds)
            self.lastYield = CACurrentMediaTime()
        }

        mutating func yieldIfNeeded() async {
            let now = CACurrentMediaTime()
            if now - lastYield < seconds { return }
            lastYield = now
            await Task.yield()
        }
    }

    // MARK: - Flower sprites kept local

    @MainActor
    private static func makeFlowerPatchNode(palette: BiomePalette, rng: GKRandomDistribution) -> SCNNode {
        let patch = SCNNode()
        let count = Int.random(in: 4...8, using: &rng)
        for _ in 0..<count {
            let size = CGFloat.random(in: 0.10...0.18, using: &rng)
            let tint = randomFlowerTint(palette: palette, rng: rng)
            let img = flowerSpriteImage(tint: tint, diameter: Int(ceil(size * 128)))

            let plane = SCNPlane(width: size, height: size)
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = img
            m.diffuse.mipFilter = .linear
            m.diffuse.minificationFilter = .linear
            m.diffuse.magnificationFilter = .linear
            m.transparent.contents = img
            m.isDoubleSided = true
            m.blendMode = .alpha
            m.writesToDepthBuffer = false
            plane.materials = [m]

            let n = SCNNode(geometry: plane)
            n.constraints = [SCNBillboardConstraint()]
            n.position = SCNVector3(Float.random(in: -0.6...0.6, using: &rng), 0, Float.random(in: -0.6...0.6, using: &rng))
            patch.addChildNode(n)
        }
        return patch
    }

    @MainActor
    private static func flowerSpriteImage(tint: UIColor, diameter: Int) -> UIImage {
        let d = max(8, diameter)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: d, height: d))
        return renderer.image { ctx in
            let c = CGPoint(x: d/2, y: d/2)
            let r = CGFloat(d) / 2

            // Radial gradient: tint → transparent
            let colors = [tint.withAlphaComponent(0.85).cgColor,
                          tint.withAlphaComponent(0.0).cgColor] as CFArray
            let locs: [CGFloat] = [0.0, 1.0]
            if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: locs) {
                ctx.cgContext.drawRadialGradient(
                    grad,
                    startCenter: c, startRadius: 0,
                    endCenter: c, endRadius: r,
                    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
                )
            }

            // Small bright core
            ctx.cgContext.setFillColor(UIColor.white.withAlphaComponent(0.85).cgColor)
            let core = CGRect(x: d/2 - d/10, y: d/2 - d/10, width: d/5, height: d/5)
            ctx.cgContext.fillEllipse(in: core)
        }
    }

    @MainActor
    private static func randomFlowerTint(palette: BiomePalette, rng: GKRandomDistribution) -> UIColor {
        let base = palette.floraA
        let jitter = CGFloat.random(in: -0.10...0.10, using: &rng)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        base.getRed(&r, green: &g, blue: &b, alpha: &a)
        return UIColor(red: min(1, max(0, r + jitter)),
                       green: min(1, max(0, g + jitter)),
                       blue: min(1, max(0, b + jitter)),
                       alpha: 1)
    }

    // MARK: - Shadow casting toggle

    @MainActor
    private static func enableShadowsRecursively(_ node: SCNNode) {
        node.castsShadow = true
        for c in node.childNodes {
            enableShadowsRecursively(c)
        }
    }
}
