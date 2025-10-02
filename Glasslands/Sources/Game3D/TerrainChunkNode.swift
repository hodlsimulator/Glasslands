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
    let positions: [SIMD3<Float>]
    let normals:   [SIMD3<Float>]
    let colors:    [SIMD4<Float>]   // RGBA 0…1 (A unused for draw; we compute wetness in shader)
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
        // Backwards-compatible path (cfg unknown): assume defaults
        return node(from: data, cfg: FirstPersonEngine.Config())
    }

    @MainActor
    static func node(from data: TerrainChunkData, cfg: FirstPersonEngine.Config) -> SCNNode {
        let node = SCNNode()
        node.name = "chunk_\(data.originChunkX)_\(data.originChunkY)"

        let posData = data.positions.withUnsafeBytes { Data($0) }
        let nrmData = data.normals.withUnsafeBytes { Data($0) }
        let colData = data.colors.withUnsafeBytes { Data($0) }
        let uvData  = data.uvs.withUnsafeBytes { Data($0) }
        let idxData = data.indices.withUnsafeBytes { Data($0) }

        let posSrc = SCNGeometrySource(data: posData, semantic: .vertex,  vectorCount: data.positions.count, usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: MemoryLayout<SIMD3<Float>>.stride)
        let nrmSrc = SCNGeometrySource(data: nrmData, semantic: .normal,  vectorCount: data.normals.count,   usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: MemoryLayout<SIMD3<Float>>.stride)
        let colSrc = SCNGeometrySource(data: colData, semantic: .color,   vectorCount: data.colors.count,    usesFloatComponents: true, componentsPerVector: 4, bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: MemoryLayout<SIMD4<Float>>.stride)
        let uvSrc  = SCNGeometrySource(data: uvData,  semantic: .texcoord,vectorCount: data.uvs.count,       usesFloatComponents: true, componentsPerVector: 2, bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: MemoryLayout<SIMD2<Float>>.stride)

        let element = SCNGeometryElement(data: idxData, primitiveType: .triangles, primitiveCount: data.indices.count / 3, bytesPerIndex: MemoryLayout<UInt32>.size)
        let geom = SCNGeometry(sources: [posSrc, nrmSrc, colSrc, uvSrc], elements: [element])

        let mat = SCNMaterial()
        mat.lightingModel = .physicallyBased
        mat.isDoubleSided = false

        // Base colour from vertex colours; keep albedo neutral
        mat.diffuse.contents = UIColor.white

        // Subtle micro-detail via multiply (safe even with vertex colours)
        let repeatTiling: CGFloat = 10.0
        mat.multiply.contents = SceneKitHelpers.groundDetailTexture(size: 512)
        mat.multiply.wrapS = .repeat
        mat.multiply.wrapT = .repeat
        mat.multiply.contentsTransform = SCNMatrix4MakeScale(Float(repeatTiling), Float(repeatTiling), 1)

        // Keep normal map but reduce strength visually by raising roughness
        mat.normal.contents = SceneKitHelpers.groundDetailNormalTexture(size: 512, strength: 1.2)
        mat.normal.wrapS = .repeat
        mat.normal.wrapT = .repeat
        mat.normal.contentsTransform = SCNMatrix4MakeScale(Float(repeatTiling), Float(repeatTiling), 1)

        mat.roughness.contents = 0.95
        mat.metalness.contents = 0.0

        // Shore wetness + foam band
        let surfaceMod = """
        #pragma arguments
        float u_heightScale;
        float u_waterLevelN;
        float u_grassIntensity;
        float u_waterBlue;
        #pragma body
        float hN = clamp(_worldPosition.y / max(0.0001, u_heightScale), 0.0, 1.0);
        float n1 = fract(sin(dot(_worldPosition.xz, float2(12.9898, 78.233))) * 43758.5453);
        float n2 = fract(sin(dot(_worldPosition.xz, float2(3.9812, 17.719))) * 15731.7431);
        float jitter = (n1 * 0.6 + n2 * 0.4) * 2.0 - 1.0;
        float tint = 1.0 + u_grassIntensity * jitter * 0.03;
        _surface.diffuse.rgb *= tint;

        float wet  = smoothstep(u_waterLevelN + 0.030, u_waterLevelN - 0.060, hN);
        float foam = smoothstep(u_waterLevelN + 0.004, u_waterLevelN - 0.010, hN)
                   - smoothstep(u_waterLevelN - 0.012, u_waterLevelN - 0.030, hN);
        float3 waterTint = float3(0.58, 0.76, 0.90);
        _surface.diffuse.rgb = mix(_surface.diffuse.rgb, waterTint, wet * u_waterBlue);
        _surface.roughness   = mix(_surface.roughness, 0.18, wet);
        _surface.emission.rgb += foam * float3(0.08, 0.09, 0.10);
        """
        mat.shaderModifiers = [.surface: surfaceMod]
        mat.setValue(CGFloat(cfg.heightScale), forKey: "u_heightScale")
        mat.setValue(0.30 as CGFloat,          forKey: "u_waterLevelN")
        mat.setValue(0.55 as CGFloat,          forKey: "u_waterBlue")
        mat.setValue(0.85 as CGFloat,          forKey: "u_grassIntensity")

        geom.materials = [mat]
        node.geometry = geom
        node.castsShadow = true
        return node
    }
}
