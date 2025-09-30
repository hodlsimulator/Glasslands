//
//  TerrainChunkNode.swift
//  Glasslands
//
//  Created by . . on 9/30/25.
//
//  Builds one SceneKit mesh chunk from the noise fields.
//  Changes: add one light blur pass over the vertex-height grid.
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
        var heights = [Float](repeating: 0, count: vertsX * vertsZ)
        @inline(__always) func idx(_ x: Int, _ z: Int) -> Int { z * vertsX + x }

        for z in 0..<vertsZ {
            for x in 0..<vertsX {
                let tx = Double(originTileX + x)
                let tz = Double(originTileZ + z)

                var h = noise.sampleHeight(tx, tz)

                // Soften river channels a touch (flatter near water)
                let r = noise.riverMask(tx, tz) // 0..1
                if r > 0.55 {
                    h = h * (1.0 - 0.35 * min(1.0, (r - 0.55) / 0.45))
                }

                heights[idx(x, z)] = Float(h) * heightScale
            }
        }

        // --- Light blur over height grid to remove “shards” ---
        var blurred = heights
        for z in 0..<vertsZ {
            for x in 0..<vertsX {
                var sum = heights[idx(x, z)]
                var n: Float = 1
                if x > 0         { sum += heights[idx(x-1, z)]; n += 1 }
                if x+1 < vertsX  { sum += heights[idx(x+1, z)]; n += 1 }
                if z > 0         { sum += heights[idx(x, z-1)]; n += 1 }
                if z+1 < vertsZ  { sum += heights[idx(x, z+1)]; n += 1 }
                blurred[idx(x, z)] = sum / n
            }
        }
        heights = blurred
        // ------------------------------------------------------

        // Vertex positions, normals, colours
        var vertices = [SCNVector3](repeating: SCNVector3(0,0,0), count: vertsX * vertsZ)
        var normals  = [SCNVector3](repeating: SCNVector3(0,0,0), count: vertsX * vertsZ)
        var colors   = [SIMD4<Float>](repeating: SIMD4(1,1,1,1), count: vertsX * vertsZ)

        // Build positions + colours (by height bands + rivers)
        let grad = HeightGradient()

        let minY = heights.min() ?? 0
        let maxY = heights.max() ?? 1
        let invRange: Float = (maxY > minY) ? 1.0 / (maxY - minY) : 1.0

        for z in 0..<vertsZ {
            for x in 0..<vertsX {
                let y = heights[idx(x, z)]
                let wx = Float(originTileX + x) * tileSize
                let wz = Float(originTileZ + z) * tileSize
                vertices[idx(x, z)] = SCNVector3(wx, y, wz)

                let yn = (y - minY) * invRange
                let r  = Float(noise.riverMask(Double(originTileX + x), Double(originTileZ + z)))
                colors[idx(x, z)] = grad.color(yNorm: yn, riverMask: r)
            }
        }

        // Normals (finite difference)
        @inline(__always) func hclamped(_ x: Int, _ z: Int) -> Float {
            heights[max(0, min(vertsZ-1, z)) * vertsX + max(0, min(vertsX-1, x))]
        }
        for z in 0..<vertsZ {
            for x in 0..<vertsX {
                let dx = hclamped(x+1, z) - hclamped(x-1, z)
                let dz = hclamped(x, z+1) - hclamped(x, z-1)
                let tX = SIMD3<Float>(tileSize, dx, 0)
                let tZ = SIMD3<Float>(0, dz, tileSize)
                let n  = simd_normalize(simd_cross(tZ, tX)) // right-handed
                normals[idx(x, z)] = SCNVector3(n.x, n.y, n.z)
            }
        }

        // Triangle indices
        var indices = [Int32]()
        indices.reserveCapacity(tilesX * tilesZ * 6)
        for z in 0..<tilesZ {
            for x in 0..<tilesX {
                let i0 = Int32((z    ) * vertsX + (x    ))
                let i1 = Int32((z    ) * vertsX + (x + 1))
                let i2 = Int32((z + 1) * vertsX + (x    ))
                let i3 = Int32((z + 1) * vertsX + (x + 1))
                indices.append(contentsOf: [i0, i2, i1,  i1, i2, i3])
            }
        }

        // Geometry sources
        let vSource = SCNGeometrySource(vertices: vertices)
        let nSource = SCNGeometrySource(normals: normals)

        let colorData: Data = colors.withUnsafeBufferPointer { Data(buffer: $0) }
        let cSource = SCNGeometrySource(
            data: colorData,
            semantic: .color,
            vectorCount: colors.count,
            usesFloatComponents: true,
            componentsPerVector: 4,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SIMD4<Float>>.size
        )

        let indexData: Data = indices.withUnsafeBufferPointer { Data(buffer: $0) }
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: indices.count / 3,
            bytesPerIndex: MemoryLayout<Int32>.size
        )

        let geom = SCNGeometry(sources: [vSource, nSource, cSource], elements: [element])

        let mat = SCNMaterial()
        mat.lightingModel = .physicallyBased
        mat.diffuse.contents = UIColor.white       // vertex colours carry the look
        mat.roughness.contents = 0.95
        mat.metalness.contents = 0.0
        mat.writesToDepthBuffer = true
        geom.materials = [mat]

        node.geometry = geom
        node.castsShadow = false
        return node
    }

    // Minimal height palette → RGBA (0…1)
    private struct HeightGradient {
        // beach, shallow, grass, dry, rock/snow
        let stops: [SIMD4<Float>] = [
            SIMD4(0.55, 0.80, 0.85, 1.0),
            SIMD4(0.20, 0.45, 0.55, 1.0),
            SIMD4(0.94, 0.95, 0.90, 1.0),
            SIMD4(0.93, 0.88, 0.70, 1.0),
            SIMD4(0.92, 0.92, 0.95, 1.0)
        ]

        func color(yNorm: Float, riverMask r: Float) -> SIMD4<Float> {
            if r > 0.55, yNorm >= 0.28 { return stops[0] } // water tint in channels
            if yNorm < 0.18 { return stops[1] }
            if yNorm < 0.28 { return stops[0] }
            if yNorm < 0.34 { return stops[3] }
            if yNorm < 0.62 { return stops[2] }
            return stops[4]
        }
    }
}
