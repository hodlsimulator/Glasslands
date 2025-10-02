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
import Dispatch

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
        // Use the background actor but wait once (no double-wait).
        let actor = ChunkMeshBuilder(tilesX: tilesX, tilesZ: tilesZ, tileSize: tileSize, heightScale: heightScale, recipe: recipe)
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
