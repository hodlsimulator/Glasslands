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
    enum CloudFixedProfile: String {
        case quality
        case balanced
        case performance
    }

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

    struct RunHUDSnapshot {
        let banked: Int
        let carrying: Int
        let secondsRemaining: Int
        let canBankNow: Bool
        let runEnded: Bool
        let chapterTitle: String
        let objectiveText: String
        let bankPromptText: String
        let bankRadiusMeters: Float
        let waystoneDebugText: String
        let debugFpsDisplay: Int
        let debugFpsMin1s: Int
        let debugLowFpsThreshold: Int
        let debugLowFpsActive: Bool
        let debugActiveToggles: String
        let debugCpuFrameMs: Double
        let debugCpuMoveMs: Double
        let debugCpuChunkMs: Double
        let debugCpuCloudMs: Double
        let debugCpuSkyMs: Double
        let debugCpuSubmitMs: Double
        let debugPerfHint: String
        let debugCloudLodInfo: String
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
    var cloudSpinRate: Float = 0.0014544410   // 5°/min in rad/s
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
    var cloudUpdateAccumulator: TimeInterval = 0
    var cloudAdaptiveTier = 0
    var cloudAppliedVisualTier: Int = -1
    var cloudVisiblePuffsPerCluster: Int = 10
    var cloudCheapShaderEnabled: Bool = false
    var cloudFixedProfile: CloudFixedProfile = .performance
    var cloudFixedProfileResolved = false


    // Frame timing
    var lastTime: TimeInterval = 0
    var pickupCheckAccumulator: TimeInterval = 0

    // Gameplay
    var beaconsByChunk: [IVec2: [SCNNode]] = [:]
    var score = 0
    var onScore: (Int) -> Void
    var carriedBeacons = 0
    var bankedBeacons = 0
    var banksCompleted = 0
    let runDurationSeconds = 240
    var runStartTime: TimeInterval = 0
    var runEnded = false
    var waystoneNode: SCNNode?
    #if DEBUG
    let debugEnableWaystoneVFX = ProcessInfo.processInfo.environment["GL_DEBUG_ENABLE_WAYSTONE_VFX"] == "1"
    let debugDisableCloudRender = ProcessInfo.processInfo.environment["GL_DEBUG_DISABLE_CLOUD_RENDER"] == "1"
    let debugDisableCloudUpdate = ProcessInfo.processInfo.environment["GL_DEBUG_DISABLE_CLOUD_UPDATE"] == "1"
    let debugDisableCloudBillboardPass = ProcessInfo.processInfo.environment["GL_DEBUG_DISABLE_CLOUD_BILLBOARD_PASS"] == "1"
    let debugDisableSky = ProcessInfo.processInfo.environment["GL_DEBUG_DISABLE_SKY"] == "1"
    let debugDisableTerrainShading = ProcessInfo.processInfo.environment["GL_DEBUG_DISABLE_TERRAIN_SHADING"] == "1"
    let debugDisableDynamicLights = ProcessInfo.processInfo.environment["GL_DEBUG_DISABLE_DYNAMIC_LIGHTS"] == "1"
    let debugDisableChunkStreaming = ProcessInfo.processInfo.environment["GL_DEBUG_DISABLE_CHUNK_STREAMING"] == "1"
    let debugForceCloudTier: Int? = {
        guard
            let raw = ProcessInfo.processInfo.environment["GL_DEBUG_FORCE_CLOUD_TIER"],
            let v = Int(raw),
            (0...3).contains(v)
        else { return nil }
        return v
    }()
    let debugForceCloudMode: String? = {
        guard let raw = ProcessInfo.processInfo.environment["GL_DEBUG_FORCE_CLOUD_MODE"]?.lowercased() else { return nil }
        if raw == "cheap" || raw == "full" { return raw }
        return nil
    }()
    let debugForceCloudDither: Bool? = {
        guard let raw = ProcessInfo.processInfo.environment["GL_DEBUG_FORCE_CLOUD_DITHER"]?.lowercased() else { return nil }
        if ["1", "true", "on", "yes"].contains(raw) { return true }
        if ["0", "false", "off", "no"].contains(raw) { return false }
        return nil
    }()
    let debugCloudProfileOverride: CloudFixedProfile? = {
        guard let raw = ProcessInfo.processInfo.environment["GL_DEBUG_CLOUD_PROFILE"]?.lowercased() else { return nil }
        return CloudFixedProfile(rawValue: raw)
    }()
    let debugLowFpsThresholdOverride: Float? = {
        guard
            let raw = ProcessInfo.processInfo.environment["GL_DEBUG_LOW_FPS_THRESHOLD"],
            let v = Float(raw),
            v > 1
        else { return nil }
        return v
    }()
    var debugFrameAccum: TimeInterval = 0
    var debugFrameCount = 0
    var debugLastSpikeLogTime: TimeInterval = 0
    var debugFpsEMA: Float = 60
    var debugFpsMin1s: Float = 60
    var debugFpsMinWindowCurrent: Float = 60
    var debugFpsMinWindowElapsed: TimeInterval = 0
    var debugExpectedFps: Float = 60
    var debugExpectedSampleElapsed: TimeInterval = 0
    var debugLowFpsDebounceElapsed: TimeInterval = 0
    var debugLowFpsActive = false
    var debugCpuFrameMs: Double = 0
    var debugCpuMoveMs: Double = 0
    var debugCpuChunkMs: Double = 0
    var debugCpuCloudMs: Double = 0
    var debugCpuSkyMs: Double = 0
    var debugCpuSubmitMs: Double = 0
    var debugPerfHint: String = "CPU/GPU stable"
    #endif

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

    @MainActor func attach(to view: SCNView, recipe: BiomeRecipe) {
        resolveCloudFixedProfileOnce()
        scnView = view
        view.scene = scene
        view.preferredFramesPerSecond = 60
        view.antialiasingMode = .none
        view.isJitteringEnabled = false
        view.isOpaque = true

        if let metal = view.layer as? CAMetalLayer {
            metal.isOpaque = true
            metal.wantsExtendedDynamicRangeContent = false
            metal.colorspace = CGColorSpaceCreateDeviceRGB()
            metal.pixelFormat = .bgra8Unorm_srgb
            metal.maximumDrawableCount = 3
        }

        scene.physicsWorld.gravity = SCNVector3(0, 0, 0)

        buildLighting()
        buildSky()
        apply(recipe: recipe, force: true)

        removeVolumetricDomeIfPresent()

        #if DEBUG
        let shouldBuildClouds = !(debugDisableSky || debugDisableCloudRender)
        #else
        let shouldBuildClouds = true
        #endif
        let cloudRadius = CGFloat(cfg.skyDistance)
        let cloudSeed = self.cloudSeed
        let cloudInitialYaw = self.cloudInitialYaw
        let cloudClusterCount = shouldBuildClouds ? cloudClusterCountForFixedProfile() : 0

        // Build Sendable specs off-thread (no SceneKit here).
        let specsTask = Task.detached(priority: .userInitiated) {
            CloudBillboardLayer.buildSpecs(
                radius: cloudRadius,
                clusterCount: cloudClusterCount,
                seed: cloudSeed,
                minAltitudeY: 0.12
            )
        }

        // Assemble SceneKit nodes on the MainActor (optionally time-sliced).
        Task { @MainActor [weak self] in
            guard let self else { return }

            let specs = await specsTask.value
            guard shouldBuildClouds, !specs.isEmpty else { return }

            if let existing = self.skyAnchor.childNode(withName: "CumulusBillboardLayer", recursively: false) {
                existing.removeFromParentNode()
            }

            let root = SCNNode()
            root.name = "CumulusBillboardLayer"
            root.castsShadow = false
            root.renderingOrder = -10_000
            root.categoryBitMask = 0x0000_0010
            root.eulerAngles.y = cloudInitialYaw

            self.skyAnchor.addChildNode(root)
            self.cloudLayerNode = root

            let factory = CloudBillboardFactory.initWithAtlas(nil)

            var rMin = Float.greatestFiniteMagnitude
            var rMax: Float = 0

            for (i, spec) in specs.enumerated() {
                let node = factory.makeNode(from: spec, renderPuffs: true)
                root.addChildNode(node)

                let r = simd_length(simd_float2(node.simdPosition.x, node.simdPosition.z))
                if r.isFinite {
                    rMin = min(rMin, r)
                    rMax = max(rMax, r)
                }

                if (i & 7) == 0 { await Task.yield() }
            }

            if rMax > 0, rMin.isFinite {
                self.cloudRMin = max(1, rMin)
                self.cloudRMax = max(self.cloudRMin, rMax)
            }

            self.cloudClusterCentroidLocal.removeAll(keepingCapacity: true)

            self.enableVolumetricCloudImpostors(false)
            self.applyCloudSunUniforms()
            self.prewarmSkyAndSun()
        }
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

    @MainActor
    func runHUDSnapshot() -> RunHUDSnapshot {
        let now = CACurrentMediaTime()
        let remaining = secondsRemaining(at: now)
        let playerWorldPos = yawNode.simdWorldPosition
        let bankRadius = activeBankRadius(at: now)
        let canBank = canBankNow(playerPos: playerWorldPos)
        let preview = bankValueForCarried(carrying: carriedBeacons, at: now)
        let chapter: String
        switch bankedBeacons {
        case ..<20: chapter = "Chapter I  First Light"
        case ..<60: chapter = "Chapter II  Wildglass Trail"
        case ..<120: chapter = "Chapter III  Long Dusk"
        default: chapter = "Chapter IV  Ember Keeper"
        }
        let objective: String = {
            if runEnded { return "Night fell. Unbanked beacons were lost." }
            if carriedBeacons == 0 { return "Collect beacons from nearby ridges." }
            if canBank { return "Bank now for +\(preview) before dusk deepens." }
            return "Return to the Waystone and secure your carry."
        }()
        let waystoneDebugText: String = {
            guard let waystone = waystoneNode else { return "Waystone: missing" }
            let d = playerWorldPos - waystone.simdWorldPosition
            let meters = sqrt(d.x * d.x + d.z * d.z)
            let hasGeom = (waystone.geometry != nil) ? "yes" : "no"
            #if DEBUG
            let vfx = debugEnableWaystoneVFX ? "on" : "off"
            return String(format: "Waystone: %.1f m  r=%.1f  geom=%@  vfx=%@", meters, bankRadius, hasGeom, vfx)
            #else
            return String(format: "Waystone: %.1f m  r=%.1f  geom=%@", meters, bankRadius, hasGeom)
            #endif
        }()
        let bankPromptText: String = {
            if runEnded { return "Run Ended" }
            if carriedBeacons == 0 { return "Carry 0" }
            return "Bank +\(preview)"
        }()
        let debugFpsDisplay: Int
        let debugFpsMin1sDisplay: Int
        let debugLowFpsThresholdDisplay: Int
        let debugLowFpsActiveDisplay: Bool
        #if DEBUG
        debugFpsDisplay = Int(debugFpsEMA.rounded())
        debugFpsMin1sDisplay = Int(debugFpsMin1s.rounded())
        debugLowFpsThresholdDisplay = Int(currentLowFpsThreshold().rounded())
        debugLowFpsActiveDisplay = debugLowFpsActive
        let debugActiveToggles = activeDebugTogglesText()
        let debugCpuFrameMs = self.debugCpuFrameMs
        let debugCpuMoveMs = self.debugCpuMoveMs
        let debugCpuChunkMs = self.debugCpuChunkMs
        let debugCpuCloudMs = self.debugCpuCloudMs
        let debugCpuSkyMs = self.debugCpuSkyMs
        let debugCpuSubmitMs = self.debugCpuSubmitMs
        let debugPerfHint = self.debugPerfHint
        let debugCloudLodInfo = cloudLodDebugText()
        #else
        debugFpsDisplay = 0
        debugFpsMin1sDisplay = 0
        debugLowFpsThresholdDisplay = 0
        debugLowFpsActiveDisplay = false
        let debugActiveToggles = ""
        let debugCpuFrameMs = 0.0
        let debugCpuMoveMs = 0.0
        let debugCpuChunkMs = 0.0
        let debugCpuCloudMs = 0.0
        let debugCpuSkyMs = 0.0
        let debugCpuSubmitMs = 0.0
        let debugPerfHint = ""
        let debugCloudLodInfo = ""
        #endif
        return RunHUDSnapshot(
            banked: bankedBeacons,
            carrying: carriedBeacons,
            secondsRemaining: remaining,
            canBankNow: canBank,
            runEnded: runEnded,
            chapterTitle: chapter,
            objectiveText: objective,
            bankPromptText: bankPromptText,
            bankRadiusMeters: bankRadius,
            waystoneDebugText: waystoneDebugText,
            debugFpsDisplay: debugFpsDisplay,
            debugFpsMin1s: debugFpsMin1sDisplay,
            debugLowFpsThreshold: debugLowFpsThresholdDisplay,
            debugLowFpsActive: debugLowFpsActiveDisplay,
            debugActiveToggles: debugActiveToggles,
            debugCpuFrameMs: debugCpuFrameMs,
            debugCpuMoveMs: debugCpuMoveMs,
            debugCpuChunkMs: debugCpuChunkMs,
            debugCpuCloudMs: debugCpuCloudMs,
            debugCpuSkyMs: debugCpuSkyMs,
            debugCpuSubmitMs: debugCpuSubmitMs,
            debugPerfHint: debugPerfHint,
            debugCloudLodInfo: debugCloudLodInfo
        )
    }

    @MainActor
    func bankNow() {
        let now = CACurrentMediaTime()
        guard canBankNow(playerPos: yawNode.simdWorldPosition) else { return }
        let gained = bankValueForCarried(carrying: carriedBeacons, at: now)
        bankedBeacons += gained
        carriedBeacons = 0
        banksCompleted += 1
        score = bankedBeacons
        DispatchQueue.main.async { [score, onScore] in onScore(score) }
    }

    // MARK: - Per-frame

    @MainActor
    func stepUpdateMain(at t: TimeInterval) {
        let sp = Signposts.begin("Frame"); defer { Signposts.end("Frame", sp) }
        #if DEBUG
        let perfStart = CACurrentMediaTime()
        let moveStart = perfStart
        var moveMs: Double = 0
        var debugChunkMs: Double = 0
        var debugCloudMs: Double = 0
        var debugSkyMs: Double = 0
        #endif

        // Timing (avoid zero-dt double-calls from multiple tickers)
        let rawDt = (lastTime == 0) ? 1/60 : max(0, t - lastTime)
        let dt: Float = Float(min(1/30, max(1/240, rawDt)))
        lastTime = t
        updateRunState(now: CACurrentMediaTime())
        updateCloudAdaptiveLOD(rawDt: rawDt)
        applyCloudTierVisualPolicyIfNeeded()
        #if DEBUG
        if rawDt > 0 {
            let instFps = Float(1.0 / rawDt)
            let alpha = max(0.05, min(0.4, Float(rawDt * 6.0)))
            debugFpsEMA += (instFps - debugFpsEMA) * alpha

            if debugExpectedSampleElapsed < 2.5 {
                debugExpectedSampleElapsed += rawDt
                debugExpectedFps = max(debugExpectedFps, debugFpsEMA)
            }

            debugFpsMinWindowCurrent = min(debugFpsMinWindowCurrent, instFps)
            debugFpsMinWindowElapsed += rawDt
            if debugFpsMinWindowElapsed >= 1.0 {
                debugFpsMin1s = debugFpsMinWindowCurrent
                debugFpsMinWindowCurrent = debugFpsEMA
                debugFpsMinWindowElapsed = 0
            }

            let threshold = currentLowFpsThreshold()
            let below = min(debugFpsEMA, debugFpsMin1s) < threshold
            if below {
                debugLowFpsDebounceElapsed += rawDt
                if debugLowFpsDebounceElapsed >= 0.25 { debugLowFpsActive = true }
            } else {
                debugLowFpsDebounceElapsed = 0
                debugLowFpsActive = false
            }
        }
        #endif

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
        
        // Cull billboard clouds near zenith to avoid GPU stalls when the sky fills the screen.
        // updateZenithCull()

        // Movement
        let forward = SIMD3(-sinf(yaw), 0, -cosf(yaw))
        let right   = SIMD3( cosf(yaw), 0, -sinf(yaw))
        let moveVec = (right * moveInput.x) + (forward * moveInput.y)
        let attemptedDelta = moveVec * (cfg.moveSpeed * dt)

        let current = yawNode.simdPosition
        let movedXZ = simd_length_squared(simd_float2(attemptedDelta.x, attemptedDelta.z)) > 1e-8
        var next = current + attemptedDelta

        // Height follow + descent cap
        // When stationary (e.g. looking around), avoid the raycast path: it's CPU-expensive and
        // can introduce camera-latency on mid-range devices.
        var groundY: Float
        if movedXZ {
            groundY = groundHeightFootprint(worldX: next.x, z: next.z)
        } else {
            groundY = TerrainMath.heightWorld(x: current.x, z: current.z, cfg: cfg, noise: noise)
        }

        let targetY = groundY + cfg.eyeHeight
        if !targetY.isFinite {
            next = spawn().simd
        } else if movedXZ == false && abs(current.y - targetY) < 0.02 {
            // Already grounded and not translating: keep the exact y to avoid micro-jitter.
            next = current
            groundY = current.y - cfg.eyeHeight
        } else if next.y <= targetY {
            next.y = targetY
        } else {
            let maxDrop = cfg.maxDescentRate * dt
            next.y = max(targetY, next.y - maxDrop)
        }

        // Collisions (skip when fully stationary and grounded)
        if movedXZ || abs(next.y - current.y) > 0.001 {
            next = resolveObstacleCollisions(position: next)
        }

        // Apply position
        yawNode.simdPosition = next
        skyAnchor.simdPosition = next

        // Stream world continuously. The initial preload ring must keep filling even when the
        // player is stationary (e.g. only looking around), otherwise most chunks never load.
        #if DEBUG
        moveMs = (CACurrentMediaTime() - moveStart) * 1000.0
        #endif
        #if DEBUG
        let chunkStart = CACurrentMediaTime()
        #endif
        #if DEBUG
        if !debugDisableChunkStreaming {
            chunker.updateVisible(center: next)
        }
        #else
        chunker.updateVisible(center: next)
        #endif
        #if DEBUG
        debugChunkMs = (CACurrentMediaTime() - chunkStart) * 1000.0
        #endif

        pickupCheckAccumulator += rawDt
        if pickupCheckAccumulator >= 0.25 {
            pickupCheckAccumulator = 0
            collectNearbyBeacons(playerPos: next)
        }

        // -------------------- CLOUD CONVEYOR (30 Hz throttled) --------------------
        cloudUpdateAccumulator += rawDt
        #if DEBUG
        let shouldUpdateClouds = !debugDisableCloudUpdate
        #else
        let shouldUpdateClouds = true
        #endif
        let cloudHz = cloudUpdateHzForCurrentTier()
        if shouldUpdateClouds, cloudUpdateAccumulator >= (1.0 / cloudHz), let layer = cloudLayerNode {
            let cloudDt = Float(cloudUpdateAccumulator)
            cloudUpdateAccumulator = 0
            #if DEBUG
            let cloudStart = CACurrentMediaTime()
            #endif
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
                    let farCull = cloudFarCullRatioForCurrentTier()
                    let maxVisibleRadius = Rmin + farCull * span
                    if r > maxVisibleRadius {
                        group.isHidden = true
                        continue
                    } else {
                        group.isHidden = false
                    }
                    let tR  = simd_clamp((r - Rmin) / span, 0, 1)
                    let scale: Float = 2.0 * (1.0 - tR) + 0.5 * tR

                    if doFallbackSpin {
                        // Keep motion when wind ≈ 0
                        let theta = cloudSpinRate * cloudDt * scale
                        let ca = cosf(theta), sa = sinf(theta)
                        let vx = cw.x, vz = cw.z
                        let rx = vx * ca - vz * sa
                        let rz = vx * sa + vz * ca
                        group.simdPosition.x = rx - c0.x
                        group.simdPosition.z = rz - c0.z
                    } else {
                        // Advect along wind axis
                        let v = baseSpeedUnits * scale
                        let d = wDir * (v * cloudDt)
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
            // Volumetric uniforms (if present)
            if let sphere = skyAnchor.childNode(withName: "VolumetricCloudLayer", recursively: false),
               let m = sphere.geometry?.firstMaterial {
                #if DEBUG
                let skyStart = CACurrentMediaTime()
                #endif
                m.setValue(CGFloat(t), forKey: "time")
                let pov = (scnView?.pointOfView ?? camNode).presentation
                let invView = simd_inverse(pov.simdWorldTransform)
                let sunView4 = invView * simd_float4(sunDirWorld, 0)
                let s = simd_normalize(simd_float3(sunView4.x, sunView4.y, sunView4.z))
                m.setValue(SCNVector3(s.x, s.y, s.z), forKey: "sunDirView")
                m.setValue(SCNVector3(cloudWind.x, cloudWind.y, 0), forKey: "wind")
                m.setValue(SCNVector3(cloudDomainOffset.x, cloudDomainOffset.y, 0), forKey: "domainOffset")
                m.setValue(0.0 as CGFloat, forKey: "domainRotate")
                #if DEBUG
                debugSkyMs += (CACurrentMediaTime() - skyStart) * 1000.0
                #endif
            }
            #if DEBUG
            debugCloudMs = (CACurrentMediaTime() - cloudStart) * 1000.0
            #endif
        }

        // Sun diffusion reacts to billboard occlusion
        // updateSunDiffusion()

        // Safety ground follow
        if let sg = scene.rootNode.childNode(withName: "SafetyGround", recursively: false) {
            sg.simdPosition = simd_float3(next.x, groundY - 0.02, next.z)
        }

        #if DEBUG
        let frameCost = CACurrentMediaTime() - perfStart
        let frameMs = frameCost * 1000.0
        let submitMs = max(0, frameMs - (moveMs + debugChunkMs + debugCloudMs + debugSkyMs))
        debugCpuFrameMs = frameMs
        debugCpuMoveMs = moveMs
        debugCpuChunkMs = debugChunkMs
        debugCpuCloudMs = debugCloudMs
        debugCpuSkyMs = debugSkyMs
        debugCpuSubmitMs = submitMs
        debugPerfHint = classifyPerfHint(
            fps: min(debugFpsEMA, debugFpsMin1s),
            threshold: currentLowFpsThreshold(),
            moveMs: moveMs,
            chunkMs: debugChunkMs,
            cloudMs: debugCloudMs,
            skyMs: debugSkyMs,
            submitMs: submitMs
        )
        debugFrameAccum += frameCost
        debugFrameCount += 1
        if frameCost > 0.022, (t - debugLastSpikeLogTime) > 0.75 {
            debugLastSpikeLogTime = t
            print(String(
                format: "[PERF] spike=%.2fms chunk=%.2fms cloud=%.2fms",
                frameCost * 1000.0,
                debugChunkMs,
                debugCloudMs
            ))
        }
        if debugFrameCount >= 120 {
            let avgMs = (debugFrameAccum / Double(debugFrameCount)) * 1000.0
            let fps = (debugFrameAccum > 0) ? Double(debugFrameCount) / debugFrameAccum : 0
            print(String(
                format: "[PERF] stepUpdate avg=%.2fms fps=%.1f waystoneVFX=%@",
                avgMs,
                fps,
                debugEnableWaystoneVFX ? "on" : "off"
            ))
            debugFrameAccum = 0
            debugFrameCount = 0
        }
        #endif
    }

    func updateCloudAdaptiveLOD(rawDt: TimeInterval) {
        _ = rawDt
        let tier = fixedCloudTierForCurrentProfile()
        if cloudAdaptiveTier != tier {
            cloudAdaptiveTier = tier
            cloudAppliedVisualTier = -1
        }
    }

    func cloudClusterCountForFixedProfile() -> Int {
        switch cloudFixedProfile {
        case .quality: return 64
        case .balanced: return 44
        case .performance: return 24
        }
    }

    func fixedCloudTierForCurrentProfile() -> Int {
        #if DEBUG
        if let forcedTier = debugForceCloudTier {
            return forcedTier
        }
        #endif
        switch cloudFixedProfile {
        case .quality: return 0
        case .balanced: return 2
        case .performance: return 3
        }
    }

    @MainActor
    func resolveCloudFixedProfileOnce() {
        if cloudFixedProfileResolved { return }
        cloudFixedProfileResolved = true

        #if DEBUG
        if let debugProfile = debugCloudProfileOverride {
            cloudFixedProfile = debugProfile
            cloudAdaptiveTier = fixedCloudTierForCurrentProfile()
            cloudAppliedVisualTier = -1
            return
        }
        #endif

        if let raw = ProcessInfo.processInfo.environment["GL_CLOUD_PROFILE"]?.lowercased(),
           let selected = CloudFixedProfile(rawValue: raw) {
            cloudFixedProfile = selected
        } else {
            cloudFixedProfile = .performance
        }

        cloudAdaptiveTier = fixedCloudTierForCurrentProfile()
        cloudAppliedVisualTier = -1
    }

    func cloudQualityForCurrentTier() -> Float {
        switch cloudAdaptiveTier {
        case 0: return 1.00
        case 1: return 0.80
        case 2: return 0.62
        default: return 0.48
        }
    }

    func cloudUpdateHzForCurrentTier() -> Double {
        switch cloudAdaptiveTier {
        case 0: return 60.0
        case 1: return 45.0
        case 2: return 30.0
        default: return 24.0
        }
    }

    func cloudFarCullRatioForCurrentTier() -> Float {
        switch cloudAdaptiveTier {
        case 0: return 1.00
        case 1: return 0.86
        case 2: return 0.72
        default: return 0.58
        }
    }

    func targetCloudPuffsPerCluster(for tier: Int) -> Int {
        switch tier {
        case 0: return 10
        case 1: return 8
        case 2: return 7
        default: return 5
        }
    }

    func resolvedCloudMode() -> String {
        #if DEBUG
        if let forced = debugForceCloudMode { return forced }
        #endif
        return "full"
    }

    func resolvedCloudDitherEnabled() -> Bool {
        #if DEBUG
        if let forced = debugForceCloudDither { return forced }
        #endif
        return false
    }

    #if DEBUG
    @inline(__always)
    func currentLowFpsThreshold() -> Float {
        if let forced = debugLowFpsThresholdOverride { return forced }
        let expected: Float = (debugExpectedFps >= 90) ? 120 : 60
        return expected * 0.92
    }

    func activeDebugTogglesText() -> String {
        var active: [String] = []
        if debugDisableCloudRender { active.append("CLOUD_RENDER") }
        if debugDisableCloudUpdate { active.append("CLOUD_UPDATE") }
        if debugDisableCloudBillboardPass { active.append("CLOUD_BILLBOARD_PASS") }
        if debugDisableSky { active.append("SKY") }
        if debugDisableTerrainShading { active.append("TERRAIN_SHADING") }
        if debugDisableDynamicLights { active.append("DYNAMIC_LIGHTS") }
        if debugDisableChunkStreaming { active.append("CHUNK_STREAM") }
        if debugEnableWaystoneVFX { active.append("WAYSTONE_VFX") }
        if ProcessInfo.processInfo.environment["GL_DEBUG_CLOUD_FORCE_SOLID"] == "1" { active.append("CLOUD_FORCE_SOLID") }
        if ProcessInfo.processInfo.environment["GL_DEBUG_CLOUD_OUTLIER_VIS"] == "1" { active.append("CLOUD_OUTLIER_VIS") }
        if ProcessInfo.processInfo.environment["GL_DEBUG_CLOUD_CULL_OUTLIERS"] == "1" { active.append("CLOUD_CULL_OUTLIERS") }
        if let forced = debugForceCloudTier { active.append("FORCE_TIER=\(forced)") }
        if let forcedMode = debugForceCloudMode { active.append("FORCE_MODE=\(forcedMode)") }
        if let forcedDither = debugForceCloudDither { active.append("FORCE_DITHER=\(forcedDither ? "on" : "off")") }
        active.append("PROFILE=\(cloudFixedProfile.rawValue)")
        active.append("FIXED_CLOUDS=on")
        return active.isEmpty ? "none" : active.joined(separator: ",")
    }

    func cloudLodDebugText() -> String {
        let q = cloudQualityForCurrentTier()
        let hz = cloudUpdateHzForCurrentTier()
        let far = cloudFarCullRatioForCurrentTier()
        let dither = resolvedCloudDitherEnabled() ? "on" : "off"
        let mode = resolvedCloudMode()
        return String(format: "Cloud %@@t%d q%.2f hz%.0f far%.2f dither=%@ mode=%@ puffs=%d", cloudFixedProfile.rawValue, cloudAdaptiveTier, q, hz, far, dither, mode, cloudVisiblePuffsPerCluster)
    }

    func classifyPerfHint(
        fps: Float,
        threshold: Float,
        moveMs: Double,
        chunkMs: Double,
        cloudMs: Double,
        skyMs: Double,
        submitMs: Double
    ) -> String {
        let cpuMs = moveMs + chunkMs + cloudMs + skyMs
        let budgetMs = 1000.0 / Double(max(1, threshold))
        if fps < threshold, cpuMs < budgetMs * 0.7 {
            return "GPU-bound likely"
        }
        if fps >= threshold { return "CPU/GPU stable" }
        let pairs: [(String, Double)] = [
            ("move", moveMs),
            ("chunk", chunkMs),
            ("cloud", cloudMs),
            ("sky", skyMs),
            ("submit", submitMs)
        ]
        let top = pairs.max { $0.1 < $1.1 } ?? ("cpu", cpuMs)
        return "CPU-bound likely (\(top.0))"
    }
    #endif

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
        // Raycasts are noticeably expensive on mobile and can introduce camera-latency.
        // The terrain is deterministic from noise, so sample the height-field directly.
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
        let to = SCNVector3(x, -10_000, z)

        // Terrain-only raycast: avoids hitting sky dome + cloud planes every frame.
        let options: [String: Any] = [
            SCNHitTestOption.categoryBitMask.rawValue: 0x0000_0400,
            SCNHitTestOption.firstFoundOnly.rawValue: true,
            SCNHitTestOption.ignoreHiddenNodes.rawValue: true
        ]

        if let hit = scene.rootNode.hitTestWithSegment(from: from, to: to, options: options).first {
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

    // MARK: - Run state

    func secondsRemaining(at now: TimeInterval) -> Int {
        guard runStartTime > 0 else { return runDurationSeconds }
        let elapsed = max(0, Int(now - runStartTime))
        return max(0, runDurationSeconds - elapsed)
    }

    func updateRunState(now: TimeInterval) {
        guard !runEnded else { return }
        if secondsRemaining(at: now) <= 0 {
            runEnded = true
            carriedBeacons = 0
        }
    }

    func activeBankRadius(at now: TimeInterval) -> Float {
        let remaining = secondsRemaining(at: now)
        if remaining <= 45 { return 6.0 }
        if remaining <= 90 { return 5.0 }
        return 4.0
    }

    func bankValueForCarried(carrying: Int, at now: TimeInterval) -> Int {
        guard carrying > 0 else { return 0 }
        let remaining = secondsRemaining(at: now)
        let base = carrying
        let loadBonus = max(0, carrying - 4) / 2
        let duskBonus = (remaining <= 45) ? (carrying / 2) : ((remaining <= 90) ? (carrying / 4) : 0)
        return base + loadBonus + duskBonus
    }

    func canBankNow(playerPos: SIMD3<Float>) -> Bool {
        guard !runEnded, carriedBeacons > 0, let waystone = waystoneNode else { return false }
        let d = playerPos - waystone.simdWorldPosition
        let r = activeBankRadius(at: CACurrentMediaTime())
        return simd_length_squared(simd_float2(d.x, d.z)) <= (r * r)
    }

    func spawnWaystoneNearSpawn(near playerSpawnWorldPos: SIMD3<Float>) {
        waystoneNode?.removeFromParentNode()

        let cylinder = SCNCylinder(radius: 0.45, height: 2.4)
        let mat = SCNMaterial()
        mat.lightingModel = .constant
        mat.diffuse.contents = UIColor(red: 0.95, green: 0.98, blue: 1.0, alpha: 1.0)
        mat.emission.contents = UIColor(red: 0.25, green: 0.9, blue: 1.0, alpha: 1.0)
        mat.readsFromDepthBuffer = true
        mat.writesToDepthBuffer = true
        cylinder.firstMaterial = mat

        let node = SCNNode(geometry: cylinder)
        node.name = "Waystone"
        node.isHidden = false
        node.opacity = 1.0
        node.castsShadow = false
        node.renderingOrder = 1_200
        node.categoryBitMask = 0x0000_0001

        let crown = SCNNode(geometry: SCNSphere(radius: 0.30))
        let crownMat = SCNMaterial()
        crownMat.lightingModel = .constant
        crownMat.diffuse.contents = UIColor(red: 1.0, green: 0.97, blue: 0.85, alpha: 1.0)
        crownMat.emission.contents = UIColor(red: 1.0, green: 0.85, blue: 0.3, alpha: 1.0)
        crownMat.readsFromDepthBuffer = true
        crownMat.writesToDepthBuffer = true
        crown.geometry?.firstMaterial = crownMat
        crown.renderingOrder = 1_201
        crown.simdPosition = simd_float3(0, 1.35, 0)
        crown.categoryBitMask = 0x0000_0001
        node.addChildNode(crown)

        var ring: SCNNode?
        #if DEBUG
        let useVFX = debugEnableWaystoneVFX
        #else
        let useVFX = false
        #endif
        if useVFX {
            let ringNode = SCNNode(geometry: SCNTorus(ringRadius: 0.95, pipeRadius: 0.05))
            let ringMat = SCNMaterial()
            ringMat.lightingModel = .constant
            ringMat.diffuse.contents = UIColor(red: 0.7, green: 0.98, blue: 1.0, alpha: 1.0)
            ringMat.emission.contents = UIColor(red: 0.25, green: 0.9, blue: 1.0, alpha: 1.0)
            ringMat.readsFromDepthBuffer = true
            ringMat.writesToDepthBuffer = true
            ringNode.geometry?.firstMaterial = ringMat
            ringNode.renderingOrder = 1_202
            ringNode.simdPosition = simd_float3(0, 0.4, 0)
            ringNode.eulerAngles.x = .pi / 2
            ringNode.categoryBitMask = 0x0000_0001
            node.addChildNode(ringNode)
            ring = ringNode
        }

        let base2 = simd_float2(playerSpawnWorldPos.x, playerSpawnWorldPos.z)
        let offsets: [Float] = [14, 18, 12, 16]
        var placed = false
        for dist in offsets where !placed {
            for i in 0..<12 where !placed {
                let a = (Float(i) / 12.0) * 2.0 * .pi
                let wx = base2.x + cosf(a) * dist
                let wz = base2.y + sinf(a) * dist
                let y = groundHeightRaycast(worldX: wx, z: wz)
                    ?? TerrainMath.heightWorld(x: wx, z: wz, cfg: cfg, noise: noise)
                if y.isFinite {
                    node.simdPosition = simd_float3(wx, y + 1.2, wz)
                    placed = true
                }
            }
        }
        if !placed {
            let y = groundHeightRaycast(worldX: base2.x, z: base2.y)
                ?? TerrainMath.heightWorld(x: base2.x, z: base2.y, cfg: cfg, noise: noise)
            node.simdPosition = simd_float3(base2.x, y + 1.2, base2.y)
        }

        if let ring {
            let spin = SCNAction.repeatForever(.rotateBy(x: 0, y: CGFloat.pi * 2.0, z: 0, duration: 6.5))
            let pulseUp = SCNAction.scale(to: 1.04, duration: 1.4)
            let pulseDown = SCNAction.scale(to: 0.98, duration: 1.4)
            let pulse = SCNAction.repeatForever(.sequence([pulseUp, pulseDown]))
            ring.runAction(spin)
            crown.runAction(pulse)
        }

        scene.rootNode.addChildNode(node)
        waystoneNode = node
    }

    // MARK: - Beacon collection

    func collectNearbyBeacons(playerPos: SIMD3<Float>) {
        guard !runEnded else { return }

        let ci = chunkIndex(forWorldX: playerPos.x, z: playerPos.z)
        let playerXZ = simd_float2(playerPos.x, playerPos.z)
        let r2: Float = 1.25 * 1.25

        for dz in -1...1 {
            for dx in -1...1 {
                let key = IVec2(ci.x + dx, ci.y + dz)
                guard let arr = beaconsByChunk[key], !arr.isEmpty else { continue }

                var kept: [SCNNode] = []
                kept.reserveCapacity(arr.count)

                for n in arr {
                    let p = n.worldPosition
                    let d = playerXZ - simd_float2(p.x, p.z)
                    if simd_length_squared(d) <= r2 {
                        n.removeAllActions()
                        n.removeFromParentNode()
                        carriedBeacons += 1
                    } else {
                        kept.append(n)
                    }
                }

                if kept.isEmpty {
                    beaconsByChunk.removeValue(forKey: key)
                } else {
                    beaconsByChunk[key] = kept
                }
            }
        }
    }
}
