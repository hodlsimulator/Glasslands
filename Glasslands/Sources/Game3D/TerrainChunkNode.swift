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
    let colors:    [SIMD4<Float>]   // RGBA 0…1 (not relied upon here)
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
        node(from: data, cfg: FirstPersonEngine.Config())
    }

    @MainActor
    static func node(from data: TerrainChunkData, cfg: FirstPersonEngine.Config) -> SCNNode {
        let node = SCNNode()
        node.name = "chunk_\(data.originChunkX)_\(data.originChunkY)"

        // Geometry
        let posData = data.positions.withUnsafeBytes { Data($0) }
        let nrmData = data.normals.withUnsafeBytes { Data($0) }
        let colData = data.colors.withUnsafeBytes { Data($0) }
        let uvData  = data.uvs.withUnsafeBytes { Data($0) }
        let idxData = data.indices.withUnsafeBytes { Data($0) }

        let posSrc = SCNGeometrySource(
            data: posData, semantic: .vertex, vectorCount: data.positions.count,
            usesFloatComponents: true, componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0,
            dataStride: MemoryLayout<SIMD3<Float>>.stride
        )
        let nrmSrc = SCNGeometrySource(
            data: nrmData, semantic: .normal, vectorCount: data.normals.count,
            usesFloatComponents: true, componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0,
            dataStride: MemoryLayout<SIMD3<Float>>.stride
        )
        let colSrc = SCNGeometrySource(
            data: colData, semantic: .color, vectorCount: data.colors.count,
            usesFloatComponents: true, componentsPerVector: 4,
            bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0,
            dataStride: MemoryLayout<SIMD4<Float>>.stride
        )
        let uvSrc = SCNGeometrySource(
            data: uvData, semantic: .texcoord, vectorCount: data.uvs.count,
            usesFloatComponents: true, componentsPerVector: 2,
            bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0,
            dataStride: MemoryLayout<SIMD2<Float>>.stride
        )

        let element = SCNGeometryElement(
            data: idxData, primitiveType: .triangles,
            primitiveCount: data.indices.count / 3,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )

        let geom = SCNGeometry(sources: [posSrc, nrmSrc, colSrc, uvSrc], elements: [element])

        // Ground material (no external textures; no chance of magenta)
        let mat = SCNMaterial()
        mat.lightingModel = .physicallyBased
        mat.isDoubleSided = false
        mat.metalness.contents = 0.0
        mat.roughness.contents = 0.94

        // Force a sane base green; ignore any vertex-colour/albedo path.
        mat.diffuse.contents = UIColor(red: 0.32, green: 0.62, blue: 0.34, alpha: 1.0)
        mat.multiply.contents = nil
        mat.normal.contents = nil
        mat.emission.contents = nil

        // Procedural micro-detail + shoreline wetness (texture-free).
        let surfaceMod = """
        #pragma arguments
        float u_heightScale;
        float u_waterLevelN;
        float u_grassIntensity;
        float u_waterBlue;
        float u_detailFreq;
        float u_normalStrength;

        float hash2(float2 p){ return fract(sin(dot(p, float2(127.1,311.7))) * 43758.5453123); }
        float noise2(float2 p){
            float2 i = floor(p);
            float2 f = fract(p);
            float a = hash2(i);
            float b = hash2(i + float2(1.0,0.0));
            float c = hash2(i + float2(0.0,1.0));
            float d = hash2(i + float2(1.0,1.0));
            float2 u = f*f*(3.0-2.0*f);
            return mix(a,b,u.x) + (c-a)*u.y*(1.0-u.x) + (d-b)*u.x*u.y;
        }

        #pragma body
        float hN = clamp(_worldPosition.y / max(0.0001, u_heightScale), 0.0, 1.0);

        // Small colour jitter so it isn't carpet-flat.
        float n1 = noise2(_worldPosition.xz * u_detailFreq);
        float n2 = noise2(_worldPosition.xz * (u_detailFreq*1.87) + 17.0);
        float jitter = (n1 * 0.65 + n2 * 0.35) * 2.0 - 1.0;
        _surface.diffuse.rgb *= (1.0 + u_grassIntensity * jitter * 0.035);

        // Subtle fake normal perturbation from noise gradient.
        float e = 0.006;
        float h = noise2(_worldPosition.xz * u_detailFreq);
        float hx = noise2((_worldPosition.xz + float2(e,0.0)) * u_detailFreq) - h;
        float hz = noise2((_worldPosition.xz + float2(0.0,e)) * u_detailFreq) - h;
        float3 n = normalize(_surface.normal + float3(-hx * u_normalStrength, 0.0, -hz * u_normalStrength));
        _surface.normal = n;

        // Wet edge near water; slight foam.
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
        mat.setValue(0.85 as CGFloat,          forKey: "u_grassIntensity")
        mat.setValue(0.55 as CGFloat,          forKey: "u_waterBlue")
        mat.setValue(0.35 as CGFloat,          forKey: "u_detailFreq")
        mat.setValue(1.5  as CGFloat,          forKey: "u_normalStrength")

        geom.materials = [mat]
        node.geometry = geom
        node.castsShadow = true
        return node
    }
}
