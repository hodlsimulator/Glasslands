//
//  NoiseFields.swift
//  Glasslands
//
//  Created by . . on 9/29/25.
//
//  Smoothed, domain‑warped procedural fields for height, moisture, and rivers.
//  Bigger world scales here make the terrain vastly broader and gentler.
//

import GameplayKit
import simd

final class NoiseFields {
    // Primary noises
    private let height: GKNoise
    private let moisture: GKNoise

    // River + warp fields
    private let riverBase: GKNoise
    private let warpX: GKNoise
    private let warpY: GKNoise

    // Amplitudes & scales
    private let ampH: Double
    private let ampM: Double
    private let scaleH: Double
    private let scaleM: Double
    private let scaleR: Double
    private let warpScale: Double
    private let warpAmp: Double
    private let seed32: Int32

    init(recipe: BiomeRecipe) {
        let baseSeed32: Int32 = Int32(truncatingIfNeeded: recipe.seed64)

        func makeSource(_ p: NoiseParams, seed salt: Int32 = 0) -> GKNoiseSource {
            let s = baseSeed32 &+ salt
            switch p.base.lowercased() {
            case "ridged":
                return GKRidgedNoiseSource(frequency: 1.0, octaveCount: max(1, p.octaves), lacunarity: 2.0, seed: s)
            case "billow":
                return GKBillowNoiseSource(frequency: 1.0, octaveCount: max(1, p.octaves), persistence: 0.5, lacunarity: 2.0, seed: s)
            default:
                return GKPerlinNoiseSource(frequency: 1.0, octaveCount: max(1, p.octaves), persistence: 0.55, lacunarity: 2.2, seed: s)
            }
        }

        // Build noises
        let heightNoise  = GKNoise(makeSource(recipe.height))
        let moistureNoise = GKNoise(makeSource(recipe.moisture, seed: 101))
        let riverNoise   = GKNoise(GKRidgedNoiseSource(frequency: 1.0, octaveCount: 5, lacunarity: 2.0, seed: baseSeed32 &+ 202))
        let warpXNoise   = GKNoise(GKPerlinNoiseSource(frequency: 1.0, octaveCount: 3, persistence: 0.5, lacunarity: 2.0, seed: baseSeed32 &+ 303))
        let warpYNoise   = GKNoise(GKPerlinNoiseSource(frequency: 1.0, octaveCount: 3, persistence: 0.5, lacunarity: 2.0, seed: baseSeed32 &+ 404))

        // Assign stored props
        self.height   = heightNoise
        self.moisture = moistureNoise
        self.riverBase = riverNoise
        self.warpX = warpXNoise
        self.warpY = warpYNoise

        self.ampH = recipe.height.amplitude
        self.ampM = recipe.moisture.amplitude

        // >>> Huge world: multiply recipe scales strongly <<<
        // Bigger scale = smoother, broader features. These values make hills kilometres apart.
        self.scaleH = max(20.0, recipe.height.scale * 12.0)
        self.scaleM = max(10.0, recipe.moisture.scale * 8.0)
        self.scaleR = max(12.0, scaleH * 0.85)

        // Softer domain warp so large forms stay gentle
        self.warpScale = 12.0
        self.warpAmp   = 0.15 / scaleH

        self.seed32 = baseSeed32
    }

    // MARK: - Sampling helpers
    @inline(__always) private func n01(_ v: Double) -> Double { (v * 0.5) + 0.5 }

    private func warp(_ x: Double, _ y: Double) -> (Double, Double) {
        let wx = Double(warpX.value(atPosition: vector_float2(Float(x/warpScale), Float(y/warpScale))))
        let wy = Double(warpY.value(atPosition: vector_float2(Float((x+1234)/warpScale), Float((y-987)/warpScale))))
        return (x + wx * warpAmp, y + wy * warpAmp)
    }

    /// Smoothed height sample in 0..ampH
    func sampleHeight(_ x: Double, _ y: Double) -> Double {
        let (u, v) = warp(x, y)

        // 4‑tap smoothing (Gaussian‑ish) before normalising.
        let v0 = Double(height.value(atPosition: vector_float2(Float(u/scaleH), Float(v/scaleH))))
        let v1 = Double(height.value(atPosition: vector_float2(Float((u+0.73)/scaleH), Float((v-0.42)/scaleH))))
        let v2 = Double(height.value(atPosition: vector_float2(Float((u-0.61)/scaleH), Float((v+0.37)/scaleH))))
        let v3 = Double(height.value(atPosition: vector_float2(Float((u+0.21)/scaleH), Float((v+0.58)/scaleH))))
        let hRaw = (v0 * 0.46 + v1 * 0.24 + v2 * 0.18 + v3 * 0.12)

        // Mild compression of peaks to flatten mountains.
        let h = pow(n01(hRaw), 1.35)
        return h * ampH
    }

    /// Moisture sample in 0..ampM
    func sampleMoisture(_ x: Double, _ y: Double) -> Double {
        let (u, v) = warp(x, y)
        let m = Double(moisture.value(atPosition: vector_float2(Float(u/scaleM), Float(v/scaleM))))
        return n01(m) * ampM
    }

    /// 0..1 river mask (1 = river core)
    func riverMask(_ x: Double, _ y: Double) -> Double {
        let (u, v) = warp(x, y)
        let r = Double(riverBase.value(atPosition: vector_float2(Float(u/scaleR), Float(v/scaleR))))
        let valley = 1.0 - n01(r)
        let t = max(0.0, valley - 0.40) / 0.60
        return pow(t, 2.2)
    }

    /// Approximate slope magnitude in height‑units per tile.
    func slope(_ x: Double, _ y: Double) -> Double {
        let s = 0.75
        let c = sampleHeight(x, y)
        let dx = sampleHeight(x + s, y) - c
        let dy = sampleHeight(x, y + s) - c
        return sqrt(dx*dx + dy*dy)
    }
}
