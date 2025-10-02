//
//  TerrainMeshBuilder.swift
//  Glasslands
//
//  Created by . . on 10/2/25.
//
//  Pure, Sendable terrain mesh data builder (no SceneKit/UIKit).
//  Returns TerrainChunkData and includes edge “skirts” to seal gaps.
//

import simd
import GameplayKit

// Synchronous terrain mesh builder for the *centre* chunk at launch.
// Background streaming still uses ChunkMeshBuilder (actor) in ChunkStreamer3D.
enum TerrainMeshBuilder {
    static func makeData(
        originChunkX: Int,
        originChunkY: Int,
        tilesX: Int,
        tilesZ: Int,
        tileSize: Float,
        heightScale: Float,
        noise: NoiseFields,
        recipe: BiomeRecipe
    ) -> TerrainChunkData {

        let vertsX = tilesX + 1
        let vertsZ = tilesZ + 1

        let originTileX = originChunkX * tilesX
        let originTileZ = originChunkY * tilesZ

        @inline(__always) func vi(_ x: Int, _ z: Int) -> Int { z * vertsX + x }

        var positions = [SIMD3<Float>](repeating: .zero, count: vertsX * vertsZ)
        var normals   = [SIMD3<Float>](repeating: .zero, count: vertsX * vertsZ)
        var colors    = [SIMD4<Float>](repeating: SIMD4(1,1,1,1), count: vertsX * vertsZ)
        var uvs       = [SIMD2<Float>](repeating: .zero, count: vertsX * vertsZ)

        let sampler = NoiseSamplerSync(recipe: recipe)
        let palette = HeightClassifier(recipe: recipe)

        for z in 0..<vertsZ {
            for x in 0..<vertsX {
                let tx = originTileX + x
                let tz = originTileZ + z

                let wX = Float(tx) * tileSize
                let wZ = Float(tz) * tileSize

                let hN = Float(sampler.heightNorm(Double(tx), Double(tz), ampH: recipe.height.amplitude))
                let y  = hN * heightScale

                let idx = vi(x, z)
                positions[idx] = SIMD3(wX, y, wZ)

                // Central-difference normal in *global* tile space for seamless borders
                let hL = sampler.sampleHeight(Double(tx - 1), Double(tz))
                let hR = sampler.sampleHeight(Double(tx + 1), Double(tz))
                let hD = sampler.sampleHeight(Double(tx), Double(tz - 1))
                let hU = sampler.sampleHeight(Double(tx), Double(tz + 1))
                let tXv = SIMD3(tileSize, Float(hR - hL) * heightScale, 0)
                let tZv = SIMD3(0, Float(hU - hD) * heightScale, tileSize)
                normals[idx] = simd_normalize(simd_cross(tZv, tXv))

                let slope  = Float(sampler.slope(Double(tx), Double(tz)))
                let river  = Float(sampler.riverMask(Double(tx), Double(tz)))
                let moist  = Float(sampler.sampleMoisture(Double(tx), Double(tz)) / max(0.0001, recipe.moisture.amplitude))
                colors[idx] = palette.color(yNorm: hN, slope: slope, riverMask: river, moisture01: moist)

                // World-space UVs so detail texture continues across chunks
                let detailScale: Float = 1.0 / (tileSize * 8.0)
                uvs[idx] = SIMD2(wX * detailScale, wZ * detailScale)
            }
        }

        // Top surface indices
        var indices: [UInt32] = []
        indices.reserveCapacity(tilesX * tilesZ * 6)
        for z in 0..<tilesZ {
            for x in 0..<tilesX {
                let i0 = UInt32(vi(x,     z))
                let i1 = UInt32(vi(x + 1, z))
                let i2 = UInt32(vi(x,     z + 1))
                let i3 = UInt32(vi(x + 1, z + 1))
                indices.append(contentsOf: [i0, i2, i1,  i1, i2, i3])
            }
        }

        // Edge skirts to hide sub-pixel cracks between chunks
        let skirtDepth: Float = 0.20
        var bottomIndex: [Int: Int] = [:]

        @inline(__always)
        func bottomOf(_ x: Int, _ z: Int, normalHint n: SIMD3<Float>) -> Int {
            let top = vi(x, z)
            if let id = bottomIndex[top] { return id }
            let p = positions[top]
            positions.append(SIMD3(p.x, p.y - skirtDepth, p.z))
            normals.append(n)
            colors.append(colors[top])
            uvs.append(uvs[top])
            let id = positions.count - 1
            bottomIndex[top] = id
            return id
        }

        // North
        if vertsZ > 1 {
            let n = SIMD3<Float>(0, 0, -1)
            for x in 0..<vertsX {
                let topA = vi(x, 0)
                let topB = vi(max(0, x-1), 0)
                let botA = bottomOf(x, 0, normalHint: n)
                let botB = bottomOf(max(0, x-1), 0, normalHint: n)
                indices.append(contentsOf: [UInt32(topB), UInt32(botB), UInt32(topA),
                                            UInt32(topA), UInt32(botB), UInt32(botA)])
            }
        }
        // South
        if vertsZ > 1 {
            let n = SIMD3<Float>(0, 0, 1)
            let z = vertsZ - 1
            for x in 0..<vertsX {
                let topA = vi(x, z)
                let topB = vi(max(0, x-1), z)
                let botA = bottomOf(x, z, normalHint: n)
                let botB = bottomOf(max(0, x-1), z, normalHint: n)
                indices.append(contentsOf: [UInt32(topA), UInt32(botB), UInt32(topB),
                                            UInt32(topA), UInt32(botA), UInt32(botB)])
            }
        }
        // West
        if vertsX > 1 {
            let n = SIMD3<Float>(-1, 0, 0)
            for z in 0..<vertsZ {
                let topA = vi(0, z)
                let topB = vi(0, max(0, z-1))
                let botA = bottomOf(0, z, normalHint: n)
                let botB = bottomOf(0, max(0, z-1), normalHint: n)
                indices.append(contentsOf: [UInt32(topB), UInt32(botB), UInt32(topA),
                                            UInt32(topA), UInt32(botB), UInt32(botA)])
            }
        }
        // East
        if vertsX > 1 {
            let n = SIMD3<Float>(1, 0, 0)
            let x = vertsX - 1
            for z in 0..<vertsZ {
                let topA = vi(x, z)
                let topB = vi(x, max(0, z-1))
                let botA = bottomOf(x, z, normalHint: n)
                let botB = bottomOf(x, max(0, z-1), normalHint: n)
                indices.append(contentsOf: [UInt32(topA), UInt32(botB), UInt32(topB),
                                            UInt32(topA), UInt32(botA), UInt32(botB)])
            }
        }

        return TerrainChunkData(
            originChunkX: originChunkX,
            originChunkY: originChunkY,
            tilesX: tilesX,
            tilesZ: tilesZ,
            tileSize: tileSize,
            positions: positions,
            normals: normals,
            colors: colors,
            uvs: uvs,
            indices: indices
        )
    }
}

// MARK: - Colour classifier (same thresholds used by the actor builder)
private struct HeightClassifier {
    let deep  = SIMD4<Float>(0.18, 0.42, 0.58, 1.0)
    let shore = SIMD4<Float>(0.55, 0.80, 0.88, 1.0)
    let grass = SIMD4<Float>(0.32, 0.62, 0.34, 1.0)
    let sand  = SIMD4<Float>(0.92, 0.87, 0.68, 1.0)
    let rock  = SIMD4<Float>(0.90, 0.92, 0.95, 1.0)

    let deepCut:  Float = 0.22
    let shoreCut: Float = 0.30
    let sandCut:  Float = 0.33
    let snowCut:  Float = 0.88

    init(recipe: BiomeRecipe) { _ = recipe }

    @inline(__always) private func mix(_ a: SIMD4<Float>, _ b: SIMD4<Float>, _ t: Float) -> SIMD4<Float> {
        a + (b - a) * t
    }

    func color(yNorm y: Float, slope s: Float, riverMask r: Float, moisture01 m: Float) -> SIMD4<Float> {
        if y < deepCut { return deep }
        if y < shoreCut || r > 0.60 { return shore }
        if s > 0.55 || y > snowCut { return rock }
        if y < sandCut { return sand }
        let t = max(0, min(1, m * 0.65 + r * 0.20))
        return mix(grass, SIMD4<Float>(0.40, 0.75, 0.38, 1.0), t)
    }
}

// MARK: - GKNoise sampler (synchronous)
private final class NoiseSamplerSync {
    private let height: GKNoise
    private let moisture: GKNoise
    private let riverBase: GKNoise
    private let warpX: GKNoise
    private let warpY: GKNoise

    private let ampH: Double
    private let ampM: Double
    private let scaleH: Double
    private let scaleM: Double
    private let scaleR: Double
    private let warpScale: Double
    private let warpAmp: Double

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

        self.height = GKNoise(makeSource(recipe.height))
        self.moisture = GKNoise(makeSource(recipe.moisture, seed: 101))
        self.riverBase = GKNoise(GKRidgedNoiseSource(frequency: 1.0, octaveCount: 5, lacunarity: 2.0, seed: baseSeed32 &+ 202))
        self.warpX = GKNoise(GKPerlinNoiseSource(frequency: 1.0, octaveCount: 3, persistence: 0.5, lacunarity: 2.0, seed: baseSeed32 &+ 303))
        self.warpY = GKNoise(GKPerlinNoiseSource(frequency: 1.0, octaveCount: 3, persistence: 0.5, lacunarity: 2.0, seed: baseSeed32 &+ 404))

        self.ampH = recipe.height.amplitude
        self.ampM = recipe.moisture.amplitude

        self.scaleH = max(20.0, recipe.height.scale * 12.0)
        self.scaleM = max(10.0, recipe.moisture.scale * 8.0)
        self.scaleR = max(12.0, scaleH * 0.85)

        self.warpScale = 12.0
        self.warpAmp = 0.15 / scaleH
    }

    @inline(__always) private func n01(_ v: Double) -> Double { (v * 0.5) + 0.5 }

    private func warp(_ x: Double, _ y: Double) -> (Double, Double) {
        let wx = Double(warpX.value(atPosition: vector_float2(Float(x/warpScale), Float(y/warpScale))))
        let wy = Double(warpY.value(atPosition: vector_float2(Float((x+1234)/warpScale), Float((y-987)/warpScale))))
        return (x + wx * warpAmp, y + wy * warpAmp)
    }

    func sampleHeight(_ x: Double, _ y: Double) -> Double {
        let (u, v) = warp(x, y)
        let v0 = Double(height.value(atPosition: vector_float2(Float(u/scaleH), Float(v/scaleH))))
        let v1 = Double(height.value(atPosition: vector_float2(Float((u+0.73)/scaleH), Float((v-0.42)/scaleH))))
        let v2 = Double(height.value(atPosition: vector_float2(Float((u-0.61)/scaleH), Float((v+0.37)/scaleH))))
        let v3 = Double(height.value(atPosition: vector_float2(Float((u+0.21)/scaleH), Float((v+0.58)/scaleH))))
        let hRaw = (v0 * 0.46 + v1 * 0.24 + v2 * 0.18 + v3 * 0.12)
        let h = pow(n01(hRaw), 1.35)
        return h * ampH
    }

    func sampleMoisture(_ x: Double, _ y: Double) -> Double {
        let (u, v) = warp(x, y)
        let m = Double(moisture.value(atPosition: vector_float2(Float(u/scaleM), Float(v/scaleM))))
        return n01(m) * ampM
    }

    func riverMask(_ x: Double, _ y: Double) -> Double {
        let (u, v) = warp(x, y)
        let r = Double(riverBase.value(atPosition: vector_float2(Float(u/scaleR), Float(v/scaleR))))
        let valley = 1.0 - n01(r)
        let t = max(0.0, valley - 0.40) / 0.60
        return pow(t, 2.2)
    }

    func slope(_ x: Double, _ y: Double) -> Double {
        let s = 0.75
        let c = sampleHeight(x, y)
        let dx = sampleHeight(x + s, y) - c
        let dy = sampleHeight(x, y + s) - c
        return sqrt(dx*dx + dy*dy)
    }

    func heightNorm(_ x: Double, _ y: Double, ampH: Double) -> Double {
        var h = sampleHeight(x, y)
        let r = riverMask(x, y)
        if r > 0.55 {
            let t = min(1.0, (r - 0.55) / 0.45)
            h *= (1.0 - 0.35 * t)
        }
        return h / max(0.0001, ampH)
    }
}
