//
//  TerrainChunkNode.swift
//  Glasslands
//
//  Created by . . on 9/30/25.
//
//  Builds one SceneKit mesh chunk from the noise fields.
//  Adds a tiny procedural detail map so grass no longer looks like carpet.
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

        // Tile origin (in tile coordinates)
        let originTileX = originChunk.x * tilesX
        let originTileZ = originChunk.y * tilesZ

        // --- Vertex positions, normals, vertex colours
        func idx(_ x: Int, _ z: Int) -> Int { z * vertsX + x }

        var positions = [SCNVector3](repeating: .zero, count: vertsX * vertsZ)
        var normals   = [SCNVector3](repeating: .zero, count: vertsX * vertsZ)
        var colours   = [UIColor](repeating: .white, count: vertsX * vertsZ)

        let grad = HeightClassifier(recipe: recipe)

        for z in 0...vertsZ - 1 {
            for x in 0...vertsX - 1 {
                let tx = originTileX + x
                let tz = originTileZ + z
                let wX = Float(tx) * tileSize
                let wZ = Float(tz) * tileSize
                let wY = TerrainMath.heightWorld(x: wX, z: wZ, cfg: cfg, noise: noise)

                positions[idx(x, z)] = SCNVector3(wX, wY, wZ)

                // Smooth normal
                let n = TerrainMath.normal(
                    tx: Double(tx), tz: Double(tz), cfg: cfg, noise: noise
                )
                normals[idx(x, z)] = SCNVector3(n)

                // Colour by height/slope/moisture/river
                let hN = Float(NoiseFieldsHeightN(tx: Double(tx), tz: Double(tz), noise: noise, recipe: recipe))
                let slope = Float(noise.slope(Double(tx), Double(tz)))
                let river = Float(noise.riverMask(Double(tx), Double(tz)))
                let moist = Float(noise.sampleMoisture(Double(tx), Double(tz))) / Float(max(0.0001, recipe.moisture.amplitude))

                let c = grad.color(yNorm: hN, slope: slope, riverMask: river, moisture01: moist)
                colours[idx(x, z)] = UIColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1)
            }
        }

        // Triangles
        var indices: [CInt] = []
        indices.reserveCapacity(tilesX * tilesZ * 6)
        for z in 0..<tilesZ {
            for x in 0..<tilesX {
                let a = CInt(idx(x, z))
                let b = CInt(idx(x+1, z))
                let c = CInt(idx(x, z+1))
                let d = CInt(idx(x+1, z+1))
                indices.append(contentsOf: [a, c, b, b, c, d])
            }
        }

        let vSource = SCNGeometrySource(vertices: positions)
        let nSource = SCNGeometrySource(normals: normals)
        let cSource = geometrySourceForVertexColors(colours)
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)

        let geom = SCNGeometry(sources: [vSource, nSource, cSource], elements: [element])

        // Material with micro‑detail (tileable noise, multiplied into base colour)
        let mat = SCNMaterial()
        mat.lightingModel = .physicallyBased
        mat.diffuse.contents = UIColor.white                       // vertex colours carry the palette
        mat.multiply.contents = SceneKitHelpers.groundDetailTexture(size: 512)
        mat.multiply.wrapS = .repeat
        mat.multiply.wrapT = .repeat
        mat.multiply.mipFilter = .linear
        mat.roughness.contents = 0.95
        mat.metalness.contents = 0.0
        mat.isDoubleSided = true       // avoids “open ground” artefacts
        mat.writesToDepthBuffer = true
        mat.readsFromDepthBuffer = true

        geom.materials = [mat]

        let meshNode = SCNNode(geometry: geom)
        meshNode.castsShadow = false

        // Static physics for any future dynamic objects resting on terrain
        meshNode.physicsBody = SCNPhysicsBody.static()
        meshNode.physicsBody?.restitution = 0.0
        meshNode.physicsBody?.friction = 1.0
        meshNode.physicsBody?.categoryBitMask = 1

        return meshNode
    }

    // MARK: - Helper
    private static func NoiseFieldsHeightN(tx: Double, tz: Double, noise: NoiseFields, recipe: BiomeRecipe) -> Double {
        var h = noise.sampleHeight(tx, tz)
        let r = noise.riverMask(tx, tz)
        if r > 0.55 {
            let t = min(1.0, (r - 0.55) / 0.45)
            h *= (1.0 - 0.35 * t)
        }
        return h / max(0.0001, recipe.height.amplitude)
    }

    // Height → palette
    private struct HeightClassifier {
        // Colours (RGBA 0…1)
        let deep = SIMD4<Float>(0.18, 0.42, 0.58, 1.0)
        let shore = SIMD4<Float>(0.55, 0.80, 0.88, 1.0)
        let grass = SIMD4<Float>(0.32, 0.62, 0.34, 1.0)
        let sand  = SIMD4<Float>(0.92, 0.87, 0.68, 1.0)
        let rock  = SIMD4<Float>(0.90, 0.92, 0.95, 1.0)

        // Thresholds (normalised height 0…1)
        let deepCut: Float = 0.22
        let shoreCut: Float = 0.30
        let sandCut: Float  = 0.33
        let snowCut: Float  = 0.88

        let recipe: BiomeRecipe

        func color(yNorm y: Float, slope s: Float, riverMask r: Float, moisture01 m: Float) -> SIMD4<Float> {
            if y < deepCut { return deep }
            if y < shoreCut || r > 0.60 { return shore }
            if s > 0.55 || y > snowCut { return rock }
            if y < sandCut { return sand }

            // Blend greener in moist or near riverbeds
            let t = max(0, min(1, m * 0.65 + r * 0.20))
            let g = mix(grass, SIMD4<Float>(0.40, 0.75, 0.38, 1.0), t)
            return g
        }

        @inline(__always) private func mix(_ a: SIMD4<Float>, _ b: SIMD4<Float>, _ t: Float) -> SIMD4<Float> { a + (b - a) * t }
    }
}
