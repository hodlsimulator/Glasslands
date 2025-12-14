//
//  ChunkStreamer3D.swift
//  Glasslands
//
//  Created by . . on 9/30/25.
//
//  Streams terrain chunks around the player.
//  Swift 6–safe: all SceneKit on MainActor; heavy mesh generation in an actor.
//

@preconcurrency import SceneKit
@preconcurrency import GameplayKit
import simd

@MainActor
final class ChunkStreamer3D {
    private let cfg: FirstPersonEngine.Config
    private let recipe: BiomeRecipe
    private let noise: NoiseFields
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

    var tasksPerFrame: Int = 1   // was 3

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
        self.recipe = recipe
        self.noise = noise
        self.root = root
        self.renderer = renderer
        self.beaconSink = beaconSink
        self.obstacleSink = obstacleSink
        self.onChunkRemoved = onChunkRemoved

        self.builder = ChunkMeshBuilder(
            tilesX: cfg.tilesX,
            tilesZ: cfg.tilesZ,
            tileSize: cfg.tileSize,
            heightScale: cfg.heightScale,
            recipe: recipe
        )
    }

    // Build centre chunk immediately so there’s never a hole underfoot.
    func warmupCenter(at center: simd_float3) {
        guard let root else { return }
        let ci = chunkIndex(forWorldX: center.x, z: center.z)
        let key = IVec2(ci.x, ci.y)
        guard loaded[key] == nil else { return }

        let sp = Signposts.begin("BuildChunk")
        let data = TerrainMeshBuilder.makeData(
            originChunkX: key.x,
            originChunkY: key.y,
            tilesX: cfg.tilesX,
            tilesZ: cfg.tilesZ,
            tileSize: cfg.tileSize,
            heightScale: cfg.heightScale,
            noise: noise,
            recipe: recipe
        )
        let node = TerrainChunkNode.node(from: data)
        root.addChildNode(node)
        loaded[key] = node
        Signposts.end("BuildChunk", sp)
    }

    func updateVisible(center: simd_float3) {
        guard root != nil else { return }

        let ci = chunkIndex(forWorldX: center.x, z: center.z)

        // Target set for this frame.
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

        // Keep old chunks around longer so movement doesn’t expose voids.
        let unloadRadius = cfg.preloadRadius + 3
        var keepWithMargin = Set<IVec2>()
        for dy in -unloadRadius...unloadRadius {
            for dx in -unloadRadius...unloadRadius {
                keepWithMargin.insert(IVec2(ci.x + dx, ci.y + dy))
            }
        }

        // Unload anything well outside the ring.
        for (k, n) in loaded where !keepWithMargin.contains(k) {
            n.removeAllActions()
            n.removeFromParentNode()
            loaded.removeValue(forKey: k)
            onChunkRemoved(k)
        }

        // Prioritise closest first.
        toStage.sort { priority(of: $0, around: ci) < priority(of: $1, around: ci) }

        // Launch new builds up to the per-frame budget.
        var launched = 0
        while launched < tasksPerFrame, let k = toStage.first {
            toStage.removeFirst()
            queued.append(k)
            pending.insert(k)
            enqueueBuild(k)
            launched += 1
        }

        // Top-up from the backlog in the same frame if there’s budget left.
        if launched < tasksPerFrame, !queued.isEmpty {
            var i = 0
            while launched < tasksPerFrame, i < queued.count {
                let k = queued[i]
                if keep.contains(k), loaded[k] == nil, !pending.contains(k) {
                    pending.insert(k)
                    enqueueBuild(k)
                    queued.remove(at: i)
                    launched += 1
                } else {
                    i += 1
                }
            }
        }

        // Prune satisfied/stale backlog entries.
        if !queued.isEmpty {
            queued.removeAll { loaded[$0] != nil || !keepWithMargin.contains($0) }
        }

        desired = keep // diagnostic only
    }

    // MARK: - Private

    private func enqueueBuild(_ k: IVec2) {
        let ox = k.x, oy = k.y

        // Inherit @MainActor from the class (DO NOT use Task.detached here).
        Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            let key = IVec2(ox, oy)
            defer { self.pending.remove(key) }

            // Mesh generation happens off-main inside the builder actor.
            let data = await self.builder.build(originChunkX: ox, originChunkY: oy)

            // Scene may have gone away.
            guard let root = self.root else { return }

            // Create terrain on main.
            let terrainNode = TerrainChunkNode.node(from: data)

            // Pre-warm ONLY terrain to avoid long main-thread stalls.
            await self.prepareAsync([terrainNode])

            // Replace any existing node atomically.
            if let existing = self.loaded.removeValue(forKey: key) {
                existing.removeAllActions()
                existing.removeFromParentNode()
                self.onChunkRemoved(key)
            }

            // Attach terrain first so there’s never a visible hole.
            root.addChildNode(terrainNode)
            self.loaded[key] = terrainNode

            // Decorations on main; small yields keep UI fluid.
            let beacons = BeaconPlacer3D.place(inChunk: key, cfg: self.cfg, noise: self.noise, recipe: self.recipe)
            let veg     = VegetationPlacer3D.place(inChunk: key, cfg: self.cfg, noise: self.noise, recipe: self.recipe)
            let scenery = SceneryPlacer3D.place(inChunk: key, cfg: self.cfg, noise: self.noise, recipe: self.recipe)

            for (i, n) in beacons.enumerated() {
                terrainNode.addChildNode(n)
                if i & 0x0F == 0 { await Task.yield() }
            }
            for (i, n) in veg.enumerated() {
                terrainNode.addChildNode(n)
                if i & 0x0F == 0 { await Task.yield() }
            }
            for (i, n) in scenery.enumerated() {
                terrainNode.addChildNode(n)
                if i & 0x0F == 0 { await Task.yield() }
            }

            self.beaconSink(beacons)
            self.obstacleSink(key, veg + beacons + scenery)
        }
    }

    private func chunkIndex(forWorldX x: Float, z: Float) -> IVec2 {
        let tX = Int(floor(Double(x) / Double(cfg.tileSize)))
        let tZ = Int(floor(Double(z) / Double(cfg.tileSize)))
        return IVec2(floorDiv(tX, cfg.tilesX), floorDiv(tZ, cfg.tilesZ))
    }

    private func floorDiv(_ a: Int, _ b: Int) -> Int { a >= 0 ? a / b : ((a + 1) / b - 1) }

    private func priority(of k: IVec2, around c: IVec2) -> Int {
        let dx = k.x - c.x
        let dy = k.y - c.y
        return dx &* dx &+ dy &* dy
    }

    @MainActor
    private func prepareAsync(_ objects: [Any]) async {
        guard !objects.isEmpty else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            renderer.prepare(objects) { _ in
                cont.resume()
            }
        }
    }
    
    @MainActor
    func warmupInitial(at center: simd_float3, radius: Int = 1) {
        guard let root else { return }
        let ci = chunkIndex(forWorldX: center.x, z: center.z)

        for dy in -radius...radius {
            for dx in -radius...radius {
                let key = IVec2(ci.x + dx, ci.y + dy)
                guard loaded[key] == nil else { continue }

                // Build terrain synchronously so there’s no visible void
                let data = TerrainMeshBuilder.makeData(
                    originChunkX: key.x, originChunkY: key.y,
                    tilesX: cfg.tilesX, tilesZ: cfg.tilesZ,
                    tileSize: cfg.tileSize, heightScale: cfg.heightScale,
                    noise: noise, recipe: recipe
                )
                let terrainNode = TerrainChunkNode.node(from: data)
                root.addChildNode(terrainNode)
                loaded[key] = terrainNode

                // Place set-pieces, vegetation, and scenery so centre area feels complete
                let beacons = BeaconPlacer3D.place(inChunk: key, cfg: cfg, noise: noise, recipe: recipe)
                let veg     = VegetationPlacer3D.place(inChunk: key, cfg: cfg, noise: noise, recipe: recipe)
                let scenery = SceneryPlacer3D.place(inChunk: key, cfg: cfg, noise: noise, recipe: recipe)

                beacons.forEach { terrainNode.addChildNode($0) }
                veg.forEach     { terrainNode.addChildNode($0) }
                scenery.forEach { terrainNode.addChildNode($0) }

                beaconSink(beacons)
                obstacleSink(key, veg + beacons + scenery)
            }
        }
    }
}

// MARK: - Background mesh builder (actor) — pure math only, with skirts and stitched UVs.

actor ChunkMeshBuilder {
    private let tilesX: Int
    private let tilesZ: Int
    private let tileSize: Float
    private let heightScale: Float
    private let recipe: BiomeRecipe
    private let sampler: NoiseSampler

    init(tilesX: Int, tilesZ: Int, tileSize: Float, heightScale: Float, recipe: BiomeRecipe) {
        self.tilesX = tilesX
        self.tilesZ = tilesZ
        self.tileSize = tileSize
        self.heightScale = heightScale
        self.recipe = recipe
        self.sampler = NoiseSampler(recipe: recipe)
    }

    func build(originChunkX: Int, originChunkY: Int) -> TerrainChunkData {
        let vertsX = tilesX + 1
        let vertsZ = tilesZ + 1

        let originTileX = originChunkX * tilesX
        let originTileZ = originChunkY * tilesZ

        @inline(__always) func vi(_ x: Int, _ z: Int) -> Int { z * vertsX + x }

        var positions = [SIMD3<Float>](repeating: .zero, count: vertsX * vertsZ)
        var normals   = [SIMD3<Float>](repeating: .zero, count: vertsX * vertsZ)
        var colors    = [SIMD4<Float>](repeating: SIMD4(1, 1, 1, 1), count: vertsX * vertsZ)
        var uvs       = [SIMD2<Float>](repeating: .zero, count: vertsX * vertsZ)

        // Pre-sample base heights for the vertex grid + a 1-tile border so:
        // - central-difference normals don't require extra noise samples per vertex
        // - border normals remain seamless across chunk boundaries
        let extX = vertsX + 2
        let extZ = vertsZ + 2
        @inline(__always) func evi(_ x: Int, _ z: Int) -> Int { z * extX + x }

        var baseHeights = [Double](repeating: 0, count: extX * extZ)
        for ez in 0..<extZ {
            for ex in 0..<extX {
                let tx = originTileX + ex - 1
                let tz = originTileZ + ez - 1
                baseHeights[evi(ex, ez)] = sampler.sampleHeight(Double(tx), Double(tz))
            }
        }

        let ampH = max(0.0001, recipe.height.amplitude)

        for z in 0..<vertsZ {
            for x in 0..<vertsX {
                let tx = originTileX + x
                let tz = originTileZ + z

                let wX = Float(tx) * tileSize
                let wZ = Float(tz) * tileSize

                let ex = x + 1
                let ez = z + 1
                let base = baseHeights[evi(ex, ez)]

                // Apply river carving to match TerrainMath.heightN / NoiseSampler.heightNorm.
                var h = base
                let r = sampler.riverMask(Double(tx), Double(tz))
                if r > 0.55 {
                    let t = min(1.0, (r - 0.55) / 0.45)
                    h *= (1.0 - 0.35 * t)
                }

                let hN = Float(h / ampH)
                let y  = hN * heightScale

                let idx = vi(x, z)
                positions[idx] = SIMD3(wX, y, wZ)

                // Central-difference normal across global tile coords (seamless at chunk borders).
                let hL = baseHeights[evi(ex - 1, ez)]
                let hR = baseHeights[evi(ex + 1, ez)]
                let hD = baseHeights[evi(ex, ez - 1)]
                let hU = baseHeights[evi(ex, ez + 1)]
                let tXv = SIMD3(tileSize, Float(hR - hL) * heightScale, 0)
                let tZv = SIMD3(0, Float(hU - hD) * heightScale, tileSize)
                normals[idx] = simd_normalize(simd_cross(tZv, tXv))

                // Vertex colours are not used by the current terrain material/shader path.
                // Keep them neutral (future-proofing without extra noise sampling).
                colors[idx] = SIMD4(1, 1, 1, 1)

                // World-space UVs so detail texture is continuous across chunks.
                // Increased frequency to reduce visible square tiling.
                let detailScale: Float = 1.0 / (tileSize * 8.0)
                uvs[idx] = SIMD2(wX * detailScale, wZ * detailScale)
            }
        }

        // Top surface indices
        var indices: [UInt32] = []
        indices.reserveCapacity(tilesX * tilesZ * 6)
        for z in 0..<tilesZ {
            for x in 0..<tilesX {
                let i0 = UInt32(vi(x,     z))
                let i1 = UInt32(vi(x + 1, z))
                let i2 = UInt32(vi(x,     z + 1))
                let i3 = UInt32(vi(x + 1, z + 1))
                indices.append(contentsOf: [i0, i2, i1,  i1, i2, i3])
            }
        }

        // Edge skirts to hide sub-pixel cracks between chunks
        let skirtDepth: Float = 0.20
        var bottomIndex: [Int: Int] = [:]

        @inline(__always)
        func bottomOf(_ x: Int, _ z: Int, normalHint n: SIMD3<Float>) -> Int {
            let top = vi(x, z)
            if let id = bottomIndex[top] { return id }
            let p = positions[top]
            positions.append(SIMD3(p.x, p.y - skirtDepth, p.z))
            normals.append(n)
            colors.append(colors[top])
            uvs.append(uvs[top])
            let id = positions.count - 1
            bottomIndex[top] = id
            return id
        }

        // North edge
        if vertsZ > 1 {
            let n = SIMD3<Float>(0, 0, -1)
            for x in 0..<vertsX {
                let topA = vi(x, 0)
                let topB = vi(max(0, x-1), 0)
                let botA = bottomOf(x, 0, normalHint: n)
                let botB = bottomOf(max(0, x-1), 0, normalHint: n)
                indices.append(contentsOf: [UInt32(topB), UInt32(botB), UInt32(topA),
                                            UInt32(topA), UInt32(botB), UInt32(botA)])
            }
        }
        // South edge
        if vertsZ > 1 {
            let n = SIMD3<Float>(0, 0, 1)
            let z = vertsZ - 1
            for x in 0..<vertsX {
                let topA = vi(x, z)
                let topB = vi(max(0, x-1), z)
                let botA = bottomOf(x, z, normalHint: n)
                let botB = bottomOf(max(0, x-1), z, normalHint: n)
                indices.append(contentsOf: [UInt32(topA), UInt32(botB), UInt32(topB),
                                            UInt32(topA), UInt32(botA), UInt32(botB)])
            }
        }
        // West edge
        if vertsX > 1 {
            let n = SIMD3<Float>(-1, 0, 0)
            for z in 0..<vertsZ {
                let topA = vi(0, z)
                let topB = vi(0, max(0, z-1))
                let botA = bottomOf(0, z, normalHint: n)
                let botB = bottomOf(0, max(0, z-1), normalHint: n)
                indices.append(contentsOf: [UInt32(topB), UInt32(botB), UInt32(topA),
                                            UInt32(topA), UInt32(botB), UInt32(botA)])
            }
        }
        // East edge
        if vertsX > 1 {
            let n = SIMD3<Float>(1, 0, 0)
            let x = vertsX - 1
            for z in 0..<vertsZ {
                let topA = vi(x, z)
                let topB = vi(x, max(0, z-1))
                let botA = bottomOf(x, z, normalHint: n)
                let botB = bottomOf(x, max(0, z-1), normalHint: n)
                indices.append(contentsOf: [UInt32(topA), UInt32(botB), UInt32(topB),
                                            UInt32(topA), UInt32(botA), UInt32(botB)])
            }
        }

        return TerrainChunkData(
            originChunkX: originChunkX,
            originChunkY: originChunkY,
            tilesX: tilesX,
            tilesZ: tilesZ,
            tileSize: tileSize,
            positions: positions,
            normals: normals,
            colors: colors,
            uvs: uvs,
            indices: indices
        )
    }

    // Colour classifier used by the mesh builder
    private struct HeightClassifier {
        let deep  = SIMD4<Float>(0.18, 0.42, 0.58, 1.0)
        let shore = SIMD4<Float>(0.55, 0.80, 0.88, 1.0)
        let grass = SIMD4<Float>(0.32, 0.62, 0.34, 1.0)
        let sand  = SIMD4<Float>(0.92, 0.87, 0.68, 1.0)
        let rock  = SIMD4<Float>(0.90, 0.92, 0.95, 1.0)

        let deepCut:  Float = 0.22
        let shoreCut: Float = 0.30
        let sandCut:  Float = 0.33
        let snowCut:  Float = 0.88

        init(recipe: BiomeRecipe) { _ = recipe }

        @inline(__always) private func mix(_ a: SIMD4<Float>, _ b: SIMD4<Float>, _ t: Float) -> SIMD4<Float> {
            a + (b - a) * t
        }

        func color(yNorm y: Float, slope s: Float, riverMask r: Float, moisture01 m: Float) -> SIMD4<Float> {
            if y < deepCut { return deep }
            if y < shoreCut || r > 0.60 { return shore }
            if s > 0.55 || y > snowCut { return rock }
            if y < sandCut { return sand }
            let t = max(0, min(1, m * 0.65 + r * 0.20))
            return mix(grass, SIMD4<Float>(0.40, 0.75, 0.38, 1.0), t)
        }
    }

    // GKNoise-based sampler living wholly inside the actor.
    private final class NoiseSampler {
        private let height: GKNoise
        private let moisture: GKNoise
        private let riverBase: GKNoise
        private let warpX: GKNoise
        private let warpY: GKNoise

        private let ampH: Double
        private let ampM: Double
        private let scaleH: Double
        private let scaleM: Double
        private let scaleR: Double
        private let warpScale: Double
        private let warpAmp: Double

        init(recipe: BiomeRecipe) {
            let baseSeed32: Int32 = Int32(truncatingIfNeeded: recipe.seed64)

            func makeSource(_ p: NoiseParams, seed salt: Int32 = 0) -> GKNoiseSource {
                let s = baseSeed32 &+ salt
                switch p.base.lowercased() {
                case "ridged": return GKRidgedNoiseSource(frequency: 1.0, octaveCount: max(1, p.octaves), lacunarity: 2.0, seed: s)
                case "billow": return GKBillowNoiseSource(frequency: 1.0, octaveCount: max(1, p.octaves), persistence: 0.5, lacunarity: 2.0, seed: s)
                default:       return GKPerlinNoiseSource(frequency: 1.0, octaveCount: max(1, p.octaves), persistence: 0.55, lacunarity: 2.2, seed: s)
                }
            }

            self.height = GKNoise(makeSource(recipe.height))
            self.moisture = GKNoise(makeSource(recipe.moisture, seed: 101))
            self.riverBase = GKNoise(GKRidgedNoiseSource(frequency: 1.0, octaveCount: 5, lacunarity: 2.0, seed: baseSeed32 &+ 202))
            self.warpX = GKNoise(GKPerlinNoiseSource(frequency: 1.0, octaveCount: 3, persistence: 0.5, lacunarity: 2.0, seed: baseSeed32 &+ 303))
            self.warpY = GKNoise(GKPerlinNoiseSource(frequency: 1.0, octaveCount: 3, persistence: 0.5, lacunarity: 2.0, seed: baseSeed32 &+ 404))

            self.ampH = recipe.height.amplitude
            self.ampM = recipe.moisture.amplitude

            self.scaleH = max(20.0, recipe.height.scale * 12.0)
            self.scaleM = max(10.0, recipe.moisture.scale * 8.0)
            self.scaleR = max(12.0, scaleH * 0.85)

            self.warpScale = 12.0
            self.warpAmp = 0.15 / scaleH
        }

        @inline(__always) private func n01(_ v: Double) -> Double { (v * 0.5) + 0.5 }

        private func warp(_ x: Double, _ y: Double) -> (Double, Double) {
            let wx = Double(warpX.value(atPosition: vector_float2(Float(x/warpScale), Float(y/warpScale))))
            let wy = Double(warpY.value(atPosition: vector_float2(Float((x+1234)/warpScale), Float((y-987)/warpScale))))
            return (x + wx * warpAmp, y + wy * warpAmp)
        }

        func sampleHeight(_ x: Double, _ y: Double) -> Double {
            let (u, v) = warp(x, y)
            let v0 = Double(height.value(atPosition: vector_float2(Float(u/scaleH), Float(v/scaleH))))
            let v1 = Double(height.value(atPosition: vector_float2(Float((u+0.73)/scaleH), Float((v-0.42)/scaleH))))
            let v2 = Double(height.value(atPosition: vector_float2(Float((u-0.61)/scaleH), Float((v+0.37)/scaleH))))
            let v3 = Double(height.value(atPosition: vector_float2(Float((u+0.21)/scaleH), Float((v+0.58)/scaleH))))
            let hRaw = (v0 * 0.46 + v1 * 0.24 + v2 * 0.18 + v3 * 0.12)
            let h = pow(n01(hRaw), 1.35)
            return h * ampH
        }

        func sampleMoisture(_ x: Double, _ y: Double) -> Double {
            let (u, v) = warp(x, y)
            let m = Double(moisture.value(atPosition: vector_float2(Float(u/scaleM), Float(v/scaleM))))
            return n01(m) * ampM
        }

        func riverMask(_ x: Double, _ y: Double) -> Double {
            let (u, v) = warp(x, y)
            let r = Double(riverBase.value(atPosition: vector_float2(Float(u/scaleR), Float(v/scaleR))))
            let valley = 1.0 - n01(r)
            let t = max(0.0, valley - 0.40) / 0.60
            return pow(t, 2.2)
        }

        func slope(_ x: Double, _ y: Double) -> Double {
            let s = 0.75
            let c = sampleHeight(x, y)
            let dx = sampleHeight(x + s, y) - c
            let dy = sampleHeight(x, y + s) - c
            return sqrt(dx*dx + dy*dy)
        }

        func heightNorm(_ x: Double, _ y: Double, ampH: Double) -> Double {
            var h = sampleHeight(x, y)
            let r = riverMask(x, y)
            if r > 0.55 {
                let t = min(1.0, (r - 0.55) / 0.45)
                h *= (1.0 - 0.35 * t)
            }
            return h / max(0.0001, ampH)
        }
    }
}
