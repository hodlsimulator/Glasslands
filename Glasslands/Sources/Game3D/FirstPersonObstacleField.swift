//
//  FirstPersonObstacleField.swift
//  Glasslands
//
//  Created by . . on 10/4/25.
//

import Foundation
import SceneKit
import simd

struct Obstacle: Sendable {
    var centreXZ: SIMD2<Float>
    var radius: Float
}

struct ChunkKey: Hashable {
    let x: Int
    let y: Int
}

final class FirstPersonObstacleField {
    private let cfg: FirstPersonEngine.Config
    private var byChunk: [ChunkKey: [Obstacle]] = [:]

    init(cfg: FirstPersonEngine.Config) {
        self.cfg = cfg
    }

    func clear() {
        byChunk.removeAll(keepingCapacity: true)
    }

    func setObstacles(for chunk: ChunkKey, from nodes: [SCNNode]) {
        var obs: [Obstacle] = []
        obs.reserveCapacity(nodes.count)
        for n in nodes {
            let w = n.worldPosition
            let r = (n.value(forKey: "hitRadius") as? CGFloat).map { Float($0) } ?? 0.18
            obs.append(Obstacle(centreXZ: SIMD2(Float(w.x), Float(w.z)), radius: r))
        }
        byChunk[chunk] = obs
    }

    func removeChunk(_ chunk: ChunkKey) {
        byChunk.removeValue(forKey: chunk)
    }

    // Neighbourhood query using chunk ring around the player.
    func nearby(to world: SIMD3<Float>, within maxDistance: Float) -> [Obstacle] {
        let (cx, cy) = chunkIndex(forWorldX: world.x, z: world.z)
        var out: [Obstacle] = []
        let r = cfg.preloadRadius + 1
        for dy in -r...r {
            for dx in -r...r {
                if let arr = byChunk[ChunkKey(x: cx + dx, y: cy + dy)] {
                    out.append(contentsOf: arr)
                }
            }
        }
        if maxDistance.isFinite {
            let md2 = maxDistance * maxDistance
            out.removeAll { obs in
                let dx = obs.centreXZ.x - world.x
                let dz = obs.centreXZ.y - world.z
                return (dx*dx + dz*dz) > md2
            }
        }
        return out
    }

    // Same chunking as the streamer.
    private func chunkIndex(forWorldX x: Float, z: Float) -> (Int, Int) {
        let tX = Int(floor(Double(x) / Double(cfg.tileSize)))
        let tZ = Int(floor(Double(z) / Double(cfg.tileSize)))
        func floorDiv(_ a: Int, _ b: Int) -> Int { a >= 0 ? a / b : ((a + 1) / b - 1) }
        return (floorDiv(tX, cfg.tilesX), floorDiv(tZ, cfg.tilesZ))
    }
}
