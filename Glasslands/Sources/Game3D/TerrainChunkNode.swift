//
//  TerrainChunkNode.swift
//  Glasslands
//
//  Created by . . on 9/30/25.
//
//  Uses prebuilt wrap-aware mipmapped MTLTextures to eliminate tiling seam lines.
//

import SceneKit
import simd
import UIKit
import Metal

struct TerrainChunkData: Sendable {
    let originChunkX: Int
    let originChunkY: Int
    let tilesX: Int
    let tilesZ: Int
    let tileSize: Float
    let positions: [simd_float3]
    let normals: [simd_float3]
    let colors: [simd_float4]
    let uvs: [simd_float2]
    let indices: [UInt32]
}

enum TerrainChunkNode {

    static func makeNode(
        originChunk: IVec2,
        cfg: FirstPersonEngine.Config,
        noise: NoiseFields,
        recipe: BiomeRecipe
    ) -> SCNNode {
        let data = TerrainMeshBuilder.makeData(
            originChunkX: originChunk.x,
            originChunkY: originChunk.y,
            tilesX: cfg.tilesX,
            tilesZ: cfg.tilesZ,
            tileSize: cfg.tileSize,
            heightScale: cfg.heightScale,
            noise: noise,
            recipe: recipe
        )
        return node(from: data, cfg: cfg)
    }

    @MainActor
    static func node(from data: TerrainChunkData) -> SCNNode {
        node(from: data, cfg: FirstPersonEngine.Config())
    }

    @MainActor
    static func node(from data: TerrainChunkData, cfg: FirstPersonEngine.Config) -> SCNNode {
        let node = SCNNode()
        node.name = "chunk_\(data.originChunkX)_\(data.originChunkY)"

        // Interleaved buffers → SceneKit sources
        let posData = data.positions.withUnsafeBytes { Data($0) }
        let nrmData = data.normals.withUnsafeBytes { Data($0) }
        let uvData  = data.uvs.withUnsafeBytes { Data($0) }
        let idxData = data.indices.withUnsafeBytes { Data($0) }

        let posSrc = SCNGeometrySource(
            data: posData, semantic: .vertex,
            vectorCount: data.positions.count,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<simd_float3>.stride
        )
        let nrmSrc = SCNGeometrySource(
            data: nrmData, semantic: .normal,
            vectorCount: data.normals.count,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<simd_float3>.stride
        )
        let uvSrc = SCNGeometrySource(
            data: uvData, semantic: .texcoord,
            vectorCount: data.uvs.count,
            usesFloatComponents: true,
            componentsPerVector: 2,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<simd_float2>.stride
        )
        let element = SCNGeometryElement(
            data: idxData,
            primitiveType: .triangles,
            primitiveCount: data.indices.count / 3,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )

        let geom = SCNGeometry(sources: [posSrc, nrmSrc, uvSrc], elements: [element])

        // --- Material using seamless MTLTextures ---
        let mat = SCNMaterial()
        mat.lightingModel = .physicallyBased
        mat.metalness.contents = 0.0
        mat.roughness.contents = 0.95
        mat.emission.contents = UIColor.black
        mat.isDoubleSided = true
        mat.cullMode = .back
        mat.readsFromDepthBuffer = true
        mat.writesToDepthBuffer = true

        // Prebuilt, wrap-aware mipmapped textures
        let albedoMTL = SceneKitHelpers.grassAlbedoTextureMTL(size: 512)
        let normalMTL = SceneKitHelpers.grassNormalTextureMTL(size: 512, strength: 1.6)
        let macroMTL  = SceneKitHelpers.grassMacroVariationTextureMTL(size: 256)

        mat.diffuse.contents = albedoMTL
        mat.normal.contents  = normalMTL
        mat.multiply.contents = macroMTL

        // Repeat settings (integer repeats per chunk = seam-safe)
        let repeatsPerTile = SceneKitHelpers.grassRepeatsPerTile
        let repeatsX = CGFloat(data.tilesX) * repeatsPerTile
        let repeatsY = CGFloat(data.tilesZ) * repeatsPerTile

        mat.diffuse.wrapS = .repeat;    mat.diffuse.wrapT = .repeat
        mat.normal.wrapS  = .repeat;    mat.normal.wrapT  = .repeat
        mat.multiply.wrapS = .repeat;   mat.multiply.wrapT = .repeat

        // Use linear sampling; our custom mip chain is already seamless.
        mat.diffuse.minificationFilter = .linear
        mat.diffuse.magnificationFilter = .linear
        mat.diffuse.mipFilter = .linear
        mat.normal.minificationFilter = .linear
        mat.normal.magnificationFilter = .linear
        mat.normal.mipFilter = .linear
        mat.multiply.minificationFilter = .linear
        mat.multiply.magnificationFilter = .linear
        mat.multiply.mipFilter = .linear

        // Scale repeats across the chunk
        let scaleT = SCNMatrix4MakeScale(Float(repeatsX), Float(repeatsY), 1)
        mat.diffuse.contentsTransform = scaleT
        mat.normal.contentsTransform  = scaleT

        // Macro variation repeats a small integer count across the chunk
        let macroRepeats = SceneKitHelpers.grassMacroRepeatsAcrossChunk
        let macroScaleT = SCNMatrix4MakeScale(Float(macroRepeats), Float(macroRepeats), 1)
        mat.multiply.contentsTransform = macroScaleT

        geom.materials = [mat]
        node.geometry = geom

        node.castsShadow = false
        node.categoryBitMask = 0x00000400

        return node
    }
}
