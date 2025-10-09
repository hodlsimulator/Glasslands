//
//  VegetationPlacer3D.swift
//  Glasslands
//
//  Created by . . on 9/30/25.
//
//  Places *3D* trees using the TreeLibrary3D prototypes (no sprites).
//  Reduced density, cheap shadows, shared geometry, and LOD cull.
//

import SceneKit
import GameplayKit
import UIKit
import simd

struct VegetationPlacer3D {

    @MainActor
    static func place(
        inChunk ci: IVec2,
        cfg: FirstPersonEngine.Config,
        noise: NoiseFields,
        recipe: BiomeRecipe
    ) -> [SCNNode] {
        let originTile = IVec2(ci.x * cfg.tilesX, ci.y * cfg.tilesZ)

        // Deterministic per-chunk seed mixed with the biome seed
        let ux = UInt64(bitPattern: Int64(ci.x))
        let uy = UInt64(bitPattern: Int64(ci.y))
        let seed = recipe.seed64 ^ (ux &* 0x9E37_79B9_7F4A_7C15) ^ (uy &* 0xBF58_476D_1CE4_E5B9)

        let src = GKMersenneTwisterRandomSource(seed: seed)
        var rng = RandomAdaptor(src)

        var nodes: [SCNNode] = []
        nodes.reserveCapacity(64)

        let palette = AppColours.uiColors(from: recipe.paletteHex)
        TreeLibrary3D.ensureWarm(palette: palette)

        // Primary sampling stride (tiles). Higher = fewer candidates.
        let step = 6

        // Pass 1 — individual trees
        for tz in stride(from: 0, to: cfg.tilesZ, by: step) {
            for tx in stride(from: 0, to: cfg.tilesX, by: step) {

                let tileX = originTile.x + tx
                let tileZ = originTile.y + tz

                // Normalised fields
                let h = noise.sampleHeight(Double(tileX), Double(tileZ)) / max(0.0001, recipe.height.amplitude)
                let m = noise.sampleMoisture(Double(tileX), Double(tileZ)) / max(0.0001, recipe.moisture.amplitude)
                let slope = noise.slope(Double(tileX), Double(tileZ))
                let r = noise.riverMask(Double(tileX), Double(tileZ))

                // Hard gates: avoid beaches/water, steep slopes, and river beds
                if h < 0.34 { continue }
                if slope > 0.16 { continue }
                if r > 0.50 { continue }

                // Forest bias in mid-moist, mid-height regions (lowered base chance)
                let isForest = (h < 0.66) && (m > 0.52) && (slope < 0.12)
                let baseChance: Double = isForest ? 0.22 : 0.08
                if Double.random(in: 0...1, using: &rng) > baseChance { continue }

                // Jitter within the sampling cell
                let jx = Float.random(in: -0.45...0.45, using: &rng)
                let jz = Float.random(in: -0.45...0.45, using: &rng)

                let wx = (Float(tileX) + jx) * cfg.tileSize
                let wz = (Float(tileZ) + jz) * cfg.tileSize
                let wy = TerrainMath.heightWorld(x: wx, z: wz, cfg: cfg, noise: noise)

                let (tree, hitR) = TreeLibrary3D.instance(using: &rng)
                tree.position = SCNVector3(wx, wy, wz)
                tree.setValue(CGFloat(hitR), forKey: "hitRadius")

                nodes.append(tree)
            }
        }

        // Pass 2 — small groves for variety (also reduced)
        let groveAttempts = 1
        for _ in 0..<groveAttempts {
            let cx = originTile.x + Int.random(in: 0..<cfg.tilesX, using: &rng)
            let cz = originTile.y + Int.random(in: 0..<cfg.tilesZ, using: &rng)

            let h = noise.sampleHeight(Double(cx), Double(cz)) / max(0.0001, recipe.height.amplitude)
            let m = noise.sampleMoisture(Double(cx), Double(cz)) / max(0.0001, recipe.moisture.amplitude)
            let slope = noise.slope(Double(cx), Double(cz))
            let r = noise.riverMask(Double(cx), Double(cz))

            guard h >= 0.42, h <= 0.78, m >= 0.48, m <= 0.80, slope < 0.10, r < 0.42 else { continue }
            guard Double.random(in: 0...1, using: &rng) < 0.35 else { continue }

            let count = Int.random(in: 3...4, using: &rng)
            let baseWX = Float(cx) * cfg.tileSize
            let baseWZ = Float(cz) * cfg.tileSize

            for _ in 0..<count {
                let offR = Float.random(in: 0.0...3.5, using: &rng) * cfg.tileSize
                let offA = Float.random(in: 0...(2 * .pi), using: &rng)
                let wx = baseWX + cos(offA) * offR
                let wz = baseWZ + sin(offA) * offR
                let wy = TerrainMath.heightWorld(x: wx, z: wz, cfg: cfg, noise: noise)

                let (tree, hitR) = TreeLibrary3D.instance(using: &rng)
                tree.position = SCNVector3(wx, wy, wz)
                tree.setValue(CGFloat(hitR), forKey: "hitRadius")

                nodes.append(tree)
            }
        }

        return nodes
    }
}
