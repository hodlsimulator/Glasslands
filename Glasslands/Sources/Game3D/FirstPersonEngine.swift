//
//  FirstPersonEngine.swift
//  Glasslands
//
//  Created by . . on 9/30/25.
//
//  Updated: stream chunks off-thread + prewarm before attach.
//

import SceneKit
import GameplayKit
import simd
import UIKit

final class FirstPersonEngine: NSObject {
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

    private var scene = SCNScene()
    private weak var scnView: SCNView?

    private var recipe: BiomeRecipe!
    private var noise: NoiseFields!
    private var chunker: ChunkStreamer3D!

    private let yawNode = SCNNode()
    private let pitchNode = SCNNode()
    private let camNode = SCNNode()

    private var moveInput = SIMD2<Float>(repeating: 0)

    // Accumulate swipe deltas (UIKit points) — no inertia
    private var pendingLookDeltaPts = SIMD2<Float>(repeating: 0)

    private var yaw: Float = 0
    private var pitch: Float = -0.1

    private let skyAnchor = SCNNode()
    private var sunDiscNode: SCNNode?
    private var sunLightNode: SCNNode?

    private var lastTime: TimeInterval = 0
    private var beacons = Set<SCNNode>()
    private var score = 0
    private var onScore: (Int) -> Void

    private struct Obstacle { weak var node: SCNNode?; let position: SIMD2<Float>; let radius: Float }
    private var obstaclesByChunk: [IVec2: [Obstacle]] = [:]

    init(onScore: @escaping (Int) -> Void) {
        self.onScore = onScore
        super.init()
    }

    func attach(to view: SCNView, recipe: BiomeRecipe) {
        scnView = view
        view.scene = scene
        view.antialiasingMode = .none
        view.preferredFramesPerSecond = 60
        view.rendersContinuously = true
        view.backgroundColor = .black

        scene.physicsWorld.gravity = SCNVector3(0, 0, 0)
        buildLighting()
        buildSky()

        apply(recipe: recipe, force: true)
    }

    func setPaused(_ paused: Bool) { scnView?.isPlaying = !paused }

    func setMoveInput(_ v: SIMD2<Float>) { moveInput = v }

    func setLookRate(_ _: SIMD2<Float>) { }

    // FIX: use += (not &+=) for floats
    func applyLookDelta(points: SIMD2<Float>) {
        pendingLookDeltaPts += points
    }

    func apply(recipe: BiomeRecipe, force: Bool = false) {
        if !force, let r = self.recipe, r == recipe { return }
        self.recipe = recipe
        noise = NoiseFields(recipe: recipe)
        resetWorld()
    }

    @MainActor
    func snapshot() -> UIImage? { scnView?.snapshot() }

    @MainActor
    func stepUpdateMain(at t: TimeInterval) {
        let sp = Signposts.begin("Frame"); defer { Signposts.end("Frame", sp) }

        let dt: Float = (lastTime == 0) ? 1/60 : Float(min(1/30, max(0, t - lastTime)))
        lastTime = t

        if pendingLookDeltaPts != .zero {
            let yawRadPerPt   = cfg.swipeYawDegPerPt   * (.pi / 180)
            let pitchRadPerPt = cfg.swipePitchDegPerPt * (.pi / 180)
            yaw   -= pendingLookDeltaPts.x * yawRadPerPt
            pitch -= pendingLookDeltaPts.y * pitchRadPerPt
            pendingLookDeltaPts = .zero
            clampAngles()
        }

        updateRig()

        let forward = SIMD3<Float>(-sinf(yaw), 0, -cosf(yaw))
        let right   = SIMD3<Float>( cosf(yaw), 0, -sinf(yaw))
        let attemptedDelta = (right * moveInput.x + forward * moveInput.y) * (cfg.moveSpeed * dt)
        var next = yawNode.simdPosition + attemptedDelta

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

        next = resolveObstacleCollisions(position: next)

        yawNode.simdPosition = next
        skyAnchor.simdPosition = next

        chunker.updateVisible(center: next)
        collectNearbyBeacons(playerXZ: SIMD2(next.x, next.z))
    }

    private func resetWorld() {
        scene.rootNode.childNodes.forEach { $0.removeFromParentNode() }
        beacons.removeAll()
        obstaclesByChunk.removeAll()

        buildLighting()
        buildSky()

        yaw = 0
        pitch = -0.08

        yawNode.position = spawn()
        updateRig()

        let camera = SCNCamera()
        camera.zNear = 0.02
        camera.zFar = 20_000
        camera.fieldOfView = 70
        camNode.camera = camera

        pitchNode.addChildNode(camNode)
        yawNode.addChildNode(pitchNode)
        scene.rootNode.addChildNode(yawNode)
        scnView?.pointOfView = camNode

        chunker = ChunkStreamer3D(
            cfg: cfg,
            noise: noise,
            recipe: recipe,
            root: scene.rootNode,
            renderer: scnView!,
            beaconSink: { [weak self] beacons in
                beacons.forEach { self?.beacons.insert($0) }
            },
            obstacleSink: { [weak self] chunk, nodes in
                self?.registerObstacles(for: chunk, from: nodes)
            },
            onChunkRemoved: { [weak self] chunk in
                self?.obstaclesByChunk.removeValue(forKey: chunk)
            }
        )

        chunker.warmupCenter(at: yawNode.simdPosition)

        score = 0
        DispatchQueue.main.async { [score, onScore] in onScore(score) }
    }

    private func buildLighting() {
        let amb = SCNLight()
        amb.type = .ambient
        amb.intensity = 450
        amb.color = UIColor(white: 0.94, alpha: 1)
        let ambNode = SCNNode(); ambNode.light = amb
        scene.rootNode.addChildNode(ambNode)

        let sun = SCNLight()
        sun.type = .directional
        sun.intensity = 1350
        sun.castsShadow = false
        let sunNode = SCNNode(); sunNode.light = sun
        sunNode.eulerAngles = SCNVector3(-1.31, .pi/4, 0)
        scene.rootNode.addChildNode(sunNode)
        self.sunLightNode = sunNode
    }

    private func buildSky() {
        skyAnchor.removeFromParentNode()
        skyAnchor.childNodes.forEach { $0.removeFromParentNode() }
        scene.rootNode.addChildNode(skyAnchor)
        sunDiscNode = nil

        scene.background.contents = SceneKitHelpers.skyboxImages(size: 1024)

        if let sunLightNode {
            let discSize: CGFloat = 260.0
            let plane = SCNPlane(width: discSize, height: discSize)
            plane.cornerRadius = discSize * 0.5

            let sunMat = SCNMaterial()
            sunMat.lightingModel = .constant
            sunMat.isDoubleSided = true
            sunMat.emission.contents = SceneKitHelpers.sunImage(diameter: 512)
            sunMat.blendMode = .add
            sunMat.writesToDepthBuffer = false
            sunMat.readsFromDepthBuffer = true
            plane.firstMaterial = sunMat

            let sunDisc = SCNNode(geometry: plane)
            sunDisc.name = "sunDisc"
            sunDisc.renderingOrder = -15

            let bb = SCNBillboardConstraint(); bb.freeAxes = []
            sunDisc.constraints = [bb]

            let dirToSun = -sunLightNode.presentation.simdWorldFront
            let distance = cfg.skyDistance - 180
            sunDisc.simdPosition = simd_normalize(dirToSun) * distance

            skyAnchor.addChildNode(sunDisc)
            self.sunDiscNode = sunDisc
        }
    }

    private func updateRig() {
        yawNode.eulerAngles = SCNVector3(0, yaw, 0)
        pitchNode.eulerAngles = SCNVector3(pitch, 0, 0)
        camNode.position = SCNVector3(0, 0, 0)
    }

    private func clampAngles() {
        pitch = max(-.pi/2 + 0.01, min(.pi/2 - 0.01, pitch))
        if yaw > .pi { yaw -= 2 * .pi }
        else if yaw < -.pi { yaw += 2 * .pi }
    }

    private func spawn() -> SCNVector3 {
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

        return SCNVector3(0, TerrainMath.heightWorld(x: 0, z: 0, cfg: cfg, noise: noise) + cfg.eyeHeight, 0)
    }

    private func groundHeightFootprint(worldX x: Float, z: Float) -> Float {
        let r: Float = 0.35
        let h0 = TerrainMath.heightWorld(x: x, z: z, cfg: cfg, noise: noise)
        let h1 = TerrainMath.heightWorld(x: x - r, z: z - r, cfg: cfg, noise: noise)
        let h2 = TerrainMath.heightWorld(x: x + r, z: z - r, cfg: cfg, noise: noise)
        let h3 = TerrainMath.heightWorld(x: x - r, z: z + r, cfg: cfg, noise: noise)
        let h4 = TerrainMath.heightWorld(x: x + r, z: z + r, cfg: cfg, noise: noise)
        return max(h0, h1, h2, h3, h4)
    }

    private func registerObstacles(for chunk: IVec2, from nodes: [SCNNode]) {
        var obs: [Obstacle] = []
        obs.reserveCapacity(nodes.count)
        for n in nodes {
            let p = n.worldPosition
            let r = (n.value(forKey: "hitRadius") as? CGFloat).map { Float($0) } ?? 0.5
            obs.append(Obstacle(node: n, position: SIMD2(Float(p.x), Float(p.z)), radius: r))
        }
        obstaclesByChunk[chunk] = obs
    }

    private func resolveObstacleCollisions(position p: SIMD3<Float>) -> SIMD3<Float> {
        var pos = p
        let pr = cfg.playerRadius
        let ci = chunkIndex(forWorldX: pos.x, z: pos.z)

        for dz in -1...1 {
            for dx in -1...1 {
                let key = IVec2(ci.x + dx, ci.y + dz)
                guard let arr = obstaclesByChunk[key], !arr.isEmpty else { continue }
                for o in arr {
                    guard let _ = o.node else { continue }
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

    private func chunkIndex(forWorldX x: Float, z: Float) -> IVec2 {
        let tX = Int(floor(Double(x) / Double(cfg.tileSize)))
        let tZ = Int(floor(Double(z) / Double(cfg.tileSize)))
        return IVec2(floorDiv(tX, cfg.tilesX), floorDiv(tZ, cfg.tilesZ))
    }

    private func floorDiv(_ a: Int, _ b: Int) -> Int {
        a >= 0 ? a / b : ((a + 1) / b - 1)
    }

    private func collectNearbyBeacons(playerXZ: SIMD2<Float>) {
        var picked: [SCNNode] = []
        for n in beacons {
            let p = n.worldPosition
            let dx = playerXZ.x - p.x
            let dz = playerXZ.y - p.z
            if dx*dx + dz*dz < 1.25 * 1.25 {
                picked.append(n)
            }
        }
        if !picked.isEmpty {
            picked.forEach { $0.removeAllActions(); $0.removeFromParentNode(); beacons.remove($0) }
            score += picked.count
            DispatchQueue.main.async { [score, onScore] in onScore(score) }
        }
    }
}
