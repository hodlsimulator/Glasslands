//
//  TerrainChunkNode.swift
//  Glasslands
//
//  Created by . . on 9/30/25.
//

import SceneKit
import UIKit

struct TerrainChunkNode {

    static func makeNode(originChunk: IVec2,
                         cfg: FirstPersonEngine.Config,
                         noise: NoiseFields,
                         recipe: BiomeRecipe) -> SCNNode {
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
        func idx(_ x: Int, _ z: Int) -> Int { z * vertsX + x }

        for z in 0..<vertsZ {
            for x in 0..<vertsX {
                let tx = Double(originTileX + x)
                let tz = Double(originTileZ + z)
                var h = noise.sampleHeight(tx, tz)      // 0..~1
                // Soften river channels by pulling heights down a touch
                let r = noise.riverMask(tx, tz)
                if r > 0.55 {
                    h = h * (1.0 - 0.35 * min(1.0, (r - 0.55) / 0.45))
                }
                heights[idx(x, z)] = Float(h) * heightScale
            }
        }

        // Vertex positions, normals, colours
        var vertices = [SCNVector3](repeating: SCNVector3(0,0,0), count: vertsX * vertsZ) // fix: no .zero
        var normals  = [SCNVector3](repeating: SCNVector3(0,0,0), count: vertsX * vertsZ)
        var colors   = [UIColor](repeating: .white, count: vertsX * vertsZ)

        // Build positions + provisional colours (by height bands + rivers)
        let palette = AppColours.uiColors(from: recipe.paletteHex)
        let gradient = HeightGradient(palette: palette)

        for z in 0..<vertsZ {
            for x in 0..<vertsX {
                let worldX = Float(originTileX + x) * tileSize
                let worldZ = Float(originTileZ + z) * tileSize
                let y      = heights[idx(x, z)]
                vertices[idx(x, z)] = SCNVector3(worldX, y, worldZ)

                // Normalised height 0..1 (relative to heightScale)
                let yNorm = max(0, min(1, y / heightScale))
                let r = noise.riverMask(Double(originTileX + x), Double(originTileZ + z))
                colors[idx(x, z)] = gradient.color(yNorm: Float(yNorm), riverMask: Float(r))
            }
        }

        // Compute normals via central differences
        func hAt(_ x: Int, _ z: Int) -> Float {
            heights[max(0, min(vertsZ-1, z)) * vertsX + max(0, min(vertsX-1, x))]
        }

        for z in 0..<vertsZ {
            for x in 0..<vertsX {
                let hL = hAt(x-1, z)
                let hR = hAt(x+1, z)
                let hD = hAt(x, z-1)
                let hU = hAt(x, z+1)
                let dx = (hR - hL) / 2.0
                let dz = (hU - hD) / 2.0
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
                let i0 = Int32(idx(x,     z))
                let i1 = Int32(idx(x + 1, z))
                let i2 = Int32(idx(x,     z + 1))
                let i3 = Int32(idx(x + 1, z + 1))
                indices.append(contentsOf: [i0, i1, i2,  i1, i3, i2])
            }
        }

        // Geometry sources/elements
        let vSource = SCNGeometrySource(vertices: vertices)
        let nSource = SCNGeometrySource(normals: normals)
        // Use an explicit RGBA float geometry source for iOS (fixes “No exact matches…”)
        let cSource = geometrySourceForVertexColors(colors)

        let indexData = indices.withUnsafeBufferPointer { Data(buffer: $0) }
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: indices.count / 3,
            bytesPerIndex: MemoryLayout<Int32>.size
        )

        let geom = SCNGeometry(sources: [vSource, nSource, cSource], elements: [element])
        let mat = SCNMaterial()
        mat.lightingModel = .physicallyBased
        mat.diffuse.contents = UIColor.white            // per-vertex colours carry the look
        mat.roughness.contents = 0.95
        mat.metalness.contents = 0.0
        mat.writesToDepthBuffer = true
        geom.materials = [mat]

        node.geometry = geom
        node.castsShadow = false
        return node
    }

    private struct HeightGradient {
        let stops: [UIColor]
        init(palette: [UIColor]) {
            if palette.count >= 5 { stops = palette }
            else {
                stops = [
                    UIColor(red: 0.55, green: 0.80, blue: 0.85, alpha: 1),
                    UIColor(red: 0.20, green: 0.45, blue: 0.55, alpha: 1),
                    UIColor(red: 0.94, green: 0.95, blue: 0.90, alpha: 1),
                    UIColor(red: 0.93, green: 0.88, blue: 0.70, alpha: 1),
                    UIColor(red: 0.43, green: 0.30, blue: 0.17, alpha: 1)
                ]
            }
        }

        func color(yNorm: Float, riverMask r: Float) -> UIColor {
            if r > 0.55, yNorm >= 0.28 { return stops.first ?? UIColor.systemTeal }
            if yNorm < 0.18 { return stops.indices.contains(1) ? stops[1] : .systemBlue }
            if yNorm < 0.28 { return stops.indices.contains(0) ? stops[0] : .cyan }
            if yNorm < 0.34 { return stops.indices.contains(3) ? stops[3] : .systemYellow }
            if yNorm < 0.62 { return stops.indices.contains(2) ? stops[2] : .systemGreen }
            if yNorm < 0.82 { return .darkGray }
            return .white
        }
    }
}
