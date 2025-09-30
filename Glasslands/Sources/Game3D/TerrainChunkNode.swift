//
//  TerrainChunkNode.swift
//  Glasslands
//
//  Created by . . on 9/30/25.
//
//  Builds one SceneKit mesh chunk from the noise fields.
//  This version makes the mid-altitude band green (grass).
//

import SceneKit
import simd
import UIKit

struct TerrainChunkNode {
    static func makeNode(
        originChunk: IVec2,
        cfg: FirstPersonEngine.Config,
        noise: NoiseFields,
        recipe: BiomeRecipe
    ) -> SCNNode {
        let node = SCNNode()
        node.name = "chunk_\(originChunk.x)_\(originChunk.y)"

        let tilesX = cfg.tilesX
        let tilesZ = cfg.tilesZ
        let vertsX = tilesX + 1
        let vertsZ = tilesZ + 1

        let tileSize = cfg.tileSize
        let heightScale = cfg.heightScale

        // Tile origin (in tile coordinates)
        let originTileX = originChunk.x * tilesX
        let originTileZ = originChunk.y * tilesZ

        // Heights at vertices
        func idx(_ x: Int, _ z: Int) -> Int { z * vertsX + x }
        var heights = [Float](repeating: 0, count: vertsX * vertsZ)

        for z in 0..<vertsZ {
            for x in 0..<vertsX {
                let tx = Double(originTileX + x)
                let tz = Double(originTileZ + z)
                var h = noise.sampleHeight(tx, tz)
                let r = noise.riverMask(tx, tz)

                // Carve river channel slightly
                if r > 0.55 {
                    let t = min(1.0, (r - 0.55) / 0.45)
                    h *= (1.0 - 0.35 * t)
                }
                heights[idx(x, z)] = Float(h) * heightScale
            }
        }

        // Light blur over height grid to remove “shards”
        var blurred = heights
        for z in 0..<vertsZ {
            for x in 0..<vertsX {
                var sum = heights[idx(x, z)]
                var n: Float = 1
                if x > 0 { sum += heights[idx(x-1, z)]; n += 1 }
                if x+1 < vertsX { sum += heights[idx(x+1, z)]; n += 1 }
                if z > 0 { sum += heights[idx(x, z-1)]; n += 1 }
                if z+1 < vertsZ { sum += heights[idx(x, z+1)]; n += 1 }
                blurred[idx(x, z)] = sum / n
            }
        }
        heights = blurred

        // Vertex positions, normals, vertex colours
        var positions = [SCNVector3](repeating: .zero, count: vertsX * vertsZ)
        var normals   = [SCNVector3](repeating: .zero, count: vertsX * vertsZ)
        var colours   = [UIColor](repeating: .white, count: vertsX * vertsZ)

        let grad = HeightGradient()
        let minY = heights.min() ?? 0
        let maxY = heights.max() ?? 1
        let invRange: Float = (maxY > minY) ? 1.0 / (maxY - minY) : 1.0

        @inline(__always)
        func heightAt(_ x: Int, _ z: Int) -> Float {
            heights[max(0, min(vertsZ-1, z)) * vertsX + max(0, min(vertsX-1, x))]
        }

        for z in 0..<vertsZ {
            for x in 0..<vertsX {
                let wX = Float(originTileX + x) * tileSize
                let wZ = Float(originTileZ + z) * tileSize
                let y  = heights[idx(x, z)]

                positions[idx(x, z)] = SCNVector3(wX, y, wZ)

                // Central-difference normal via neighbour heights
                let hL = heightAt(x-1, z)
                let hR = heightAt(x+1, z)
                let hD = heightAt(x, z-1)
                let hU = heightAt(x, z+1)
                let tX = SIMD3(tileSize, hR - hL, 0)
                let tZ = SIMD3(0, hU - hD, tileSize)
                let n  = simd_normalize(simd_cross(tZ, tX)) // right-handed
                normals[idx(x, z)] = SCNVector3(n)

                // Vertex colour from height band + river mask
                let yNorm = (y - minY) * invRange
                let rMask = Float(noise.riverMask(Double(originTileX + x), Double(originTileZ + z)))
                let c = grad.color(yNorm: yNorm, riverMask: rMask)
                colours[idx(x, z)] = UIColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: CGFloat(c.w))
            }
        }

        // Indices (two triangles per tile)
        var indices = [Int32]()
        indices.reserveCapacity(tilesX * tilesZ * 6)
        for z in 0..<tilesZ {
            for x in 0..<tilesX {
                let i0 = Int32(idx(x,   z))
                let i1 = Int32(idx(x+1, z))
                let i2 = Int32(idx(x,   z+1))
                let i3 = Int32(idx(x+1, z+1))
                indices.append(contentsOf: [i0, i1, i2,   i1, i3, i2])
            }
        }

        let vSource = SCNGeometrySource(vertices: positions)
        let nSource = SCNGeometrySource(normals: normals)
        let cSource = geometrySourceForVertexColors(colours)

        let indexData = Data(bytes: indices, count: indices.count * MemoryLayout<Int32>.size)
        let element   = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: indices.count / 3,
            bytesPerIndex: MemoryLayout<Int32>.size
        )

        let geom = SCNGeometry(sources: [vSource, nSource, cSource], elements: [element])

        let mat = SCNMaterial()
        mat.lightingModel = .physicallyBased
        mat.diffuse.contents = UIColor.white // vertex colours carry the look
        mat.roughness.contents = 0.95
        mat.metalness.contents = 0.0
        mat.writesToDepthBuffer = true
        geom.materials = [mat]

        let meshNode = SCNNode(geometry: geom)
        meshNode.castsShadow = false
        return meshNode
    }

    // Minimal height palette → RGBA (0…1)
    private struct HeightGradient {
        // beach, deep water, GRASS, dry/sand, rock/snow
        // (changed the mid band to a natural grass green)
        let stops: [SIMD4<Float>] = [
            SIMD4(0.55, 0.80, 0.85, 1.0), // shallows / beach tint
            SIMD4(0.20, 0.45, 0.55, 1.0), // deep water
            SIMD4(0.36, 0.62, 0.34, 1.0), // grasslands  ← NEW (was off-white)
            SIMD4(0.93, 0.88, 0.70, 1.0), // dry/sand
            SIMD4(0.92, 0.92, 0.95, 1.0)  // rock/snow
        ]

        func color(yNorm: Float, riverMask r: Float) -> SIMD4<Float> {
            if r > 0.55, yNorm >= 0.28 { return stops[0] } // water channel tint
            if yNorm < 0.18 { return stops[1] }            // deep water
            if yNorm < 0.28 { return stops[0] }            // shallows / beach
            if yNorm < 0.34 { return stops[3] }            // sand/dry
            if yNorm < 0.62 { return stops[2] }            // grasslands
            return stops[4]                                 // high/rock/snow
        }
    }
}
