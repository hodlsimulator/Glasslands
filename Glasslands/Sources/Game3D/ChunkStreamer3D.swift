//
//  ChunkStreamer3D.swift
//  Glasslands
//
//  Created by . . on 9/30/25.
//

import SceneKit
import GameplayKit

final class ChunkStreamer3D {
    private let cfg: FirstPersonEngine.Config
    private let noise: NoiseFields
    private let recipe: BiomeRecipe
    private weak var root: SCNNode?
    private var loaded: [IVec2: SCNNode] = [:]
    private let beaconSink: ([SCNNode]) -> Void

    init(cfg: FirstPersonEngine.Config,
         noise: NoiseFields,
         recipe: BiomeRecipe,
         root: SCNNode,
         beaconSink: @escaping ([SCNNode]) -> Void) {
        self.cfg = cfg; self.noise = noise; self.recipe = recipe; self.root = root; self.beaconSink = beaconSink
    }

    func buildAround(_ center: SIMD3<Float>) { updateVisible(center: center) }

    func updateVisible(center: SIMD3<Float>) {
        guard let root else { return }
        let ci = chunkIndex(forWorldX: center.x, z: center.z)
        var keep = Set<IVec2>()

        for dy in -cfg.preloadRadius...cfg.preloadRadius {
            for dx in -cfg.preloadRadius...cfg.preloadRadius {
                let k = IVec2(ci.x + dx, ci.y + dy)
                keep.insert(k)
                if loaded[k] == nil {
                    let node = TerrainChunkNode.makeNode(originChunk: k, cfg: cfg, noise: noise, recipe: recipe)
                    root.addChildNode(node)
                    loaded[k] = node

                    // Populate beacons + vegetation as children of the chunk node.
                    let beacons = BeaconPlacer3D.place(inChunk: k, cfg: cfg, noise: noise, recipe: recipe)
                    beacons.forEach { node.addChildNode($0) }
                    beaconSink(beacons)

                    let veg = VegetationPlacer3D.place(inChunk: k, cfg: cfg, noise: noise, recipe: recipe)
                    veg.forEach { node.addChildNode($0) }
                }
            }
        }

        for (k, n) in loaded where !keep.contains(k) {
            n.removeAllActions()
            n.removeFromParentNode()
            loaded.removeValue(forKey: k)
        }
    }

    private func chunkIndex(forWorldX x: Float, z: Float) -> IVec2 {
        let tX = Int(floor(Double(x) / Double(cfg.tileSize)))
        let tZ = Int(floor(Double(z) / Double(cfg.tileSize)))
        return IVec2(floorDiv(tX, cfg.tilesX), floorDiv(tZ, cfg.tilesZ))
    }

    private func floorDiv(_ a: Int, _ b: Int) -> Int { a >= 0 ? a / b : ((a + 1) / b - 1) }
}
