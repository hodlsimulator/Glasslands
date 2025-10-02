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
            cfg: cfg,
            noise: noise,
            recipe: recipe
        )
        return node(from: data)
    }

    @MainActor
    static func node(from data: TerrainChunkData) -> SCNNode {
        let node = SCNNode()
        node.name = "chunk_\(data.originChunkX)_\(data.originChunkY)"

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
        mat.isDoubleSided = true              // never see through underside
        mat.diffuse.contents = SceneKitHelpers.groundDetailTexture(size: 128)
        mat.diffuse.wrapS = .repeat
        mat.diffuse.wrapT = .repeat
        mat.roughness.contents = 1.0
        geom.materials = [mat]

        node.geometry = geom
        node.castsShadow = false
        return node
    }
}
