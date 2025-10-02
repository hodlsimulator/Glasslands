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
import GameplayKit
import simd

@MainActor
final class ChunkStreamer3D {

    private let cfg: FirstPersonEngine.Config
    private let recipe: BiomeRecipe

    private weak var root: SCNNode?
    private let renderer: SCNSceneRenderer

    // Background builder does NOT capture cfg/noise/types tied to MainActor.
    private let builder: ChunkMeshBuilder

    // Live scene state (main-actor only).
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
        noise: NoiseFields,                         // kept for warmup only
        recipe: BiomeRecipe,
        root: SCNNode,
        renderer: SCNSceneRenderer,
        beaconSink: @escaping ([SCNNode]) -> Void,
        obstacleSink: @escaping (IVec2, [SCNNode]) -> Void,
        onChunkRemoved: @escaping (IVec2) -> Void
    ) {
        self.cfg = cfg
        self.recipe = recipe
        self.root = root
        self.renderer = renderer
        self.beaconSink = beaconSink
        self.obstacleSink = obstacleSink
        self.onChunkRemoved = onChunkRemoved

        // Pass ONLY primitives/value types into the actor.
        self.builder = ChunkMeshBuilder(
            tilesX: cfg.tilesX,
            tilesZ: cfg.tilesZ,
            tileSize: cfg.tileSize,
            heightScale: cfg.heightScale,
            recipe: recipe
        )

        // We keep `noise` only to build the single warmup node on main below.
        _ = noise
    }

    /// Build just the centre chunk immediately so the renderer has real geometry.
    func warmupCenter(at center: simd_float3) {
        guard let root else { return }
        let ci = chunkIndex(forWorldX: center.x, z: center.z)
        let key = IVec2(ci.x, ci.y)
        guard loaded[key] == nil else { return }

        let sp = Signposts.begin("BuildChunk")
        // Warmup path uses synchronous main-actor construction for one chunk.
        let node = TerrainChunkNode.makeNode(originChunk: key, cfg: cfg, noise: NoiseFields(recipe: recipe), recipe: recipe)
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
        // Snapshot coords so no main-actor types cross to the actor.
        let ox = k.x, oy = k.y

        Task { [weak self] in
            guard let self = self else { return }

            // Heavy work off the main thread inside the actor.
            let data = await self.builder.build(originChunkX: ox, originChunkY: oy)

            // Back on main: proceed only if still desired.
            guard let root = self.root else { self.pending.remove(k); return }
            let key = IVec2(ox, oy)
            guard self.desired.contains(key) else { self.pending.remove(key); return }

            let node = TerrainChunkNode.node(from: data)
            await self.prepareAsync([node])

            guard self.desired.contains(key) else { self.pending.remove(key); return }

            root.addChildNode(node)
            self.loaded[key] = node

            // Populate beacons/vegetation on main (they return SCNNodes).
            let beacons = BeaconPlacer3D.place(inChunk: key, cfg: self.cfg, noise: NoiseFields(recipe: self.recipe), recipe: self.recipe)
            beacons.forEach { node.addChildNode($0) }
            self.beaconSink(beacons)

            let veg = VegetationPlacer3D.place(inChunk: key, cfg: self.cfg, noise: NoiseFields(recipe: self.recipe), recipe: self.recipe)
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

    // Async wrapper so we don't capture SceneKit types in a completion.
    private func prepareAsync(_ objects: [Any]) async {
        await withCheckedContinuation { cont in
            renderer.prepare(objects) { _ in cont.resume() }
        }
    }
}

// MARK: - Background mesh builder (actor)
// Pure math only. No SceneKit, no TerrainMath, no NoiseFields, no FirstPersonEngine.Config.

actor ChunkMeshBuilder {
    private let tilesX: Int
    private let tilesZ: Int
    private let tileSize: Float
    private let heightScale: Float
    private let recipe: BiomeRecipe

    // Local GKNoise sampler that lives entirely inside the actor.
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

        @inline(__always)
        func vi(_ x: Int, _ z: Int) -> Int { z * vertsX + x }

        var positions = [SIMD3<Float>](repeating: .zero, count: vertsX * vertsZ)
        var normals   = [SIMD3<Float>](repeating: .zero, count: vertsX * vertsZ)
        var colors    = [SIMD4<Float>](repeating: SIMD4<Float>(1,1,1,1), count: vertsX * vertsZ)
        var uvs       = [SIMD2<Float>](repeating: .zero, count: vertsX * vertsZ)

        let palette = HeightClassifier(recipe: recipe)

        for z in 0..<vertsZ {
            for x in 0..<vertsX {
                let tx = originTileX + x
                let tz = originTileZ + z

                let wX = Float(tx) * tileSize
                let wZ = Float(tz) * tileSize
                let hT = sampler.sampleHeight(Double(tx), Double(tz))        // 0..ampH in tile coords
                let wY = Float(hT) * heightScale

                let idx = vi(x, z)
                positions[idx] = SIMD3(wX, wY, wZ)

                // Smooth normal from central differences (tile coords → world Y via heightScale)
                let hL = sampler.sampleHeight(Double(tx - 1), Double(tz))
                let hR = sampler.sampleHeight(Double(tx + 1), Double(tz))
                let hD = sampler.sampleHeight(Double(tx), Double(tz - 1))
                let hU = sampler.sampleHeight(Double(tx), Double(tz + 1))
                let tX = SIMD3<Float>(tileSize, Float(hR - hL) * heightScale, 0)
                let tZ = SIMD3<Float>(0,        Float(hU - hD) * heightScale, tileSize)
                normals[idx] = simd_normalize(simd_cross(tZ, tX))

                // Colour classification inputs
                let hN   = Float(sampler.heightNorm(Double(tx), Double(tz), ampH: recipe.height.amplitude))
                let slope = Float(sampler.slope(Double(tx), Double(tz)))
                let river = Float(sampler.riverMask(Double(tx), Double(tz)))
                let moist = Float(sampler.sampleMoisture(Double(tx), Double(tz)) / max(0.0001, recipe.moisture.amplitude))
                colors[idx] = palette.color(yNorm: hN, slope: slope, riverMask: river, moisture01: moist)

                // Simple world-space UVs for small detail texture
                let detailScale: Float = 1.0 / (tileSize * 2.0)
                uvs[idx] = SIMD2(wX * detailScale, wZ * detailScale)
            }
        }

        var indices: [UInt32] = []
        indices.reserveCapacity(tilesX * tilesZ * 6)
        for z in 0..<tilesZ {
            for x in 0..<tilesX {
                let a = UInt32(vi(x,     z))
                let b = UInt32(vi(x + 1, z))
                let c = UInt32(vi(x,     z + 1))
                let d = UInt32(vi(x + 1, z + 1))
                indices.append(contentsOf: [a, b, c, b, d, c])
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

    // MARK: - Private helpers inside the actor

    private struct HeightClassifier {
        let deep  = SIMD4<Float>(0.18, 0.42, 0.58, 1.0)
        let shore = SIMD4<Float>(0.55, 0.80, 0.88, 1.0)
        let grass = SIMD4<Float>(0.32, 0.62, 0.34, 1.0)
        let sand  = SIMD4<Float>(0.92, 0.87, 0.68, 1.0)
        let rock  = SIMD4<Float>(0.90, 0.92, 0.95, 1.0)

        let deepCut: Float = 0.22
        let shoreCut: Float = 0.30
        let sandCut:  Float = 0.33
        let snowCut:  Float = 0.88

        let recipe: BiomeRecipe

        func color(yNorm y: Float, slope s: Float, riverMask r: Float, moisture01 m: Float) -> SIMD4<Float> {
            if y < deepCut { return deep }
            if y < shoreCut || r > 0.60 { return shore }
            if s > 0.55 || y > snowCut { return rock }
            if y < sandCut { return sand }
            let t = max(0, min(1, m * 0.65 + r * 0.20))
            return mix(grass, SIMD4<Float>(0.40, 0.75, 0.38, 1.0), t)
        }

        @inline(__always)
        private func mix(_ a: SIMD4<Float>, _ b: SIMD4<Float>, _ t: Float) -> SIMD4<Float> { a + (b - a) * t }
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

            self.height   = GKNoise(makeSource(recipe.height))
            self.moisture = GKNoise(makeSource(recipe.moisture, seed: 101))
            self.riverBase = GKNoise(GKRidgedNoiseSource(frequency: 1.0, octaveCount: 5, lacunarity: 2.0, seed: baseSeed32 &+ 202))
            self.warpX    = GKNoise(GKPerlinNoiseSource(frequency: 1.0, octaveCount: 3, persistence: 0.5, lacunarity: 2.0, seed: baseSeed32 &+ 303))
            self.warpY    = GKNoise(GKPerlinNoiseSource(frequency: 1.0, octaveCount: 3, persistence: 0.5, lacunarity: 2.0, seed: baseSeed32 &+ 404))

            self.ampH = recipe.height.amplitude
            self.ampM = recipe.moisture.amplitude
            // Match the broader world scales used in NoiseFields.swift
            self.scaleH = max(20.0, recipe.height.scale * 12.0)
            self.scaleM = max(10.0, recipe.moisture.scale * 8.0)
            self.scaleR = max(12.0, scaleH * 0.85)
            self.warpScale = 12.0
            self.warpAmp   = 0.15 / scaleH
        }

        @inline(__always) private func n01(_ v: Double) -> Double { (v * 0.5) + 0.5 }

        private func warp(_ x: Double, _ y: Double) -> (Double, Double) {
            let wx = Double(warpX.value(atPosition: vector_float2(Float(x/warpScale), Float(y/warpScale))))
            let wy = Double(warpY.value(atPosition: vector_float2(Float((x+1234)/warpScale), Float((y-987)/warpScale))))
            return (x + wx * warpAmp, y + wy * warpAmp)
        }

        // Smoothed height sample in 0..ampH (tile coordinates)
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

        // Moisture sample in 0..ampM
        func sampleMoisture(_ x: Double, _ y: Double) -> Double {
            let (u, v) = warp(x, y)
            let m = Double(moisture.value(atPosition: vector_float2(Float(u/scaleM), Float(v/scaleM))))
            return n01(m) * ampM
        }

        // 0..1 river mask (1 = river core)
        func riverMask(_ x: Double, _ y: Double) -> Double {
            let (u, v) = warp(x, y)
            let r = Double(riverBase.value(atPosition: vector_float2(Float(u/scaleR), Float(v/scaleR))))
            let valley = 1.0 - n01(r)
            let t = max(0.0, valley - 0.40) / 0.60
            return pow(t, 2.2)
        }

        // Approximate slope magnitude (height-units per tile)
        func slope(_ x: Double, _ y: Double) -> Double {
            let s = 0.75
            let c = sampleHeight(x, y)
            let dx = sampleHeight(x + s, y) - c
            let dy = sampleHeight(x, y + s) - c
            return sqrt(dx*dx + dy*dy)
        }

        // Normalised height 0..1 after river carve (divide by ampH)
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
