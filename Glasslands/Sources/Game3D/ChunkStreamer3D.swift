//
//  ChunkStreamer3D.swift
//  Glasslands
//
//  Created by . . on 9/30/25.
//
//  treams terrain chunks around the player.
//  Swift 6–safe: all SceneKit on MainActor; heavy mesh generation in an actor.
//

//  ChunkStreamer3D.swift
//  Glasslands
//
//  Streams terrain chunks around the player.
//  Swift 6–safe: all SceneKit on MainActor; heavy mesh generation in an actor.

@preconcurrency import SceneKit
import GameplayKit
import simd

@MainActor
final class ChunkStreamer3D {

    private let cfg: FirstPersonEngine.Config
    private let noise: NoiseFields
    private let recipe: BiomeRecipe

    private weak var root: SCNNode?
    private let renderer: SCNSceneRenderer

    private let builder: ChunkMeshBuilder

    private var loaded: [IVec2: SCNNode] = [:]
    private var desired: Set<IVec2> = []
    private var pending: Set<IVec2> = []
    private var queued: [IVec2] = []

    private let beaconSink: ([SCNNode]) -> Void
    private let obstacleSink: (IVec2, [SCNNode]) -> Void
    private let onChunkRemoved: (IVec2) -> Void

    var tasksPerFrame: Int = 2

    init(
        cfg: FirstPersonEngine.Config,
        noise: NoiseFields,
        recipe: BiomeRecipe,
        root: SCNNode,
        renderer: SCNSceneRenderer,
        beaconSink: @escaping ([SCNNode]) -> Void,
        obstacleSink: @escaping (IVec2, [SCNNode]) -> Void,
        onChunkRemoved: @escaping (IVec2) -> Void
    ) {
        self.cfg = cfg
        self.noise = noise
        self.recipe = recipe
        self.root = root
        self.renderer = renderer
        self.beaconSink = beaconSink
        self.obstacleSink = obstacleSink
        self.onChunkRemoved = onChunkRemoved
        self.builder = ChunkMeshBuilder(cfg: cfg, noise: noise, recipe: recipe)
    }

    func warmupCenter(at center: simd_float3) {
        guard let root else { return }
        let ci = chunkIndex(forWorldX: center.x, z: center.z)
        let key = IVec2(ci.x, ci.y)
        guard loaded[key] == nil else { return }

        let sp = Signposts.begin("BuildChunk")
        let node = TerrainChunkNode.makeNode(originChunk: key, cfg: cfg, noise: noise, recipe: recipe)
        root.addChildNode(node)
        loaded[key] = node
        Signposts.end("BuildChunk", sp)
    }

    func updateVisible(center: simd_float3) {
        guard root != nil else { return }

        let ci = chunkIndex(forWorldX: center.x, z: center.z)
        var keep = Set<IVec2>()
        var toStage: [IVec2] = []

        for dy in -cfg.preloadRadius...cfg.preloadRadius {
            for dx in -cfg.preloadRadius...cfg.preloadRadius {
                let k = IVec2(ci.x + dx, ci.y + dy)
                keep.insert(k)
                if loaded[k] == nil, !pending.contains(k), !queued.contains(k) {
                    toStage.append(k)
                }
            }
        }

        for (k, n) in loaded where !keep.contains(k) {
            n.removeAllActions()
            n.removeFromParentNode()
            loaded.removeValue(forKey: k)
            onChunkRemoved(k)
        }

        desired = keep

        if !toStage.isEmpty {
            toStage.sort { priority(of: $0, around: ci) < priority(of: $1, around: ci) }
            let slice = toStage.prefix(max(1, tasksPerFrame))
            for k in slice {
                queued.append(k)
                pending.insert(k)
                enqueueBuild(k)
            }
            if slice.count < toStage.count {
                queued.append(contentsOf: toStage.dropFirst(slice.count))
            }
        }

        if !queued.isEmpty {
            queued.removeAll { !keep.contains($0) || loaded[$0] != nil || pending.contains($0) }
        }
    }

    // MARK: - Private

    private func enqueueBuild(_ k: IVec2) {
        let ox = k.x, oy = k.y

        Task { [weak self] in
            guard let self = self else { return }

            // Off-main heavy mesh build
            let data = await self.builder.build(originChunkX: ox, originChunkY: oy)

            guard let root = self.root else { self.pending.remove(k); return }
            let key = IVec2(ox, oy)
            guard self.desired.contains(key) else { self.pending.remove(key); return }

            let node = TerrainChunkNode.node(from: data)
            await self.prepareAsync([node])

            guard self.desired.contains(key) else { self.pending.remove(key); return }

            root.addChildNode(node)
            self.loaded[key] = node

            let beacons = BeaconPlacer3D.place(inChunk: key, cfg: self.cfg, noise: self.noise, recipe: self.recipe)
            beacons.forEach { node.addChildNode($0) }
            self.beaconSink(beacons)

            let veg = VegetationPlacer3D.place(inChunk: key, cfg: self.cfg, noise: self.noise, recipe: self.recipe)
            veg.forEach { node.addChildNode($0) }
            self.obstacleSink(key, veg + beacons)

            self.pending.remove(key)
        }
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

    private func prepareAsync(_ objects: [Any]) async {
        await withCheckedContinuation { cont in
            renderer.prepare(objects) { _ in cont.resume() }
        }
    }
}

// MARK: - Background mesh builder (actor)

actor ChunkMeshBuilder {
    private let cfg: FirstPersonEngine.Config
    private let noise: NoiseFields
    private let recipe: BiomeRecipe

    init(cfg: FirstPersonEngine.Config, noise: NoiseFields, recipe: BiomeRecipe) {
        self.cfg = cfg
        self.noise = noise
        self.recipe = recipe
    }

    func build(originChunkX: Int, originChunkY: Int) -> TerrainChunkData {
        // IMPORTANT: use the pure builder, not TerrainChunkNode.makeData (which is main-actor inferred)
        TerrainMeshBuilder.makeData(
            originChunkX: originChunkX,
            originChunkY: originChunkY,
            cfg: cfg,
            noise: noise,
            recipe: recipe
        )
    }
}
