//
//  FirstPersonEngine.swift
//  Glasslands
//
//  Created by . . on 9/30/25.
//
//  Updated: full engine restored; perf-safe view config; sky generator tuned for real gaps.
//

import Foundation
import SceneKit
import UIKit
import simd
import GameplayKit

@MainActor
final class FirstPersonEngine {

    // MARK: Public API

    init(onScore: @escaping (Int) -> Void) {
        self.onScore = onScore
    }

    func attach(to view: SCNView, recipe: BiomeRecipe) {
        scnView = view
        setupView(view)
        setupSceneIfNeeded()
        apply(recipe: recipe)
        isPaused = false
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        scnView?.isPlaying = !paused
    }

    func setMoveInput(_ vec: SIMD2<Float>) { // MoveStickView
        moveAxis = vec
    }

    func applyLookDelta(points delta: SIMD2<Float>) { // LookPadView
        look.applyDelta(points: delta)
        look.apply(to: playerNode, pitchNode: pitchNode)
    }

    func apply(recipe newRecipe: BiomeRecipe) {
        clearWorld()
        recipe = newRecipe
        noise = NoiseFields(recipe: newRecipe)

        makeLighting()
        makeSkyBillboards()       // ← billboard impostors (Sky/*), not the dome

        terrainRoot = SCNNode()
        terrainRoot.name = "TerrainRoot"
        scene.rootNode.addChildNode(terrainRoot)

        let cfg = config
        let streamer = ChunkStreamer3D(
            cfg: cfg,
            noise: noise,
            recipe: newRecipe,
            root: terrainRoot,
            renderer: scnView ?? sceneRendererFallback,
            beaconSink: { [weak self] nodes in
                guard let self, let first = nodes.first else { return }
                let k = self.keyFor(position: first.worldPosition)
                self.beacons[k, default: []].append(contentsOf: nodes)
            },
            obstacleSink: { [weak self] ci, nodes in
                guard let self else { return }
                let k = ChunkKey(x: ci.x, y: ci.y)
                self.obstacles.setObstacles(for: k, from: nodes)
            },
            onChunkRemoved: { [weak self] ci in
                guard let self else { return }
                let k = ChunkKey(x: ci.x, y: ci.y)
                self.obstacles.removeChunk(k)
                if let arr = self.beacons.removeValue(forKey: k) {
                    for n in arr { n.removeFromParentNode() }
                }
            }
        )
        streamer.tasksPerFrame = cfg.tasksPerFrame
        self.streamer = streamer

        let startY = TerrainMath.heightWorld(
            x: playerPos.x, z: playerPos.z, cfg: cfg, noise: noise
        ) + cfg.eyeHeight
        playerPos.y = startY
        updateTransforms()

        // Build a 3×3 immediately so there are no visible “voids”.
        streamer.warmupInitial(at: SIMD3(playerPos.x, 0, playerPos.z), radius: 1)
        streamer.updateVisible(center: SIMD3(playerPos.x, 0, playerPos.z))
    }

    func snapshot() -> UIImage? { scnView?.snapshot() }

    // Render-thread callback via RendererProxy
    func stepUpdateMain(at t: TimeInterval) {
        guard !isPaused else { lastTime = t; return }

        let dt: Float
        if let last = lastTime {
            dt = Float(max(0, min(0.050, t - last)))
        } else {
            lastTime = t
            return
        }
        lastTime = t

        let gy = TerrainMath.heightWorld(
            x: playerPos.x, z: playerPos.z, cfg: config, noise: noise
        )

        let groundY = { [noise, cfg = config] (x: Float, z: Float) -> Float in
            TerrainMath.heightWorld(x: x, z: z, cfg: cfg, noise: noise)
        }

        let near = obstacles.nearby(to: playerPos, within: 4.0)

        playerPos = mover.step(
            from: SIMD3(playerPos.x, gy + config.eyeHeight, playerPos.z),
            yaw: lookYaw,
            moveAxis: moveAxis,
            dt: dt,
            groundHeight: groundY,
            obstacles: near
        )
        playerPos.y = groundY(playerPos.x, playerPos.z) + config.eyeHeight

        updateTransforms()
        updateSunBillboardPosition()

        streamer?.updateVisible(center: SIMD3(playerPos.x, 0, playerPos.z))
        tallyBeacons()
    }

    // MARK: - Private

    private let scene = SCNScene()
    private weak var scnView: SCNView?

    private var sceneRendererFallback: SCNSceneRenderer { sceneRendererView }
    private let sceneRendererView = SCNView(frame: .zero)

    private let sceneRoot = SCNNode()

    private let playerNode = SCNNode()
    private let pitchNode = SCNNode()

    private let cameraNode: SCNNode = {
        let cam = SCNCamera()
        cam.zNear = 0.01
        cam.zFar = 2000

        // HDR + bloom for the sun disc
        cam.wantsHDR = true
        cam.wantsExposureAdaptation = true
        cam.minimumExposure = -2.0
        cam.maximumExposure =  2.0
        cam.exposureOffset = 0.0
        cam.exposureAdaptationBrighteningSpeedFactor = 1.0
        cam.exposureAdaptationDarkeningSpeedFactor  = 1.0

        cam.bloomIntensity  = 1.2
        cam.bloomThreshold  = 0.90
        cam.bloomBlurRadius = 18.0

        let n = SCNNode()
        n.camera = cam
        return n
    }()

    private var terrainRoot = SCNNode()
    private var skyNode: SCNNode?              // billboard cloud layer (Sky/)
    private var sunBillboard: SCNNode?         // HDR sun sprite (Sky/)

    private var streamer: ChunkStreamer3D?

    private var recipe: BiomeRecipe?

    private var noise = NoiseFields(recipe: BiomeRecipe(
        height: .init(base: "perlin",  octaves: 5, amplitude: 1, scale: 30),
        moisture: .init(base: "perlin", octaves: 4, amplitude: 1, scale: 20),
        paletteHex: ["#75AADB","#85C16A","#A8D0A6","#F3E9D2","#6B4F3B"],
        faunaTags: [],
        setpieces: [],
        weatherBias: "clear",
        music: .init(mode: "major", tempo: 110),
        seed64: 424242
    ))

    private var config = Config()

    private var moveAxis = SIMD2<Float>(repeating: 0)

    private var look = FirstPersonLookController(
        sensitivity: Config().lookSensitivityRadPerPoint,
        maxPitch: Config().maxPitchRadians
    )

    private var mover = FirstPersonMover(
        speed: Config().moveSpeed,
        radius: Config().playerRadius
    )

    private var isPaused = false

    private var score: Int = 0 { didSet { onScore(score) } }
    private let onScore: (Int) -> Void

    private var lastTime: TimeInterval?
    private var playerPos = SIMD3<Float>(0, 0, 0)

    private var beacons: [ChunkKey: [SCNNode]] = [:]
    private var obstacles = FirstPersonObstacleField(cfg: Config())

    private var lookYaw: Float { look.yaw }

    // MARK: Setup

    private func setupView(_ v: SCNView) {
        v.scene = scene
        v.isPlaying = true
        v.isJitteringEnabled = false
        v.antialiasingMode = .none
        v.rendersContinuously = true
        v.backgroundColor = .black

        // IBL so PBR/matte materials aren’t black on the unlit side.
        let ibl = SceneKitHelpers.skyEquirectGradient(width: 512, height: 256)
        scene.lightingEnvironment.contents = ibl
        scene.lightingEnvironment.intensity = 1.0
        // Also use as background so gaps never look like voids.
        scene.background.contents = ibl
    }

    private func setupSceneIfNeeded() {
        if sceneRoot.parent == nil {
            scene.rootNode.addChildNode(sceneRoot)
            sceneRoot.name = "WorldRoot"
        }

        if playerNode.parent == nil {
            scene.rootNode.addChildNode(playerNode)
            playerNode.addChildNode(pitchNode)
            pitchNode.addChildNode(cameraNode)
            pitchNode.position = SCNVector3(0, config.eyeHeight, 0)
            updateTransforms()
        }
    }

    // MARK: Lighting + HDR sun

    private func makeLighting() {
        // Directional sunlight kept moderate; HDR look comes from the sun sprite.
        let light = SCNLight()
        light.type = .directional
        light.color = UIColor.white
        light.intensity = 1400

        light.castsShadow = true
        light.shadowMode = .deferred
        light.shadowRadius = 2.0
        light.shadowSampleCount = 4
        light.shadowMapSize = CGSize(width: 1024, height: 1024)
        light.shadowBias = 0.02

        let sun = SCNNode()
        sun.light = light

        let az = deg2rad(config.sunAzimuthDeg)
        let el = deg2rad(config.sunElevationDeg)
        sun.eulerAngles = SCNVector3(el, az, 0)
        scene.rootNode.addChildNode(sun)

        // Soft ambient fill so backsides aren’t black.
        let amb = SCNLight()
        amb.type = .ambient
        amb.intensity = 400
        amb.color = UIColor(white: 1.0, alpha: 1.0)
        scene.rootNode.addChildNode(SCNNode()).light = amb

        // Visible HDR sun disc (billboard sprite from Sky/)
        sunBillboard?.removeFromParentNode()
        let sprite = SunBillboard.makeNode(
            diameterWorld: 24,
            emissionIntensity: 10.0 // ensures bloom
        )
        scene.rootNode.addChildNode(sprite)
        sunBillboard = sprite
        updateSunBillboardPosition()
    }

    // MARK: Sky (billboard impostors; all logic in Sky/)

    private func makeSkyBillboards() {
        skyNode?.removeFromParentNode()

        let radius: CGFloat = 1200
        CloudBillboardLayer.makeAsync(
            radius: radius,
            minAltitudeY: 0.12,
            clusterCount: 140,
            seed: 0xC10D5
        ) { [weak self] node in
            guard let self else { return }

            // Pass sun direction to the cloud materials for backlight.
            let d = self.sunDirection()
            node.enumerateChildNodes { c, _ in
                if let g = c.geometry, let m = g.firstMaterial {
                    m.setValue(SCNVector3(d.x, d.y, d.z), forKey: "sunDirWorld")
                }
            }

            self.skyNode = node
            self.scene.rootNode.addChildNode(node)
        }
    }

    // MARK: Lifecycle helpers

    private func clearWorld() {
        streamer = nil
        obstacles.clear()
        for (_, arr) in beacons { for n in arr { n.removeFromParentNode() } }
        beacons.removeAll(keepingCapacity: true)

        for n in terrainRoot.childNodes { n.removeFromParentNode() }
        terrainRoot.removeFromParentNode()

        skyNode?.removeFromParentNode()
        skyNode = nil

        sunBillboard?.removeFromParentNode()
        sunBillboard = nil
    }

    private func updateTransforms() {
        playerNode.position = SCNVector3(x: playerPos.x, y: playerPos.y, z: playerPos.z)
        look.apply(to: playerNode, pitchNode: pitchNode)
    }

    private func tallyBeacons() {
        let rPlayer = config.playerRadius
        var gained = 0

        for (k, arr) in beacons {
            var keep: [SCNNode] = []
            keep.reserveCapacity(arr.count)

            for n in arr {
                let w = n.worldPosition
                let dx = Float(w.x) - playerPos.x
                let dz = Float(w.z) - playerPos.z
                let br = (n.value(forKey: "hitRadius") as? CGFloat).map { Float($0) } ?? 0.18
                let rr = rPlayer + br + 0.12
                if dx*dx + dz*dz <= rr * rr {
                    n.removeFromParentNode()
                    gained += 1
                } else {
                    keep.append(n)
                }
            }
            beacons[k] = keep
        }
        if gained > 0 { score += gained }
    }

    private func keyFor(position p: SCNVector3) -> ChunkKey {
        let tX = Int(floor(Double(p.x) / Double(config.tileSize)))
        let tZ = Int(floor(Double(p.z) / Double(config.tileSize)))

        func floorDiv(_ a: Int, _ b: Int) -> Int {
            a >= 0 ? a / b : ((a + 1) / b - 1)
        }
        return ChunkKey(x: floorDiv(tX, config.tilesX), y: floorDiv(tZ, config.tilesZ))
    }

    // MARK: Sun helpers

    private func sunDirection() -> simd_float3 {
        let az = deg2rad(config.sunAzimuthDeg)
        let el = deg2rad(config.sunElevationDeg)
        let d = simd_float3(sinf(az) * cosf(el), sinf(el), cosf(az) * cosf(el))
        return simd_normalize(d)
    }

    private func updateSunBillboardPosition() {
        guard let sunBillboard else { return }
        let d = sunDirection()
        let dist: Float = 1400
        let pos = SIMD3<Float>(
            playerPos.x + d.x * dist,
            playerPos.y + d.y * dist,
            playerPos.z + d.z * dist
        )
        sunBillboard.position = SCNVector3(pos)
    }

    @inline(__always) private func deg2rad(_ v: Float) -> Float { v * .pi / 180 }
}

// MARK: - Tuning

extension FirstPersonEngine {
    struct Config {
        // World grid
        var tileSize: Float = 1.5
        var tilesX: Int = 24
        var tilesZ: Int = 24
        var heightScale: Float = 3.8

        // Streaming
        var preloadRadius: Int = 2
        var tasksPerFrame: Int = 2

        // Camera/player
        var eyeHeight: Float = 1.62
        var playerRadius: Float = 0.22
        var moveSpeed: Float = 3.2
        var lookSensitivityRadPerPoint: Float = 0.0030
        var maxPitchRadians: Float = .pi * 0.42

        // Sky/sun
        var skyTextureWidth: Int = 1024
        var skyTextureHeight: Int = 512
        var skyCoverage: Float = 0.34
        var skyEdgeSoftness: Float = 0.22
        var sunAzimuthDeg: Float = 30
        var sunElevationDeg: Float = 55
    }
}
 
