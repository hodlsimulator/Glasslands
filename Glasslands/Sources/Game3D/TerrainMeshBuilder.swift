//
//  TerrainMeshBuilder.swift
//  Glasslands
//
//  Created by . . on 10/2/25.
//
//  Pure, Sendable terrain mesh data builder (no SceneKit/UIKit).
//  Returns TerrainChunkData and includes edge “skirts” to seal gaps.
//

// Glasslands/Sources/Game3D/TerrainMeshBuilder.swift

import simd

enum TerrainMeshBuilder {
    static func makeData(
        originChunkX: Int,
        originChunkY: Int,
        tilesX: Int,
        tilesZ: Int,
        tileSize: Float,
        heightScale: Float,
        noise: NoiseFields,
        recipe: BiomeRecipe
    ) -> TerrainChunkData {
        // Thin wrapper calling the same maths as the background actor so centre warmup matches neighbours.
        let actor = ChunkMeshBuilder(tilesX: tilesX, tilesZ: tilesZ, tileSize: tileSize, heightScale: heightScale, recipe: recipe)
        // Note: quick synchronous hop to the actor. This builds on the current thread.
        let sem = DispatchSemaphore(value: 0)
        var out: TerrainChunkData?
        Task {
            out = await actor.build(originChunkX: originChunkX, originChunkY: originChunkY)
            sem.signal()
        }
        sem.wait()
        return out!
    }
}
