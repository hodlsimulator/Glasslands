//
//  TerrainChunkNode.swift
//  Glasslands
//
//  Created by . . on 9/30/25.
//
//  Builds one SceneKit mesh chunk from the noise fields.
//  This version dramatically increases grass coverage,
//  adds slope-aware rock, and gives the mesh a static physics body.
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

        let grad = HeightClassifier(recipe: recipe)
        let minY = heights.min() ?? 0
        let maxY = heights.max() ?? 1
        let invRange: Float = (maxY > minY) ? 1.0 / (maxY - minY) : 1.0

        @inline(__always)
        func heightAt(_ x: Int, _ z: Int) -> Float {
            heights[max(0, min(vertsZ-1, z)) * vertsX + max(0, min(vertsX-1, x))]
        }

        for z in 0..<vertsZ {
            for x in 0..<vertsX {
                let tx = Float(originTileX + x)
                let tz = Float(originTileZ + z)

                let wX = tx * tileSize
                let wZ = tz * tileSize
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

                // Additional local metrics for colouring
                let yNorm = (y - minY) * invRange
                let slopeMag = min(1.0, (abs(hR - hL) + abs(hU - hD)) * 0.20) // tuned slope proxy
                let river = Float(noise.riverMask(Double(tx), Double(tz)))
                let moistureRaw = Float(noise.sampleMoisture(Double(tx), Double(tz)))
                let moisture = min(1, moistureRaw / max(0.001, Float(recipe.moisture.amplitude)))

                let rgba = grad.color(yNorm: yNorm, slope: slopeMag, riverMask: river, moisture01: moisture)
                colours[idx(x, z)] = UIColor(red: CGFloat(rgba.x), green: CGFloat(rgba.y), blue: CGFloat(rgba.z), alpha: CGFloat(rgba.w))
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
        mat.readsFromDepthBuffer = true
        geom.materials = [mat]

        let meshNode = SCNNode(geometry: geom)
        meshNode.castsShadow = false

        // Give terrain a static physics body so *anything* with physics won't fall through.
        meshNode.physicsBody = SCNPhysicsBody.static()
        meshNode.physicsBody?.restitution = 0.0
        meshNode.physicsBody?.friction = 1.0
        meshNode.physicsBody?.categoryBitMask = 1

        return meshNode
    }

    // MARK: - Height → palette (with slope & moisture)
    private struct HeightClassifier {
        // Colours (RGBA 0…1)
        // deep water, shallows, grass base, sand, rock/snow
        let deep  = SIMD4<Float>(0.18, 0.42, 0.58, 1.0)
        let shore = SIMD4<Float>(0.55, 0.80, 0.88, 1.0)
        let grass = SIMD4<Float>(0.32, 0.62, 0.34, 1.0)
        let sand  = SIMD4<Float>(0.92, 0.87, 0.68, 1.0)
        let rock  = SIMD4<Float>(0.90, 0.92, 0.95, 1.0)

        // Thresholds (normalised height 0…1). Wide green band.
        let deepCut:  Float = 0.22
        let shoreCut: Float = 0.30
        let sandCut:  Float = 0.33
        let snowCut:  Float = 0.88

        let recipe: BiomeRecipe

        func color(yNorm y: Float, slope s: Float, riverMask r: Float, moisture01 m: Float) -> SIMD4<Float> {
            // Water first
            if y < deepCut { return deep }
            if y < shoreCut || r > 0.60 { return shore }

            // Very steep or very high → rock/snow
            if s > 0.55 || y > snowCut {
                return rock
            }

            // A tiny beach/sand fringe just above shore
            if y < sandCut { return sand }

            // Everything else → lush grass (modulated by moisture)
            // Moisture lightens & saturates the green slightly.
            let t = max(0, min(1, m * 0.65 + r * 0.20)) // rivers make it lusher
            let g = mix(grass, SIMD4<Float>(0.40, 0.75, 0.38, 1.0), t)
            return g
        }

        @inline(__always)
        private func mix(_ a: SIMD4<Float>, _ b: SIMD4<Float>, _ t: Float) -> SIMD4<Float> {
            a + (b - a) * t
        }
    }
}
