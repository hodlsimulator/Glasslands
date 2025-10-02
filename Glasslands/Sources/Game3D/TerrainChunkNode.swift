//
//  TerrainChunkNode.swift
//  Glasslands
//
//  Created by . . on 9/30/25.
//
//  Builds terrain either as pure mesh data (Sendable) or as an SCNNode (main actor).
//

@preconcurrency import SceneKit
import simd
import UIKit

// Pure value mesh payload so we can build off the main thread.
struct TerrainChunkData: Sendable {
    let originChunkX: Int
    let originChunkY: Int
    let tilesX: Int
    let tilesZ: Int
    let tileSize: Float

    let positions: [SIMD3<Float>]
    let normals:   [SIMD3<Float>]
    let colors:    [SIMD4<Float>]  // RGBA 0…1
    let uvs:       [SIMD2<Float>]
    let indices:   [UInt32]
}

struct TerrainChunkNode {

    // MARK: - Public entry points

    static func makeNode(
        originChunk: IVec2,
        cfg: FirstPersonEngine.Config,
        noise: NoiseFields,
        recipe: BiomeRecipe
    ) -> SCNNode {
        let data = makeData(
            originChunkX: originChunk.x,
            originChunkY: originChunk.y,
            cfg: cfg,
            noise: noise,
            recipe: recipe
        )
        return node(from: data)
    }

    static func makeData(
        originChunkX: Int,
        originChunkY: Int,
        cfg: FirstPersonEngine.Config,
        noise: NoiseFields,
        recipe: BiomeRecipe
    ) -> TerrainChunkData {
        let tilesX = cfg.tilesX
        let tilesZ = cfg.tilesZ
        let vertsX = tilesX + 1
        let vertsZ = tilesZ + 1
        let tileSize = cfg.tileSize

        let originTileX = originChunkX * tilesX
        let originTileZ = originChunkY * tilesZ

        @inline(__always)
        func vi(_ x: Int, _ z: Int) -> Int { z * vertsX + x }

        var positions = [SIMD3<Float>](repeating: .zero, count: vertsX * vertsZ)
        var normals   = [SIMD3<Float>](repeating: .zero, count: vertsX * vertsZ)
        var colors    = [SIMD4<Float>](repeating: SIMD4<Float>(1,1,1,1), count: vertsX * vertsZ)
        var uvs       = [SIMD2<Float>](repeating: .zero, count: vertsX * vertsZ)

        let palette = HeightClassifier(recipe: recipe)

        for z in 0..<vertsZ {
            for x in 0..<vertsX {
                let tx = originTileX + x
                let tz = originTileZ + z
                let wX = Float(tx) * tileSize
                let wZ = Float(tz) * tileSize
                let wY = TerrainMath.heightWorld(x: wX, z: wZ, cfg: cfg, noise: noise)

                positions[vi(x, z)] = SIMD3(wX, wY, wZ)

                let n = TerrainMath.normal(tx: Double(tx), tz: Double(tz), cfg: cfg, noise: noise)
                normals[vi(x, z)] = n

                let hN   = Float(NoiseFieldsHeightN(tx: Double(tx), tz: Double(tz), noise: noise, recipe: recipe))
                let slope = Float(noise.slope(Double(tx), Double(tz)))
                let river = Float(noise.riverMask(Double(tx), Double(tz)))
                let moist = Float(noise.sampleMoisture(Double(tx), Double(tz))) / Float(max(0.0001, recipe.moisture.amplitude))
                colors[vi(x, z)] = palette.color(yNorm: hN, slope: slope, riverMask: river, moisture01: moist)

                // Simple world-space UVs for small detail texture
                let detailScale: Float = 1.0 / (tileSize * 2.0)
                uvs[vi(x, z)] = SIMD2(wX * detailScale, wZ * detailScale)
            }
        }

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

    @MainActor
    static func node(from data: TerrainChunkData) -> SCNNode {
        let node = SCNNode()
        node.name = "chunk_\(data.originChunkX)_\(data.originChunkY)"

        // Geometry sources
        let posData = data.positions.withUnsafeBytes { Data($0) }
        let nrmData = data.normals.withUnsafeBytes { Data($0) }
        let colData = data.colors.withUnsafeBytes { Data($0) }
        let uvData  = data.uvs.withUnsafeBytes { Data($0) }
        let idxData = data.indices.withUnsafeBytes { Data($0) }

        let posSrc = SCNGeometrySource(
            data: posData,
            semantic: .vertex,
            vectorCount: data.positions.count,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SIMD3<Float>>.stride
        )
        let nrmSrc = SCNGeometrySource(
            data: nrmData,
            semantic: .normal,
            vectorCount: data.normals.count,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SIMD3<Float>>.stride
        )
        let colSrc = SCNGeometrySource(
            data: colData,
            semantic: .color,
            vectorCount: data.colors.count,
            usesFloatComponents: true,
            componentsPerVector: 4,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SIMD4<Float>>.stride
        )
        let uvSrc  = SCNGeometrySource(
            data: uvData,
            semantic: .texcoord,
            vectorCount: data.uvs.count,
            usesFloatComponents: true,
            componentsPerVector: 2,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SIMD2<Float>>.stride
        )

        let element = SCNGeometryElement(
            data: idxData,
            primitiveType: .triangles,
            primitiveCount: data.indices.count / 3,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )

        let geom = SCNGeometry(sources: [posSrc, nrmSrc, colSrc, uvSrc], elements: [element])

        let mat = SCNMaterial()
        mat.lightingModel = .lambert
        mat.isDoubleSided = false
        // Tiny ground detail (procedural), repeated via UVs
        mat.diffuse.contents = SceneKitHelpers.groundDetailTexture(size: 128)
        mat.diffuse.wrapS = .repeat
        mat.diffuse.wrapT = .repeat
        mat.roughness.contents = 1.0
        geom.materials = [mat]

        node.geometry = geom
        node.castsShadow = false
        return node
    }

    // MARK: - Helpers

    // Height used for colouring (normalised 0…1 with river carve)
    @inline(__always)
    private static func NoiseFieldsHeightN(tx: Double, tz: Double, noise: NoiseFields, recipe: BiomeRecipe) -> Double {
        var h = noise.sampleHeight(tx, tz)
        let r = noise.riverMask(tx, tz)
        if r > 0.55 {
            let t = min(1.0, (r - 0.55) / 0.45)
            h *= (1.0 - 0.35 * t)
        }
        return h / max(0.0001, recipe.height.amplitude)
    }

    private struct HeightClassifier {
        // Colours (RGBA)
        let deep  = SIMD4<Float>(0.18, 0.42, 0.58, 1.0)
        let shore = SIMD4<Float>(0.55, 0.80, 0.88, 1.0)
        let grass = SIMD4<Float>(0.32, 0.62, 0.34, 1.0)
        let sand  = SIMD4<Float>(0.92, 0.87, 0.68, 1.0)
        let rock  = SIMD4<Float>(0.90, 0.92, 0.95, 1.0)

        // Thresholds
        let deepCut: Float = 0.22
        let shoreCut: Float = 0.30
        let sandCut:  Float = 0.33
        let snowCut:  Float = 0.88

        let recipe: BiomeRecipe

        func color(yNorm y: Float, slope s: Float, riverMask r: Float, moisture01 m: Float) -> SIMD4<Float> {
            if y < deepCut { return deep }
            if y < shoreCut || r > 0.60 { return shore }
            if s > 0.55 || y > snowCut { return rock }
            if y < sandCut { return sand }
            // Blend greener in moist or near riverbeds
            let t = max(0, min(1, m * 0.65 + r * 0.20))
            return mix(grass, SIMD4<Float>(0.40, 0.75, 0.38, 1.0), t)
        }

        @inline(__always)
        private func mix(_ a: SIMD4<Float>, _ b: SIMD4<Float>, _ t: Float) -> SIMD4<Float> { a + (b - a) * t }
    }
}
