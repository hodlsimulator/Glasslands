//
//  FirstPersonEngine.swift
//  Glasslands
//
//  Created by . . on 9/30/25.
//

import SceneKit
import GameplayKit
import simd
import UIKit
import CoreGraphics
import QuartzCore

final class FirstPersonEngine: NSObject {

    // MARK: - Configuration

    struct Config {
        let tileSize: Float = 16.0
        let heightScale: Float = 24.0
        let chunkTiles = IVec2(64, 64)
        let preloadRadius: Int = 2
        let moveSpeed: Float = 6.0
        let eyeHeight: Float = 1.62
        let playerRadius: Float = 0.34
        let maxDescentRate: Float = 8.0
        let skyDistance: Float = 4600
        let swipeYawDegPerPt: Float = 0.22
        let swipePitchDegPerPt: Float = 0.18
        var tilesX: Int { chunkTiles.x }
        var tilesZ: Int { chunkTiles.y }
    }

    let cfg = Config()

    // MARK: - Scene / world

    var scene = SCNScene()
    weak var scnView: SCNView?
    var recipe: BiomeRecipe!
    var noise: NoiseFields!
    var chunker: ChunkStreamer3D!

    // Camera rig
    let yawNode = SCNNode()
    let pitchNode = SCNNode()
    let camNode = SCNNode()

    // Movement / input
    var moveInput: SIMD2<Float> = .zero
    var pendingLookDeltaPts: SIMD2<Float> = .zero
    var yaw: Float = 0
    var pitch: Float = -0.1

    // Sky + sun
    let skyAnchor = SCNNode()
    var sunDiscNode: SCNNode?
    var sunLightNode: SCNNode?
    var vegSunLightNode: SCNNode?
    var sunDirWorld: simd_float3 = simd_float3(0, 1, 0)

    // Cloud lighting parameters
    let cloudSunTint = simd_float3(1.00, 0.94, 0.82)
    let cloudSunBacklight: CGFloat = 0.45
    let cloudHorizonFade: CGFloat = 0.20

    // Cloud motion / formation (per-session)
    var cloudSeed: UInt32 = 0
    var cloudInitialYaw: Float = 0
    var cloudSpinAccum: Float = 0
    var cloudSpinRate: Float = 0.0034906586   // 12°/min in rad/s
    var cloudWind: simd_float2 = simd_float2(0.60, 0.20)
    var cloudDomainOffset: simd_float2 = simd_float2(0, 0)

    // Billboard caches and wind state
    var cloudBillboardNodes: [SCNNode] = []          // puff parents with SCNBillboardConstraint (used by sun diffusion)
    var cloudClusterGroups: [SCNNode] = []           // each cluster root (group) under CumulusBillboardLayer
    var cloudClusterCentroidLocal: [ObjectIdentifier: simd_float3] = [:] // per-cluster local centroid at build time

    var cloudRMin: Float = 1
    var cloudRMax: Float = 1
    var cloudWrapMargin: Float = 600                 // how far beyond the rim to recycle along the wind axis
    var cloudLayerNode: SCNNode?   // reference to the CumulusBillboardLayer root


    // Frame timing
    var lastTime: TimeInterval = 0

    // Gameplay
    var beacons = Set<SCNNode>()
    var score = 0
    var onScore: (Int) -> Void

    // Obstacles (by chunk)
    struct Obstacle {
        weak var node: SCNNode?
        let position: SIMD2<Float>
        let radius: Float
    }
    var obstaclesByChunk: [IVec2: [Obstacle]] = [:]

    // MARK: - Init

    init(onScore: @escaping (Int) -> Void) {
        self.onScore = onScore
        super.init()
    }

    // MARK: - Public API

    @MainActor
    func attach(to view: SCNView, recipe: BiomeRecipe) {
        scnView = view
        view.scene = scene
        view.antialiasingMode = .none
        view.isJitteringEnabled = false
        view.preferredFramesPerSecond = 60
        view.rendersContinuously = true
        view.isPlaying = true
        view.isOpaque = true

        if let metal = view.layer as? CAMetalLayer {
            metal.isOpaque = true
            metal.wantsExtendedDynamicRangeContent = true
            metal.colorspace = CGColorSpace(name: CGColorSpace.extendedSRGB)
            metal.pixelFormat = .bgra10_xr_srgb
            metal.maximumDrawableCount = 3
        }

        scene.physicsWorld.gravity = SCNVector3(0, 0, 0)

        buildLighting()
        buildSky()
        apply(recipe: recipe, force: true)

        // Remove billboards completely (no 2D shapes).
        removeCloudBillboards()
        enableVolumetricCloudImpostors(false)

        // Keep only the true volumetric vapour, tuned for scattered cumulus.
        self.useScatteredVolumetricCumulus(
            coverage: 0.36,
            densityMul: 1.05,
            stepMul: 0.82,
            horizonLift: 0.10,
            detailMul: 0.90,
            puffScale: 0.0048,
            puffStrength: 0.62,
            macroScale: 0.00040,
            macroThreshold: 0.62
        )
    }

    func setPaused(_ paused: Bool) { scnView?.isPlaying = !paused }
    func setMoveInput(_ v: SIMD2<Float>) { moveInput = v }
    func setLookRate(_ _: SIMD2<Float>) { }
    func applyLookDelta(points: SIMD2<Float>) { pendingLookDeltaPts += points }

    func apply(recipe: BiomeRecipe, force: Bool = false) {
        if !force, let r = self.recipe, r == recipe { return }
        self.recipe = recipe
        noise = NoiseFields(recipe: recipe)
        resetWorld()
    }

    @MainActor
    func snapshot() -> UIImage? { scnView?.snapshot() }

    // MARK: - Per-frame

    @MainActor
    func stepUpdateMain(at t: TimeInterval) {
        let sp = Signposts.begin("Frame"); defer { Signposts.end("Frame", sp) }

        // Timing (avoid zero-dt double-calls from multiple tickers)
        let rawDt = (lastTime == 0) ? 1/60 : max(0, t - lastTime)
        let dt: Float = Float(min(1/30, max(1/240, rawDt)))
        lastTime = t

        // Look
        if pendingLookDeltaPts != .zero {
            let yawRadPerPt = cfg.swipeYawDegPerPt * (Float.pi / 180)
            let pitchRadPerPt = cfg.swipePitchDegPerPt * (Float.pi / 180)
            yaw   -= pendingLookDeltaPts.x * yawRadPerPt
            pitch -= pendingLookDeltaPts.y * pitchRadPerPt
            pendingLookDeltaPts = .zero
            clampAngles()
        }

        // Camera rig
        updateRig()

        // Movement
        let forward = SIMD3(-sinf(yaw), 0, -cosf(yaw))
        let right   = SIMD3( cosf(yaw), 0, -sinf(yaw))
        let moveVec = (right * moveInput.x) + (forward * moveInput.y)
        let attemptedDelta = moveVec * (cfg.moveSpeed * dt)
        var next = yawNode.simdPosition + attemptedDelta

        // Height follow + descent cap
        let groundY = groundHeightFootprint(worldX: next.x, z: next.z)
        let targetY = groundY + cfg.eyeHeight
        if !targetY.isFinite {
            next = spawn().simd
        } else if next.y <= targetY {
            next.y = targetY
        } else {
            let maxDrop = cfg.maxDescentRate * dt
            next.y = max(targetY, next.y - maxDrop)
        }

        // Collisions
        next = resolveObstacleCollisions(position: next)

        // Apply position
        yawNode.simdPosition = next
        skyAnchor.simdPosition = next

        // Stream world
        chunker.updateVisible(center: next)

        // -------------------- CLOUD CONVEYOR (robust: re-scan groups + centroid fallback) --------------------
        if let layer = cloudLayerNode {
            // Always use current children in case anything changed after buildSky()
            let groups = layer.childNodes
            if !groups.isEmpty {
                @inline(__always)
                func windLocal(_ w: simd_float2, _ yaw: Float) -> simd_float2 {
                    let c = cosf(yaw), s = sinf(yaw)           // rotate world→layer by −yaw
                    return simd_float2(w.x * c + w.y * s, -w.x * s + w.y * c)
                }

                // Layer-local wind direction/magnitude
                let wLocal = windLocal(cloudWind, layer.eulerAngles.y)
                let wLen   = simd_length(wLocal)
                let wDir   = (wLen < 1e-5) ? simd_float2(1, 0) : (wLocal / wLen)

                // Match the old far-belt spin speed as a reference
                let Rmin: Float = cloudRMin
                let Rmax: Float = cloudRMax
                let Rref: Float = max(1, Rmin + 0.85 * (Rmax - Rmin))
                let vSpinRef: Float = cloudSpinRate * Rref

                // Wind gain around that reference (kept visible)
                let wRef: Float = 0.6324555
                let windMul = simd_clamp(wLen / max(1e-5, wRef), 0.25, 2.0)
                let baseSpeedUnits: Float = vSpinRef * windMul

                // Fallback when calm: tiny spin so nothing stalls
                let doFallbackSpin = (wLen < 1e-4)
                let span: Float = max(1e-5, Rmax - Rmin)
                let wrapLen: Float = (2 * Rmax) + cloudWrapMargin

                for group in groups {
                    let gid = ObjectIdentifier(group)

                    // Get centroid; if missing, compute once and cache
                    let c0: simd_float3 = {
                        if let cached = cloudClusterCentroidLocal[gid] { return cached }
                        var sum = simd_float3.zero
                        var n = 0
                        for bb in group.childNodes {
                            if let cs = bb.constraints, cs.contains(where: { $0 is SCNBillboardConstraint }) {
                                sum += bb.simdPosition; n += 1
                            }
                        }
                        let c = (n > 0) ? (sum / Float(n)) : .zero
                        cloudClusterCentroidLocal[gid] = c
                        return c
                    }()

                    // Cluster centre in layer-local XZ
                    let cw = c0 + group.simdPosition

                    // Parallax: faster near, slower far (2× → 0.5×)
                    let r   = simd_length(SIMD2(cw.x, cw.z))
                    let tR  = simd_clamp((r - Rmin) / span, 0, 1)
                    let scale: Float = 2.0 * (1.0 - tR) + 0.5 * tR

                    if doFallbackSpin {
                        // Keep motion when wind ≈ 0
                        let theta = cloudSpinRate * dt * scale
                        let ca = cosf(theta), sa = sinf(theta)
                        let vx = cw.x, vz = cw.z
                        let rx = vx * ca - vz * sa
                        let rz = vx * sa + vz * ca
                        group.simdPosition.x = rx - c0.x
                        group.simdPosition.z = rz - c0.z
                    } else {
                        // Advect along wind axis
                        let v = baseSpeedUnits * scale
                        let d = wDir * (v * dt)
                        group.simdPosition.x += d.x
                        group.simdPosition.z += d.y

                        // Recycle strictly along the wind axis at the far rim
                        let ax = simd_dot(SIMD2(cw.x, cw.z), wDir)
                        if ax > (Rmax + cloudWrapMargin) {
                            group.simdPosition.x -= wDir.x * wrapLen
                            group.simdPosition.z -= wDir.y * wrapLen
                        } else if ax < -(Rmax + cloudWrapMargin) {
                            group.simdPosition.x += wDir.x * wrapLen
                            group.simdPosition.z += wDir.y * wrapLen
                        }
                    }
                }
            }
        }

        // Volumetric uniforms (if present)
        if let sphere = skyAnchor.childNode(withName: "VolumetricCloudLayer", recursively: false),
           let m = sphere.geometry?.firstMaterial {
            m.setValue(CGFloat(t), forKey: "time")
            let pov = (scnView?.pointOfView ?? camNode).presentation
            let invView = simd_inverse(pov.simdWorldTransform)
            let sunView4 = invView * simd_float4(sunDirWorld, 0)
            let s = simd_normalize(simd_float3(sunView4.x, sunView4.y, sunView4.z))
            m.setValue(SCNVector3(s.x, s.y, s.z), forKey: "sunDirView")
            m.setValue(SCNVector3(cloudWind.x, cloudWind.y, 0), forKey: "wind")
            m.setValue(SCNVector3(cloudDomainOffset.x, cloudDomainOffset.y, 0), forKey: "domainOffset")
            m.setValue(0.0 as CGFloat, forKey: "domainRotate")
        }

        // Sun diffusion reacts to billboard occlusion
        updateSunDiffusion()

        // Safety ground follow
        if let sg = scene.rootNode.childNode(withName: "SafetyGround", recursively: false) {
            sg.simdPosition = simd_float3(next.x, groundY - 0.02, next.z)
        }
    }

    // MARK: - Movement / rig

    @inline(__always) func updateRig() {
        yawNode.eulerAngles   = SCNVector3(0, yaw, 0)
        pitchNode.eulerAngles = SCNVector3(pitch, 0, 0)
        camNode.position = SCNVector3(0, 0, 0)
    }

    @inline(__always) func clampAngles() {
        let halfPi = Float.pi / 2
        pitch = max(-halfPi + 0.01, min(halfPi - 0.01, pitch))
        if yaw >  Float.pi { yaw -= 2 * Float.pi }
        if yaw < -Float.pi { yaw += 2 * Float.pi }
    }

    // MARK: - World sampling

    func groundHeightFootprint(worldX x: Float, z: Float) -> Float {
        if let y = groundHeightRaycast(worldX: x, z: z) { return y }
        let r: Float = 0.35
        let h0 = TerrainMath.heightWorld(x: x,     z: z,     cfg: cfg, noise: noise)
        let h1 = TerrainMath.heightWorld(x: x - r, z: z - r, cfg: cfg, noise: noise)
        let h2 = TerrainMath.heightWorld(x: x + r, z: z - r, cfg: cfg, noise: noise)
        let h3 = TerrainMath.heightWorld(x: x - r, z: z + r, cfg: cfg, noise: noise)
        let h4 = TerrainMath.heightWorld(x: x + r, z: z + r, cfg: cfg, noise: noise)
        return max(h0, h1, h2, h3, h4)
    }

    func groundHeightRaycast(worldX x: Float, z: Float) -> Float? {
        let from = SCNVector3(x, 10_000, z)
        let to   = SCNVector3(x, -10_000, z)
        let hits = scene.rootNode.hitTestWithSegment(from: from, to: to, options: nil)
        if let hit = hits.first(where: {
            let n = $0.node
            return (n.categoryBitMask & 0x00000400) != 0 || (n.name?.hasPrefix("chunk_") ?? false)
        }) {
            return hit.worldCoordinates.y
        }
        return nil
    }

    // MARK: - Spawn

    func spawn() -> SCNVector3 {
        let ts = cfg.tileSize

        func isWalkable(tx: Int, tz: Int) -> Bool {
            let h = noise.sampleHeight(Double(tx), Double(tz)) / max(0.0001, recipe.height.amplitude)
            let s = noise.slope(Double(tx), Double(tz))
            let r = noise.riverMask(Double(tx), Double(tz))
            if h < 0.28 { return false }
            if s > 0.35 { return false }
            if r > 0.60 { return false }
            return true
        }

        if isWalkable(tx: 0, tz: 0) {
            return SCNVector3(
                ts * 0.5,
                TerrainMath.heightWorld(x: 0, z: 0, cfg: cfg, noise: noise) + cfg.eyeHeight,
                ts * 0.5
            )
        }

        for radius in 1...32 {
            for z in -radius...radius {
                for x in -radius...radius where abs(x) == radius || abs(z) == radius {
                    if isWalkable(tx: x, tz: z) {
                        let wx = Float(x) * ts + ts * 0.5
                        let wz = Float(z) * ts + ts * 0.5
                        return SCNVector3(
                            wx,
                            TerrainMath.heightWorld(x: wx, z: wz, cfg: cfg, noise: noise) + cfg.eyeHeight,
                            wz
                        )
                    }
                }
            }
        }

        return SCNVector3(
            0,
            TerrainMath.heightWorld(x: 0, z: 0, cfg: cfg, noise: noise) + cfg.eyeHeight,
            0
        )
    }

    // MARK: - Obstacles / collisions

    func registerObstacles(for chunk: IVec2, from nodes: [SCNNode]) {
        var obs: [Obstacle] = []
        obs.reserveCapacity(nodes.count)
        for n in nodes {
            let p = n.worldPosition
            let r = (n.value(forKey: "hitRadius") as? CGFloat).map { Float($0) } ?? 0.5
            obs.append(Obstacle(node: n, position: SIMD2(Float(p.x), Float(p.z)), radius: r))
        }
        obstaclesByChunk[chunk] = obs
    }

    func resolveObstacleCollisions(position p: SIMD3<Float>) -> SIMD3<Float> {
        var pos = p
        let pr = cfg.playerRadius

        let ci = chunkIndex(forWorldX: pos.x, z: pos.z)
        for dz in -1...1 {
            for dx in -1...1 {
                let key = IVec2(ci.x + dx, ci.y + dz)
                guard let arr = obstaclesByChunk[key], !arr.isEmpty else { continue }
                for o in arr {
                    guard o.node != nil else { continue }
                    let d = SIMD2(pos.x, pos.z) - o.position
                    let dist2 = simd_length_squared(d)
                    let minDist = pr + o.radius
                    if dist2 < minDist * minDist {
                        let dist = sqrt(max(1e-5, dist2))
                        let n = d / dist
                        let push = (minDist - dist) + 0.01
                        pos.x += n.x * push
                        pos.z += n.y * push
                    }
                }
            }
        }
        return pos
    }

    // MARK: - Chunk indexing

    func chunkIndex(forWorldX x: Float, z: Float) -> IVec2 {
        let tX = Int(floor(Double(x) / Double(cfg.tileSize)))
        let tZ = Int(floor(Double(z) / Double(cfg.tileSize)))
        return IVec2(floorDiv(tX, cfg.tilesX), floorDiv(tZ, cfg.tilesZ))
    }

    func floorDiv(_ a: Int, _ b: Int) -> Int {
        a >= 0 ? a / b : ((a + 1) / b - 1)
    }

    // MARK: - Beacon collection

    func collectNearbyBeacons(playerXZ: SIMD2<Float>) {
        var picked: [SCNNode] = []
        for n in beacons {
            let p = n.worldPosition
            let dx = playerXZ.x - p.x
            let dz = playerXZ.y - p.z
            if dx*dx + dz*dz < 1.25 * 1.25 { picked.append(n) }
        }

        if !picked.isEmpty {
            picked.forEach {
                $0.removeAllActions()
                $0.removeFromParentNode()
                beacons.remove($0)
            }
            score += picked.count
            DispatchQueue.main.async { [score, onScore] in onScore(score) }
        }
    }
}
