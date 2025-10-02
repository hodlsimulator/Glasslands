//
//  TerrainMeshBuilder.swift
//  Glasslands
//
//  Created by . . on 10/2/25.
//
//  Pure, Sendable terrain mesh data builder (no SceneKit/UIKit).
//  Returns TerrainChunkData and includes edge “skirts” to seal gaps.
//

import simd
import Dispatch   // FIX: for DispatchSemaphore

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
        let actor = ChunkMeshBuilder(tilesX: tilesX, tilesZ: tilesZ, tileSize: tileSize, heightScale: heightScale, recipe: recipe)
        let sem = DispatchSemaphore(value: 1)
        sem.wait()
        var out: TerrainChunkData?
        Task {
            out = await actor.build(originChunkX: originChunkX, originChunkY: originChunkY)
            sem.signal()
        }
        sem.wait()
        return out!
    }
}
