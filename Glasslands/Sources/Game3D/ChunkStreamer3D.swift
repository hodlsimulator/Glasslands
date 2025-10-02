//
//  ChunkStreamer3D.swift
//  Glasslands
//
//  Created by . . on 9/30/25.
//
//  Streams terrain chunks and populates beacons and vegetation.
//  Now also reports obstacles per chunk for collision.
//

import SceneKit
import GameplayKit
import simd

final class ChunkStreamer3D {
    private let cfg: FirstPersonEngine.Config
    private let noise: NoiseFields
    private let recipe: BiomeRecipe
    private weak var root: SCNNode?

    private var loaded: [IVec2: SCNNode] = [:]
    private var desired: Set<IVec2> = []

    private enum Phase { case build, beacons, vegetation, done }
    private struct Rec {
        var node: SCNNode?
        var phase: Phase
        var beacons: [SCNNode]      // stored to include in obstacle sink
    }
    private var recs: [IVec2: Rec] = [:]

    private var queue: [IVec2] = []
    private var queued: Set<IVec2> = []

    private let beaconSink: ([SCNNode]) -> Void
    private let obstacleSink: (IVec2, [SCNNode]) -> Void
    private let onChunkRemoved: (IVec2) -> Void

    var tasksPerFrame: Int = 2

    init(
        cfg: FirstPersonEngine.Config,
        noise: NoiseFields,
        recipe: BiomeRecipe,
        root: SCNNode,
        beaconSink: @escaping ([SCNNode]) -> Void,
        obstacleSink: @escaping (IVec2, [SCNNode]) -> Void,
        onChunkRemoved: @escaping (IVec2) -> Void
    ) {
        self.cfg = cfg
        self.noise = noise
        self.recipe = recipe
        self.root = root
        self.beaconSink = beaconSink
        self.obstacleSink = obstacleSink
        self.onChunkRemoved = onChunkRemoved
    }

    func buildAround(_ center: simd_float3) {
        updateVisible(center: center)
    }

    /// Build just the centre chunk immediately (to warm pipelines before gameplay).
    func warmupCenter(at center: simd_float3) {
        guard let root else { return }
        let ci = chunkIndex(forWorldX: center.x, z: center.z)
        let k = IVec2(ci.x, ci.y)
        guard loaded[k] == nil else { return }

        let sp = Signposts.begin("BuildChunk")
        let node = TerrainChunkNode.makeNode(originChunk: k, cfg: cfg, noise: noise, recipe: recipe)
        root.addChildNode(node)
        loaded[k] = node
        recs[k] = Rec(node: node, phase: .done, beacons: [])
        Signposts.end("BuildChunk", sp)
    }

    func updateVisible(center: simd_float3) {
        guard let root else { return }

        let ci = chunkIndex(forWorldX: center.x, z: center.z)

        var keep = Set<IVec2>()
        var toStage: [IVec2] = []

        for dy in -cfg.preloadRadius...cfg.preloadRadius {
            for dx in -cfg.preloadRadius...cfg.preloadRadius {
                let k = IVec2(ci.x + dx, ci.y + dy)
                keep.insert(k)
                if recs[k] == nil, loaded[k] == nil {
                    recs[k] = Rec(node: nil, phase: .build, beacons: [])
                    toStage.append(k)
                }
            }
        }

        for (k, n) in loaded where !keep.contains(k) {
            n.removeAllActions()
            n.removeFromParentNode()
            loaded.removeValue(forKey: k)
            recs.removeValue(forKey: k)
            onChunkRemoved(k)
        }

        if !queue.isEmpty {
            var newQ: [IVec2] = []
            newQ.reserveCapacity(queue.count)
            for k in queue where keep.contains(k) { newQ.append(k) }
            queue = newQ
            queued = Set(newQ)
        }
        if !toStage.isEmpty {
            toStage.sort { priority(of: $0, around: ci) < priority(of: $1, around: ci) }
            for k in toStage { queue.append(k); queued.insert(k) }
        }

        desired = keep

        var tasks = 0
        while tasks < tasksPerFrame, !queue.isEmpty {
            let k = queue.removeFirst()
            queued.remove(k)
            guard desired.contains(k), var rec = recs[k] else { continue }

            switch rec.phase {
            case .build:
                let sp = Signposts.begin("BuildChunk")
                let node = TerrainChunkNode.makeNode(originChunk: k, cfg: cfg, noise: noise, recipe: recipe)
                root.addChildNode(node)
                rec.node = node
                Signposts.end("BuildChunk", sp)
                rec.phase = .beacons
                enqueueIfNeeded(k)

            case .beacons:
                if let node = rec.node {
                    Signposts.event("PlaceBeacons")
                    let beacons = BeaconPlacer3D.place(inChunk: k, cfg: cfg, noise: noise, recipe: recipe)
                    beacons.forEach { node.addChildNode($0) }
                    beaconSink(beacons)
                    rec.beacons = beacons          // keep for obstacle sink next phase
                }
                rec.phase = .vegetation
                enqueueIfNeeded(k)

            case .vegetation:
                if let node = rec.node {
                    Signposts.event("PlaceVegetation")
                    let veg = VegetationPlacer3D.place(inChunk: k, cfg: cfg, noise: noise, recipe: recipe)
                    veg.forEach { node.addChildNode($0) }
                    obstacleSink(k, veg + rec.beacons)
                }
                rec.phase = .done
                if let node = rec.node { loaded[k] = node }

            case .done:
                break
            }

            recs[k] = rec
            tasks += 1
        }
    }

    private func enqueueIfNeeded(_ k: IVec2) {
        guard desired.contains(k), !queued.contains(k) else { return }
        queue.append(k); queued.insert(k)
    }

    private func chunkIndex(forWorldX x: Float, z: Float) -> IVec2 {
        let tX = Int(floor(Double(x) / Double(cfg.tileSize)))
        let tZ = Int(floor(Double(z) / Double(cfg.tileSize)))
        return IVec2(floorDiv(tX, cfg.tilesX), floorDiv(tZ, cfg.tilesZ))
    }

    private func floorDiv(_ a: Int, _ b: Int) -> Int {
        a >= 0 ? a / b : ((a + 1) / b - 1)
    }

    private func priority(of k: IVec2, around c: IVec2) -> Int {
        let dx = k.x - c.x
        let dy = k.y - c.y
        return dx &* dx &+ dy &* dy
    }
}
