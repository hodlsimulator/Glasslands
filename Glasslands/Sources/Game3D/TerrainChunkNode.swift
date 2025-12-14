//
//  TerrainChunkNode.swift
//  Glasslands
//
//  Created by . . on 9/30/25.
//
//  Uses prebuilt wrap-aware mipmapped MTLTextures to eliminate tiling seam lines.
//

import SceneKit

enum TerrainChunkNode {

    // Terrain material is identical across chunks. Reusing a single instance avoids per-chunk
    // shader compilation and significantly reduces streaming hitching.
    @MainActor private static var cachedTerrainMaterial: SCNMaterial?
    @MainActor private static var cachedTilesX: Int = -1
    @MainActor private static var cachedTilesZ: Int = -1

    @MainActor
    private static func sharedTerrainMaterial(tilesX: Int, tilesZ: Int) -> SCNMaterial {
        if let mat = cachedTerrainMaterial,
           cachedTilesX == tilesX,
           cachedTilesZ == tilesZ {
            return mat
        }

        let mat = SCNMaterial()
        mat.lightingModel = .lambert
        mat.isLitPerPixel = true
        mat.emission.contents = UIColor.black
        mat.specular.contents = UIColor.black
        mat.shininess = 0.0
        mat.isDoubleSided = false
        mat.cullMode = .back
        mat.readsFromDepthBuffer = true
        mat.writesToDepthBuffer = true

        // Use the same texture configuration as before.
        mat.diffuse.contents = SceneKitHelpers.groundStops()
        mat.diffuse.intensity = pow(2, -2)
        mat.diffuse.wrapS = .repeat
        mat.diffuse.wrapT = .repeat

        let repeatsPerTile: Float = SceneKitHelpers.grassRepeatsPerTile()
        let repeatsX = Float(tilesX) * repeatsPerTile
        let repeatsZ = Float(tilesZ) * repeatsPerTile
        mat.diffuse.contentsTransform = SCNMatrix4MakeScale(repeatsX, repeatsZ, 1)

        mat.diffuse.magnificationFilter = .linear
        mat.diffuse.minificationFilter = .linear
        mat.diffuse.mipFilter = .linear

        GroundShadowShader.applyIfNeeded(to: mat)

        cachedTerrainMaterial = mat
        cachedTilesX = tilesX
        cachedTilesZ = tilesZ
        return mat
    }

    // Helper called by TerrainMeshBuilder.makeNode(...) (2D/3D compatibility).
    @MainActor
    static func makeNode(
        originChunk: IVec2,
        cfg: FirstPersonEngine.Config,
        noise: NoiseFields,
        recipe: BiomeRecipe
    ) -> SCNNode {
        let data = TerrainMeshBuilder.makeData(originChunk: originChunk, cfg: cfg, noise: noise, recipe: recipe)
        return node(from: data, cfg: cfg)
    }

    @MainActor
    static func node(from data: TerrainChunkData) -> SCNNode {
        makeNode(data, cfg: .default)
    }

    @MainActor
    static func node(from data: TerrainChunkData, cfg: FirstPersonEngine.Config) -> SCNNode {
        // Convert arrays into contiguous Data buffers.
        let posData = data.positions.withUnsafeBytes { Data($0) }
        let norData = data.normals.withUnsafeBytes { Data($0) }
        let uvData = data.uvs.withUnsafeBytes { Data($0) }
        let idxData = data.indices.withUnsafeBytes { Data($0) }

        let posSrc = SCNGeometrySource(data: posData,
                                       semantic: .vertex,
                                       vectorCount: data.positions.count,
                                       usesFloatComponents: true,
                                       componentsPerVector: 3,
                                       bytesPerComponent: MemoryLayout<Float>.size,
                                       dataOffset: 0,
                                       dataStride: MemoryLayout<SIMD3<Float>>.stride)

        let norSrc = SCNGeometrySource(data: norData,
                                       semantic: .normal,
                                       vectorCount: data.normals.count,
                                       usesFloatComponents: true,
                                       componentsPerVector: 3,
                                       bytesPerComponent: MemoryLayout<Float>.size,
                                       dataOffset: 0,
                                       dataStride: MemoryLayout<SIMD3<Float>>.stride)

        let uvSrc = SCNGeometrySource(data: uvData,
                                      semantic: .texcoord,
                                      vectorCount: data.uvs.count,
                                      usesFloatComponents: true,
                                      componentsPerVector: 2,
                                      bytesPerComponent: MemoryLayout<Float>.size,
                                      dataOffset: 0,
                                      dataStride: MemoryLayout<SIMD2<Float>>.stride)

        let elem = SCNGeometryElement(data: idxData,
                                      primitiveType: .triangles,
                                      primitiveCount: data.indices.count / 3,
                                      bytesPerIndex: MemoryLayout<UInt32>.size)

        let geom = SCNGeometry(sources: [posSrc, norSrc, uvSrc], elements: [elem])

        // Shared material.
        geom.materials = [sharedTerrainMaterial(tilesX: data.tilesX, tilesZ: data.tilesZ)]

        let node = SCNNode(geometry: geom)
        node.categoryBitMask = 0x400 // terrain for hit test filtering
        node.castsShadow = true
        node.name = "terrain_chunk_\(data.originChunk.x)_\(data.originChunk.y)"

        return node
    }
}
