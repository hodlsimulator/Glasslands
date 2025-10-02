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

enum TerrainMeshBuilder {

    // Convenience that matches existing call sites.
    static func makeData(
        originChunkX: Int,
        originChunkY: Int,
        cfg: FirstPersonEngine.Config,
        noise: NoiseFields,
        recipe: BiomeRecipe
    ) -> TerrainChunkData {
        return makeData(
            originChunkX: originChunkX,
            originChunkY: originChunkY,
            tilesX: cfg.tilesX,
            tilesZ: cfg.tilesZ,
            tileSize: cfg.tileSize,
            heightScale: cfg.heightScale,
            noise: noise,
            recipe: recipe
        )
    }

    // Core builder (no dependency on Config so we can use it from a background actor)
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
        var colors    = [SIMD4<Float>](repeating: SIMD4<Float>(1,1,1,1), count: vertsX * vertsZ)
        var uvs       = [SIMD2<Float>](repeating: .zero, count: vertsX * vertsZ)

        let palette = HeightClassifier(recipe: recipe)

        for z in 0..<vertsZ {
            for x in 0..<vertsX {
                let tx = originTileX + x
                let tz = originTileZ + z

                // World position
                let wX = Float(tx) * tileSize
                let wZ = Float(tz) * tileSize
                let hN = Float(TerrainMath.heightN(tx: Double(tx), tz: Double(tz), noise: noise))
                let wY = hN * heightScale

                let idx = vi(x, z)
                positions[idx] = SIMD3(wX, wY, wZ)

                // Normal via central differences (same math as TerrainMath.normal, inlined)
                let hL = Float(TerrainMath.heightN(tx: Double(tx - 1), tz: Double(tz),     noise: noise))
                let hR = Float(TerrainMath.heightN(tx: Double(tx + 1), tz: Double(tz),     noise: noise))
                let hD = Float(TerrainMath.heightN(tx: Double(tx),     tz: Double(tz - 1), noise: noise))
                let hU = Float(TerrainMath.heightN(tx: Double(tx),     tz: Double(tz + 1), noise: noise))
                let tXv = SIMD3<Float>(tileSize, (hR - hL) * heightScale, 0)
                let tZv = SIMD3<Float>(0,        (hU - hD) * heightScale, tileSize)
                normals[idx] = simd_normalize(simd_cross(tZv, tXv))

                // Colour classification inputs
                let slope = Float(noise.slope(Double(tx), Double(tz)))
                let river = Float(noise.riverMask(Double(tx), Double(tz)))
                let moist = Float(noise.sampleMoisture(Double(tx), Double(tz)) / max(0.0001, recipe.moisture.amplitude))
                colors[idx] = palette.color(yNorm: hN, slope: slope, riverMask: river, moisture01: moist)

                let detailScale: Float = 1.0 / (tileSize * 2.0)
                uvs[idx] = SIMD2(wX * detailScale, wZ * detailScale)
            }
        }

        // Top surface indices
        var indices: [UInt32] = []
        indices.reserveCapacity(tilesX * tilesZ * 6)
        for z in 0..<tilesZ {
            for x in 0..<tilesX {
                let a = UInt32(vi(x,     z))
                let b = UInt32(vi(x + 1, z))
                let c = UInt32(vi(x,     z + 1))
                let d = UInt32(vi(x + 1, z + 1))
                indices.append(contentsOf: [a, b, c, b, d, c])
            }
        }

        // Skirts to seal edges
        let skirtDepth: Float = max(tileSize, heightScale * 1.2)

        var bottomIndex = [Int: Int]()
        @inline(__always)
        func dupBottom(_ x: Int, _ z: Int, normalHint: SIMD3<Float>) -> Int {
            let top = vi(x, z)
            if let id = bottomIndex[top] { return id }
            let p = positions[top]
            positions.append(SIMD3<Float>(p.x, p.y - skirtDepth, p.z))
            normals.append(normalHint)
            colors.append(colors[top])
            uvs.append(uvs[top])
            let id = positions.count - 1
            bottomIndex[top] = id
            return id
        }

        // North edge (z = 0) → outward -Z
        if vertsZ > 1 {
            let n = SIMD3<Float>(0, 0, -1)
            for x in 0..<tilesX {
                let tl = vi(x, 0), tr = vi(x + 1, 0)
                let bl = dupBottom(x, 0, normalHint: n), br = dupBottom(x + 1, 0, normalHint: n)
                indices.append(contentsOf: [UInt32(tl), UInt32(tr), UInt32(bl),
                                            UInt32(tr), UInt32(br), UInt32(bl)])
            }
        }
        // South edge (z = vertsZ - 1) → outward +Z
        if vertsZ > 1 {
            let n = SIMD3<Float>(0, 0, 1)
            let z = vertsZ - 1
            for x in 0..<tilesX {
                let tl = vi(x, z), tr = vi(x + 1, z)
                let bl = dupBottom(x, z, normalHint: n), br = dupBottom(x + 1, z, normalHint: n)
                indices.append(contentsOf: [UInt32(tr), UInt32(tl), UInt32(br),
                                            UInt32(tl), UInt32(bl), UInt32(br)])
            }
        }
        // West edge (x = 0) → outward -X
        if vertsX > 1 {
            let n = SIMD3<Float>(-1, 0, 0)
            for z in 0..<tilesZ {
                let tt = vi(0, z), tb = vi(0, z + 1)
                let bt = dupBottom(0, z, normalHint: n), bb = dupBottom(0, z + 1, normalHint: n)
                indices.append(contentsOf: [UInt32(tt), UInt32(bt), UInt32(tb),
                                            UInt32(tb), UInt32(bt), UInt32(bb)])
            }
        }
        // East edge (x = vertsX - 1) → outward +X
        if vertsX > 1 {
            let n = SIMD3<Float>(1, 0, 0)
            let x = vertsX - 1
            for z in 0..<tilesZ {
                let tt = vi(x, z), tb = vi(x, z + 1)
                let bt = dupBottom(x, z, normalHint: n), bb = dupBottom(x, z + 1, normalHint: n)
                indices.append(contentsOf: [UInt32(tb), UInt32(bt), UInt32(tt),
                                            UInt32(tb), UInt32(bb), UInt32(bt)])
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

    private struct HeightClassifier {
        let deep  = SIMD4<Float>(0.18, 0.42, 0.58, 1.0)
        let shore = SIMD4<Float>(0.55, 0.80, 0.88, 1.0)
        let grass = SIMD4<Float>(0.32, 0.62, 0.34, 1.0)
        let sand  = SIMD4<Float>(0.92, 0.87, 0.68, 1.0)
        let rock  = SIMD4<Float>(0.90, 0.92, 0.95, 1.0)

        let deepCut: Float = 0.22
        let shoreCut: Float = 0.30
        let sandCut:  Float = 0.33
        let snowCut:  Float = 0.88

        let recipe: BiomeRecipe

        @inline(__always)
        private func mix(_ a: SIMD4<Float>, _ b: SIMD4<Float>, _ t: Float) -> SIMD4<Float> { a + (b - a) * t }

        func color(yNorm y: Float, slope s: Float, riverMask r: Float, moisture01 m: Float) -> SIMD4<Float> {
            if y < deepCut { return deep }
            if y < shoreCut || r > 0.60 { return shore }
            if s > 0.55 || y > snowCut { return rock }
            if y < sandCut { return sand }
            let t = max(0, min(1, m * 0.65 + r * 0.20))
            return mix(grass, SIMD4<Float>(0.40, 0.75, 0.38, 1.0), t)
        }
    }
}
