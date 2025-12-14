//
//  ChunkStreamer3D.swift
//  Glasslands
//
//  Created by . . on 9/30/25.
//
//  Streams terrain chunks around the player.
//  Swift 6–safe: all SceneKit on MainActor; heavy mesh generation in an actor.
//

import SceneKit
import Metal

@MainActor
final class ChunkStreamer3D {

    // MARK: - Types

    typealias BeaconSink = ([SCNNode]) -> Void
    typealias ObstacleSink = (IVec2, [SCNNode]) -> Void
    typealias ChunkRemovedCallback = (IVec2) -> Void

    // MARK: - State

    private weak var root: SCNNode?
    private let cfg: FirstPersonEngine.Config
    private let noise: NoiseFields
    private let recipe: BiomeRecipe
    private let renderer: SCNSceneRenderer
    private let builder = ChunkMeshBuilder()

    private let beaconSink: BeaconSink
    private let obstacleSink: ObstacleSink
    private let onChunkRemoved: ChunkRemovedCallback

    private var loaded: [IVec2: SCNNode] = [:]
    private var desired: Set<IVec2> = []
    private var pending: Set<IVec2> = []
    private var queued: [IVec2] = []

    // Decorations are relatively expensive (lots of small nodes/materials). To avoid hitches when
    // multiple chunks complete in the same moment, we time-slice decoration generation/attachment
    // through a single worker queue.
    private var decorationQueue: [IVec2] = []
    private var decorationQueued: Set<IVec2> = []
    private var decorated: Set<IVec2> = []
    private var decorationWorker: Task<Void, Never>?

    // MARK: - Init

    init(root: SCNNode,
         cfg: FirstPersonEngine.Config,
         noise: NoiseFields,
         recipe: BiomeRecipe,
         renderer: SCNSceneRenderer,
         beaconSink: @escaping BeaconSink,
         obstacleSink: @escaping ObstacleSink,
         onChunkRemoved: @escaping ChunkRemovedCallback)
    {
        self.root = root
        self.cfg = cfg
        self.noise = noise
        self.recipe = recipe
        self.renderer = renderer
        self.beaconSink = beaconSink
        self.obstacleSink = obstacleSink
        self.onChunkRemoved = onChunkRemoved
    }

    // MARK: - Public

    func clearAll() {
        for (_, n) in loaded {
            n.removeAllActions()
            n.removeFromParentNode()
        }
        loaded.removeAll()
        desired.removeAll()
        pending.removeAll()
        queued.removeAll()

        decorationQueue.removeAll()
        decorationQueued.removeAll()
        decorated.removeAll()
        decorationWorker?.cancel()
        decorationWorker = nil
    }

    func updateVisible(center worldPos: simd_float3) {
        guard let root else { return }

        let centreChunk = chunkIndex(fromWorld: worldPos)
        let r = cfg.preloadRadius

        // Desired ring.
        var keep: Set<IVec2> = []
        keep.reserveCapacity((2*r + 1) * (2*r + 1))

        for dy in -r...r {
            for dx in -r...r {
                let k = IVec2(centreChunk.x + dx, centreChunk.y + dy)
                keep.insert(k)
            }
        }
        desired = keep

        // Unload anything well outside the ring.
        let m = max(cfg.preloadRadius, cfg.unloadRadius)
        var keepWithMargin: Set<IVec2> = []
        keepWithMargin.reserveCapacity((2*m + 1) * (2*m + 1))
        for dy in -m...m {
            for dx in -m...m {
                let k = IVec2(centreChunk.x + dx, centreChunk.y + dy)
                keepWithMargin.insert(k)
            }
        }

        for (k, n) in loaded where !keepWithMargin.contains(k) {
            n.removeAllActions()
            n.removeFromParentNode()
            loaded.removeValue(forKey: k)
            removeDecorationState(for: k)
            onChunkRemoved(k)
        }

        // Stage new chunks.
        let toStage = keep
            .filter { loaded[$0] == nil && !pending.contains($0) && !queued.contains($0) }
            .sorted { priority(of: $0, around: centreChunk) < priority(of: $1, around: centreChunk) }

        let maxStage = max(0, cfg.tasksPerFrame)
        for k in toStage.prefix(maxStage) {
            queued.append(k)
            enqueueBuild(k, around: centreChunk, root: root)
        }
    }

    // Builds the centre chunk immediately. Use sparingly.
    func warmupCenter(at worldPos: simd_float3) {
        guard let root else { return }
        let sp = Signposts.begin("BuildChunk")

        let centreChunk = chunkIndex(fromWorld: worldPos)
        let key = centreChunk

        // Build terrain synchronously so there’s no visible void.
        let data = TerrainMeshBuilder.makeData(originChunk: key, cfg: cfg, noise: noise, recipe: recipe)
        let node = TerrainChunkNode.node(from: data)
        root.addChildNode(node)
        loaded[key] = node
        enqueueDecoration(for: key)
        Signposts.end("BuildChunk", sp)
    }

    func warmupInitial(at worldPos: simd_float3, radius: Int) {
        guard let root else { return }
        let centreChunk = chunkIndex(fromWorld: worldPos)

        for dy in -radius...radius {
            for dx in -radius...radius {
                let key = IVec2(centreChunk.x + dx, centreChunk.y + dy)

                if loaded[key] != nil { continue }

                // Terrain synchronously to avoid a blank frame at launch.
                let data = TerrainMeshBuilder.makeData(originChunk: key, cfg: cfg, noise: noise, recipe: recipe)
                let terrainNode = TerrainChunkNode.node(from: data)
                root.addChildNode(terrainNode)
                loaded[key] = terrainNode

                // Decorations are queued and time-sliced to avoid launch hitches.
                enqueueDecoration(for: key)
            }
        }
    }

    // MARK: - Private

    private func enqueueBuild(_ key: IVec2, around centre: IVec2, root: SCNNode) {
        guard !pending.contains(key) else { return }
        pending.insert(key)

        // Inherit @MainActor from the class (DO NOT use Task.detached here).
        // Use .utility so chunk streaming work doesn't fight the renderer for CPU.
        Task(priority: .utility) { [weak self] in
            guard let self else { return }
            defer {
                self.pending.remove(key)
                if let idx = self.queued.firstIndex(of: key) { self.queued.remove(at: idx) }
            }

            // If it’s no longer desired by the time build completes, skip attaching entirely.
            // (Avoids wasted work when moving quickly.)
            if !self.desired.contains(key) {
                return
            }

            // Build mesh data off-main via actor.
            let data = await self.builder.build(originChunk: key, cfg: self.cfg, noise: self.noise, recipe: self.recipe)

            // Create node on main.
            let terrainNode = TerrainChunkNode.node(from: data)

            // Prepare only the terrain to reduce first-draw stutters (cheap compared to preparing everything).
            await self.prepareAsync([terrainNode])

            // Replace if present.
            if let existing = self.loaded[key] {
                existing.removeAllActions()
                existing.removeFromParentNode()
                self.loaded.removeValue(forKey: key)
                self.removeDecorationState(for: key)
                self.onChunkRemoved(key)
            }

            root.addChildNode(terrainNode)
            self.loaded[key] = terrainNode

            // Queue decorations separately (time-sliced worker).
            self.enqueueDecoration(for: key)
        }
    }

    private func priority(of k: IVec2, around c: IVec2) -> Int {
        let dx = k.x - c.x
        let dy = k.y - c.y
        return dx &* dx &+ dy &* dy
    }

    private func enqueueDecoration(for key: IVec2) {
        guard loaded[key] != nil else { return }
        guard !decorated.contains(key), !decorationQueued.contains(key) else { return }

        decorationQueue.append(key)
        decorationQueued.insert(key)
        startDecorationWorkerIfNeeded()
    }

    private func removeDecorationState(for key: IVec2) {
        decorated.remove(key)
        decorationQueued.remove(key)
        decorationQueue.removeAll { $0 == key }
    }

    private func startDecorationWorkerIfNeeded() {
        guard decorationWorker == nil else { return }

        decorationWorker = Task(priority: .utility) { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                guard let key = self.dequeueNextDecorationKey() else { break }
                await self.buildDecorations(for: key)
                await Task.yield()
            }

            self.decorationWorker = nil
        }
    }

    private func dequeueNextDecorationKey() -> IVec2? {
        while !decorationQueue.isEmpty {
            let key = decorationQueue.removeFirst()
            decorationQueued.remove(key)

            if decorated.contains(key) { continue }
            if loaded[key] == nil { continue }

            // Prefer decorating chunks that are still in the desired ring.
            // If it’s only in the unload margin, deprioritise by pushing it back once.
            if !desired.contains(key) {
                decorationQueue.append(key)
                decorationQueued.insert(key)
                // Avoid infinite cycling if only margin chunks remain.
                if decorationQueue.count > 1 {
                    continue
                }
            }

            return key
        }
        return nil
    }

    private func buildDecorations(for key: IVec2) async {
        guard let terrainNode = loaded[key] else { return }
        guard !decorated.contains(key) else { return }

        // Generate on main (SceneKit + UIKit work).
        let beacons = BeaconPlacer3D.place(inChunk: key, cfg: cfg, noise: noise, recipe: recipe)
        if Task.isCancelled { return }

        let veg = VegetationPlacer3D.place(inChunk: key, cfg: cfg, noise: noise, recipe: recipe)
        if Task.isCancelled { return }

        // Give the renderer/input loop a chance to breathe before the heaviest step.
        await Task.yield()

        // Scenery is the heaviest chunk-decoration step; time-sliced via placeAsync.
        let scenery = await SceneryPlacer3D.placeAsync(
            inChunk: key,
            cfg: cfg,
            noise: noise,
            recipe: recipe,
            frameBudgetSeconds: 0.0020
        )
        if Task.isCancelled { return }

        // Chunk might have been removed/replaced while yielding.
        guard let current = loaded[key], current === terrainNode else { return }

        // Attach nodes with small yields to keep frames smooth.
        for (i, n) in beacons.enumerated() {
            if Task.isCancelled { return }
            terrainNode.addChildNode(n)
            if i & 0x07 == 0 { await Task.yield() }
        }

        for (i, n) in veg.enumerated() {
            if Task.isCancelled { return }
            terrainNode.addChildNode(n)
            if i & 0x07 == 0 { await Task.yield() }
        }

        for (i, n) in scenery.enumerated() {
            if Task.isCancelled { return }
            terrainNode.addChildNode(n)
            if i & 0x07 == 0 { await Task.yield() }
        }

        // Only mark complete after everything is attached + sinks are notified.
        decorated.insert(key)
        beaconSink(beacons)
        obstacleSink(key, veg + beacons + scenery)
    }

    private func prepareAsync(_ objects: [Any]) async {
        await withCheckedContinuation { cont in
            renderer.prepare(objects) { _ in
                cont.resume()
            }
        }
    }

    private func chunkIndex(fromWorld p: simd_float3) -> IVec2 {
        let cs = Float(cfg.tileSize) * Float(cfg.tilesX)
        let ix = Int(floor(p.x / cs))
        let iz = Int(floor(p.z / cs))
        return IVec2(ix, iz)
    }
}

// MARK: - Chunk mesh builder actor

actor ChunkMeshBuilder {
    func build(originChunk: IVec2,
               cfg: FirstPersonEngine.Config,
               noise: NoiseFields,
               recipe: BiomeRecipe) -> TerrainChunkData
    {
        let sp = Signposts.begin("BuildChunkData")

        let tilesX = cfg.tilesX
        let tilesZ = cfg.tilesZ
        let tileSize = Float(cfg.tileSize)

        let originTileX = originChunk.x * tilesX
        let originTileZ = originChunk.y * tilesZ

        let detailScale = SceneKitHelpers.grassRepeatsPerTile()
        let heightAmp = Float(cfg.heightScale)
        let ampH = heightAmp
        let ampM = 1.0 as Float

        let sampler = NoiseSampler(noise: noise, recipe: recipe)

        // Grid vertices (tilesX+1)*(tilesZ+1)
        let vxCount = tilesX + 1
        let vzCount = tilesZ + 1
        let vCount = vxCount * vzCount

        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []

        positions.reserveCapacity(vCount + (tilesX + tilesZ) * 2 + 4 * 2)
        normals.reserveCapacity(vCount + (tilesX + tilesZ) * 2 + 4 * 2)
        uvs.reserveCapacity(vCount + (tilesX + tilesZ) * 2 + 4 * 2)

        // Sample heights into a buffer for normal computation.
        var heights: [Float] = Array(repeating: 0, count: vCount)

        func vi(_ x: Int, _ z: Int) -> Int { z * vxCount + x }

        for z in 0...tilesZ {
            for x in 0...tilesX {
                let tx = originTileX + x
                let tz = originTileZ + z
                var hN = sampler.heightNorm(tx, tz, ampH)

                // Apply river carving so mesh matches TerrainMath.heightWorld.
                let r = sampler.riverMask(tx, tz, ampM)
                if r > 0.55 {
                    let t = min(1.0, (r - 0.55) / 0.25)
                    hN *= (1.0 - 0.6 * t)
                }

                let h = hN * 1.0 // already scaled by ampH
                heights[vi(x, z)] = h

                let wx = (Float(originTileX + x) * tileSize)
                let wz = (Float(originTileZ + z) * tileSize)
                positions.append(SIMD3<Float>(wx, h, wz))

                // UV in tile space (for repeatable grass texture).
                uvs.append(SIMD2<Float>(Float(tx) * detailScale, Float(tz) * detailScale))
            }
        }

        // Normals: finite differences from heights.
        for z in 0...tilesZ {
            for x in 0...tilesX {
                let xm = max(0, x - 1)
                let xp = min(tilesX, x + 1)
                let zm = max(0, z - 1)
                let zp = min(tilesZ, z + 1)

                let hx0 = heights[vi(xm, z)]
                let hx1 = heights[vi(xp, z)]
                let hz0 = heights[vi(x, zm)]
                let hz1 = heights[vi(x, zp)]

                let dx = (hx0 - hx1) / (Float(xp - xm) * tileSize)
                let dz = (hz0 - hz1) / (Float(zp - zm) * tileSize)

                let n = simd_normalize(SIMD3<Float>(dx, 2.0, dz))
                normals.append(n)
            }
        }

        // Indices for two triangles per tile.
        var indices: [UInt32] = []
        indices.reserveCapacity(tilesX * tilesZ * 6)

        for z in 0..<tilesZ {
            for x in 0..<tilesX {
                let i0 = UInt32(vi(x, z))
                let i1 = UInt32(vi(x + 1, z))
                let i2 = UInt32(vi(x, z + 1))
                let i3 = UInt32(vi(x + 1, z + 1))

                // Diagonal from (x+1,z) to (x,z+1)
                indices.append(i0); indices.append(i2); indices.append(i1)
                indices.append(i1); indices.append(i2); indices.append(i3)
            }
        }

        // Skirt to hide seams between chunks (downwards extrusion).
        let skirtDepth: Float = -8.0

        func addSkirtVertex(from baseIndex: Int) -> Int {
            let p = positions[baseIndex]
            positions.append(SIMD3<Float>(p.x, p.y + skirtDepth, p.z))
            normals.append(SIMD3<Float>(0, 1, 0))
            uvs.append(uvs[baseIndex])
            return positions.count - 1
        }

        func addSkirtQuadsAlongEdge(_ edge: [(Int, Int)]) {
            for (a, b) in edge {
                let a0 = a
                let b0 = b
                let a1 = addSkirtVertex(from: a0)
                let b1 = addSkirtVertex(from: b0)

                let ia0 = UInt32(a0)
                let ib0 = UInt32(b0)
                let ia1 = UInt32(a1)
                let ib1 = UInt32(b1)

                // Two triangles for the quad.
                indices.append(ia0); indices.append(ib0); indices.append(ia1)
                indices.append(ia1); indices.append(ib0); indices.append(ib1)
            }
        }

        // Edge vertex pairs.
        var top: [(Int, Int)] = []
        var bottom: [(Int, Int)] = []
        var left: [(Int, Int)] = []
        var right: [(Int, Int)] = []

        top.reserveCapacity(tilesX)
        bottom.reserveCapacity(tilesX)
        left.reserveCapacity(tilesZ)
        right.reserveCapacity(tilesZ)

        for x in 0..<tilesX {
            top.append((vi(x, 0), vi(x + 1, 0)))
            bottom.append((vi(x, tilesZ), vi(x + 1, tilesZ)))
        }
        for z in 0..<tilesZ {
            left.append((vi(0, z), vi(0, z + 1)))
            right.append((vi(tilesX, z), vi(tilesX, z + 1)))
        }

        addSkirtQuadsAlongEdge(top)
        addSkirtQuadsAlongEdge(bottom)
        addSkirtQuadsAlongEdge(left)
        addSkirtQuadsAlongEdge(right)

        let out = TerrainChunkData(
            originChunk: originChunk,
            tilesX: tilesX,
            tilesZ: tilesZ,
            tileSize: cfg.tileSize,
            positions: positions,
            normals: normals,
            uvs: uvs,
            indices: indices
        )

        Signposts.end("BuildChunkData", sp)
        return out
    }
}
