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

    @MainActor
    private static var cachedMaterial: SCNMaterial?

    @MainActor
    private static var cachedMaterialKey: (tilesX: Int, tilesZ: Int, simple: Bool)?

    @MainActor
    private static func terrainMaterial(tilesX: Int, tilesZ: Int) -> SCNMaterial {
        #if DEBUG
        let simpleShading = ProcessInfo.processInfo.environment["GL_DEBUG_DISABLE_TERRAIN_SHADING"] == "1"
        #else
        let simpleShading = false
        #endif
        if let m = cachedMaterial, let k = cachedMaterialKey, k.tilesX == tilesX, k.tilesZ == tilesZ, k.simple == simpleShading {
            return m
        }

        let mat = SCNMaterial()
        if simpleShading {
            mat.lightingModel = .constant
            mat.isLitPerPixel = false
        } else {
            mat.lightingModel = .lambert
            mat.isLitPerPixel = true
        }
        mat.emission.contents = UIColor.black
        mat.specular.contents = UIColor.black
        mat.shininess = 0.0
        mat.isDoubleSided = false
        mat.cullMode = .back
        mat.readsFromDepthBuffer = true
        mat.writesToDepthBuffer = true

        let albedoMTL = SceneKitHelpers.grassAlbedoTextureMTL(size: 512)
        mat.diffuse.contents = albedoMTL

        let groundStops: CGFloat = -2.0
        mat.diffuse.intensity = CGFloat(pow(2.0, Double(groundStops)))

        mat.diffuse.wrapS = .repeat
        mat.diffuse.wrapT = .repeat
        mat.diffuse.minificationFilter = .linear
        mat.diffuse.magnificationFilter = .linear
        mat.diffuse.mipFilter = .linear

        let repeatsPerTile = SceneKitHelpers.grassRepeatsPerTile
        let repeatsX = CGFloat(tilesX) * repeatsPerTile
        let repeatsY = CGFloat(tilesZ) * repeatsPerTile
        mat.diffuse.contentsTransform = SCNMatrix4MakeScale(Float(repeatsX), Float(repeatsY), 1)

        if !simpleShading {
            GroundShadowShader.applyIfNeeded(to: mat)
        }

        cachedMaterial = mat
        cachedMaterialKey = (tilesX: tilesX, tilesZ: tilesZ, simple: simpleShading)
        return mat
    }

    @MainActor
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
        _ = cfg

        let node = SCNNode()
        node.name = "chunk_\(data.originChunkX)_\(data.originChunkY)"

        let posData = data.positions.withUnsafeBytes { Data($0) }
        let nrmData = data.normals.withUnsafeBytes { Data($0) }
        let uvData  = data.uvs.withUnsafeBytes { Data($0) }
        let idxData = data.indices.withUnsafeBytes { Data($0) }

        let posSrc = SCNGeometrySource(
            data: posData, semantic: .vertex, vectorCount: data.positions.count,
            usesFloatComponents: true, componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0,
            dataStride: MemoryLayout<simd_float3>.stride
        )
        let nrmSrc = SCNGeometrySource(
            data: nrmData, semantic: .normal, vectorCount: data.normals.count,
            usesFloatComponents: true, componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0,
            dataStride: MemoryLayout<simd_float3>.stride
        )
        let uvSrc = SCNGeometrySource(
            data: uvData, semantic: .texcoord, vectorCount: data.uvs.count,
            usesFloatComponents: true, componentsPerVector: 2,
            bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0,
            dataStride: MemoryLayout<simd_float2>.stride
        )
        let element = SCNGeometryElement(
            data: idxData, primitiveType: .triangles, primitiveCount: data.indices.count / 3,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )

        let geom = SCNGeometry(sources: [posSrc, nrmSrc, uvSrc], elements: [element])
        geom.materials = [terrainMaterial(tilesX: data.tilesX, tilesZ: data.tilesZ)]

        node.geometry = geom

        node.castsShadow = false
        node.categoryBitMask = 0x0000_0400

        return node
    }
}
