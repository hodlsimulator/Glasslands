//
//  TerrainMath.swift
//  Glasslands
//
//  Created by . . on 9/30/25.
//
//  One source of truth for terrain sampling so geometry, normals,
//  and the player ground-clamp all agree exactly.
//

import Foundation
import simd

enum TerrainMath {

    /// Normalised height (0…~1) in **tile coordinates** after river carving.
    static func heightN(tx: Double, tz: Double, noise: NoiseFields) -> Double {
        var h = noise.sampleHeight(tx, tz)
        let r = noise.riverMask(tx, tz)
        if r > 0.55 {
            let t = min(1.0, (r - 0.55) / 0.45)
            h *= (1.0 - 0.35 * t)
        }
        return h
    }

    /// World height (metres) from world XZ using config scale.
    static func heightWorld(x: Float, z: Float,
                            cfg: FirstPersonEngine.Config,
                            noise: NoiseFields) -> Float
    {
        let tx = Double(x) / Double(cfg.tileSize)
        let tz = Double(z) / Double(cfg.tileSize)
        return Float(heightN(tx: tx, tz: tz, noise: noise)) * cfg.heightScale
    }

    /// Smooth normal from central differences, using the same sampler.
    static func normal(tx: Double, tz: Double,
                       cfg: FirstPersonEngine.Config,
                       noise: NoiseFields) -> SIMD3<Float>
    {
        let hL = heightN(tx: tx - 1, tz: tz, noise: noise)
        let hR = heightN(tx: tx + 1, tz: tz, noise: noise)
        let hD = heightN(tx: tx, tz: tz - 1, noise: noise)
        let hU = heightN(tx: tx, tz: tz + 1, noise: noise)

        let tX = SIMD3(cfg.tileSize, Float(hR - hL) * cfg.heightScale, 0)
        let tZ = SIMD3(0, Float(hU - hD) * cfg.heightScale, cfg.tileSize)
        return simd_normalize(simd_cross(tZ, tX))
    }
}
