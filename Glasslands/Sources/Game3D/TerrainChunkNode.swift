//
//  TerrainChunkNode.swift
//  Glasslands
//
//  Created by . . on 9/30/25.
//
//  Builds terrain either as pure mesh data (Sendable) or as an SCNNode (main actor).
//

import SceneKit
import simd
import UIKit

struct TerrainChunkData: Sendable {
    let originChunkX: Int
    let originChunkY: Int
    let tilesX: Int
    let tilesZ: Int
    let tileSize: Float
    let positions: [simd_float3]
    let normals: [simd_float3]
    let colors: [simd_float4]    // not used in this hard reset
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

    @MainActor static func node(from data: TerrainChunkData) -> SCNNode {
        node(from: data, cfg: FirstPersonEngine.Config())
    }

    @MainActor static func node(from data: TerrainChunkData, cfg: FirstPersonEngine.Config) -> SCNNode {
        let node = SCNNode()
        node.name = "chunk_\(data.originChunkX)_\(data.originChunkY)"

        // Geometry sources
        let posData = data.positions.withUnsafeBytes { Data($0) }
        let nrmData = data.normals.withUnsafeBytes { Data($0) }
        let colData = data.colors.withUnsafeBytes { Data($0) }
        let uvData  = data.uvs.withUnsafeBytes { Data($0) }
        let idxData = data.indices.withUnsafeBytes { Data($0) }

        let posSrc = SCNGeometrySource(
            data: posData, semantic: .vertex,
            vectorCount: data.positions.count, usesFloatComponents: true,
            componentsPerVector: 3, bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0, dataStride: MemoryLayout<simd_float3>.stride
        )
        let nrmSrc = SCNGeometrySource(
            data: nrmData, semantic: .normal,
            vectorCount: data.normals.count, usesFloatComponents: true,
            componentsPerVector: 3, bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0, dataStride: MemoryLayout<simd_float3>.stride
        )
        let colSrc = SCNGeometrySource(
            data: colData, semantic: .color,
            vectorCount: data.colors.count, usesFloatComponents: true,
            componentsPerVector: 4, bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0, dataStride: MemoryLayout<simd_float4>.stride
        )
        let uvSrc = SCNGeometrySource(
            data: uvData, semantic: .texcoord,
            vectorCount: data.uvs.count, usesFloatComponents: true,
            componentsPerVector: 2, bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0, dataStride: MemoryLayout<simd_float2>.stride
        )
        let element = SCNGeometryElement(
            data: idxData, primitiveType: .triangles,
            primitiveCount: data.indices.count / 3, bytesPerIndex: MemoryLayout<UInt32>.size
        )

        let geom = SCNGeometry(sources: [posSrc, nrmSrc, colSrc, uvSrc], elements: [element])

        // Solid emissive green so it can’t render black.
        let mat = SCNMaterial()
        mat.lightingModel = .constant
        let green = UIColor(red: 0.32, green: 0.62, blue: 0.34, alpha: 1.0)
        mat.emission.contents = green
        mat.diffuse.contents  = green
        mat.emission.intensity = 1.0

        // Avoid any culling surprises on terrain.
        mat.isDoubleSided = true
        mat.cullMode = .back
        mat.readsFromDepthBuffer = true
        mat.writesToDepthBuffer = true

        geom.materials = [mat]
        node.geometry = geom
        node.castsShadow = true
        return node
    }
}
