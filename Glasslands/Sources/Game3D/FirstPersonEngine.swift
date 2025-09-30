//
//  FirstPersonEngine.swift
//  Glasslands
//
//  Created by . . on 9/30/25.
//
//  Camera + movement + world hookup.
//  - Seamless sky (two domes).
//  - Visible round sun (billboarded disc; reads depth so it hides behind the horizon).
//  - Huge terrain scale.
//  - Ground clamp uses the same sampler the mesh uses.
//

import Foundation
import SceneKit
import GameplayKit
import simd
import UIKit

final class FirstPersonEngine: NSObject {

    // MARK: - Config
    struct Config {
        // --- World scale (big distances)
        // Each “tile” now spans many metres. With the larger noise scales (see NoiseFields)
        // this yields very broad hills so it takes minutes to reach the next one.
        let tileSize: Float = 16.0         // was ~2.0
        let heightScale: Float = 24.0      // vertical exaggeration kept modest so terrain feels flat locally

        // Mesh resolution per chunk (keep vertex count sane)
        let chunkTiles = IVec2(64, 64)

        // How many chunks in a square radius to keep around the player
        let preloadRadius: Int = 3         // show a truly distant horizon

        // Player & camera
        let moveSpeed: Float = 6.0
        let eyeHeight: Float = 1.62
        let maxDescentRate: Float = 8.0

        var tilesX: Int { chunkTiles.x }
        var tilesZ: Int { chunkTiles.y }
    }
    let cfg = Config()

    // MARK: - Scene
    private var scene = SCNScene()
    private weak var scnView: SCNView?
    private var recipe: BiomeRecipe!
    private var noise: NoiseFields!
    private var chunker: ChunkStreamer3D!

    // Camera rig
    private let yawNode = SCNNode()
    private let pitchNode = SCNNode()
    private let camNode = SCNNode()

    // Sky
    private let skyAnchor = SCNNode()
    private var skyGradientDome: SCNNode?
    private var cloudDome: SCNNode?
    private var sunDiscNode: SCNNode?
    private var sunLightNode: SCNNode?

    // Input
    private var moveInput = SIMD2<Float>(repeating: 0)
    private var yaw: Float = 0
    private var pitch: Float = -0.1

    // Time
    private var lastTime: TimeInterval = 0

    // Scoring
    private var beacons = Set<SCNNode>()
    private var score = 0
    private var onScore: (Int) -> Void

    // MARK: - Init/attach
    init(onScore: @escaping (Int) -> Void) {
        self.onScore = onScore
        super.init()
    }

    func attach(to view: SCNView, recipe: BiomeRecipe) {
        scnView = view
        view.scene = scene
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 60
        view.rendersContinuously = true
        view.backgroundColor = .black

        scene.physicsWorld.gravity = SCNVector3(0, 0, 0)

        buildLighting()
        buildSky()
        apply(recipe: recipe, force: true)
    }

    func setPaused(_ paused: Bool) {
        scnView?.isPlaying = !paused
    }

    func setMoveInput(_ v: SIMD2<Float>) {
        moveInput = v
    }

    func addLook(yawDegrees: Float, pitchDegrees: Float) {
        yaw += yawDegrees * Float.pi / 180
        pitch += pitchDegrees * Float.pi / 180
        pitch = max(-Float.pi/2 + 0.01, min(Float.pi/2 - 0.01, pitch))
        updateRig()
    }

    func apply(recipe: BiomeRecipe, force: Bool = false) {
        if !force, let r = self.recipe, r == recipe { return }
        self.recipe = recipe
        noise = NoiseFields(recipe: recipe)
        resetWorld()
    }

    @MainActor
    func snapshot() -> UIImage? { scnView?.snapshot() }

    // MARK: - Frame stepping (called by RendererProxy)
    @MainActor
    func stepUpdateMain(at t: TimeInterval) {
        let dt: Float = (lastTime == 0) ? 1/60 : Float(min(1/30, max(0, t - lastTime)))
        lastTime = t

        // Move along ground plane
        let forward = SIMD3(-sinf(yaw), 0, -cosf(yaw))
        let right   = SIMD3( cosf(yaw), 0, -sinf(yaw))
        let delta = (right * moveInput.x + forward * moveInput.y) * (cfg.moveSpeed * dt)

        var pos = yawNode.simdPosition
        pos += delta

        // Ground clamp using the exact same sampler the mesh uses
        let groundY = groundHeightFootprint(worldX: pos.x, z: pos.z)
        let targetY = groundY + cfg.eyeHeight
        if !targetY.isFinite {
            pos = spawn().simd
        } else if pos.y <= targetY {
            pos.y = targetY
        } else {
            let maxDrop = cfg.maxDescentRate * dt
            pos.y = max(targetY, pos.y - maxDrop)
        }
        yawNode.simdPosition = pos

        // Keep the sky centred on the player
        skyAnchor.simdPosition = pos

        // Stream chunks + collect beacons
        chunker.updateVisible(center: pos)
        collectNearbyBeacons(playerXZ: SIMD2(pos.x, pos.z))
    }

    // MARK: - Build scene

    private func resetWorld() {
        scene.rootNode.childNodes.forEach { $0.removeFromParentNode() }

        buildLighting()
        buildSky()

        // Camera
        yaw = 0; pitch = -0.1
        yawNode.position = spawn()
        updateRig()

        let camera = SCNCamera()
        camera.zNear = 0.02
        camera.zFar  = 20_000         // much more distant horizon
        camera.fieldOfView = 70
        camNode.camera = camera

        pitchNode.addChildNode(camNode)
        yawNode.addChildNode(pitchNode)
        scene.rootNode.addChildNode(yawNode)
        scnView?.pointOfView = camNode

        // Terrain
        chunker = ChunkStreamer3D(cfg: cfg, noise: noise, recipe: recipe, root: scene.rootNode) { [weak self] b in
            guard let self else { return }
            b.forEach { self.beacons.insert($0) }
        }
        chunker.buildAround(yawNode.simdPosition)

        // Score reset
        score = 0
        DispatchQueue.main.async { [score, onScore] in onScore(score) }
    }

    private func buildLighting() {
        // Ambient
        let amb = SCNLight()
        amb.type = .ambient
        amb.intensity = 450
        amb.color = UIColor(white: 0.94, alpha: 1)
        let ambNode = SCNNode(); ambNode.light = amb
        scene.rootNode.addChildNode(ambNode)

        // Sun (directional)
        let sun = SCNLight()
        sun.type = .directional
        sun.intensity = 1200
        sun.castsShadow = true
        sun.shadowMode  = .deferred
        sun.shadowRadius = 4
        sun.shadowColor  = UIColor.black.withAlphaComponent(0.33)

        let sunNode = SCNNode()
        sunNode.light = sun
        // Elevation + azimuth (60° up, 45° azimuth)
        sunNode.eulerAngles = SCNVector3(-Float.pi/3, Float.pi/4, 0)
        scene.rootNode.addChildNode(sunNode)
        self.sunLightNode = sunNode
    }

    private func buildSky() {
        // Remove old
        skyAnchor.removeFromParentNode()
        skyAnchor.childNodes.forEach { $0.removeFromParentNode() }
        scene.background.contents = nil
        sunDiscNode = nil
        skyGradientDome = nil
        cloudDome = nil

        // Sky anchor follows the player
        scene.rootNode.addChildNode(skyAnchor)

        // Base gradient dome (no seams)
        let baseSphere = SCNSphere(radius: 5000) // big so it feels infinitely far
        baseSphere.segmentCount = 96

        let skyMat = SCNMaterial()
        skyMat.lightingModel = .constant
        skyMat.isDoubleSided = true
        skyMat.cullMode = .front
        skyMat.diffuse.contents = skyGradientEquirect(width: 2048, height: 1024)
        skyMat.writesToDepthBuffer = false
        skyMat.readsFromDepthBuffer = false
        skyMat.diffuse.wrapS = .repeat
        skyMat.diffuse.wrapT = .clamp
        skyMat.diffuse.mipFilter = .linear
        baseSphere.firstMaterial = skyMat

        let baseNode = SCNNode(geometry: baseSphere)
        baseNode.renderingOrder = -20
        skyAnchor.addChildNode(baseNode)
        self.skyGradientDome = baseNode

        // Cloud dome (horizontally seamless; fade near the poles to avoid zenith seams)
        let sphere = SCNSphere(radius: 4800)
        sphere.segmentCount = 128

        let cloudMat = SCNMaterial()
        cloudMat.lightingModel = .constant
        cloudMat.isDoubleSided = true
        cloudMat.cullMode = .front
        cloudMat.diffuse.contents = cloudsEquirect(width: 4096, height: 2048)
        cloudMat.transparency = 1.0
        cloudMat.writesToDepthBuffer = false
        cloudMat.readsFromDepthBuffer = false
        cloudMat.diffuse.wrapS = .repeat     // key for no vertical seam
        cloudMat.diffuse.wrapT = .clamp
        cloudMat.diffuse.mipFilter = .linear
        cloudMat.diffuse.minificationFilter = .linear
        cloudMat.diffuse.magnificationFilter = .linear
        sphere.firstMaterial = cloudMat

        let cloudNode = SCNNode(geometry: sphere)
        cloudNode.name = "cloudDome"
        cloudNode.renderingOrder = -10
        skyAnchor.addChildNode(cloudNode)
        self.cloudDome = cloudNode

        // Slow drift
        cloudNode.runAction(.repeatForever(.rotateBy(x: 0, y: 0.02, z: 0, duration: 60)))

        // Visible sun disc aligned with the light direction
        if let sunLightNode {
            let discSize: CGFloat = 80.0
            let plane = SCNPlane(width: discSize, height: discSize)
            plane.cornerRadius = discSize * 0.5    // geometry is actually round

            let sunMat = SCNMaterial()
            sunMat.lightingModel = .constant
            sunMat.isDoubleSided = true
            sunMat.emission.contents = sunImage(diameter: 512)
            sunMat.blendMode = .add
            sunMat.writesToDepthBuffer = false
            sunMat.readsFromDepthBuffer = true      // ← hides behind the horizon properly
            plane.firstMaterial = sunMat

            let sunDisc = SCNNode(geometry: plane)
            sunDisc.name = "sunDisc"
            sunDisc.renderingOrder = -15            // behind the cloud dome (-10) so clouds can sit “in front”

            // Always face the camera
            let bb = SCNBillboardConstraint()
            bb.freeAxes = [] // face on all axes
            sunDisc.constraints = [bb]

            // Place opposite the light direction at a fixed distance
            // SceneKit's "front" is -Z; the light shines along its front vector,
            // so the visible sun is the opposite of that.
            let dirToSun = -sunLightNode.presentation.simdWorldFront
            let distance: Float = 4500
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

    private func spawn() -> SCNVector3 {
        let ts = cfg.tileSize

        func isWalkable(tx: Int, tz: Int) -> Bool {
            let h = noise.sampleHeight(Double(tx), Double(tz)) / max(0.0001, recipe.height.amplitude)
            let s = noise.slope(Double(tx), Double(tz))
            let r = noise.riverMask(Double(tx), Double(tz))
            if h < 0.28 { return false }   // water
            if s > 0.35 { return false }   // too steep
            if r > 0.60 { return false }   // river channel
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

    /// Samples a small "footprint" (cross) and returns the **highest** contact.
    private func groundHeightFootprint(worldX x: Float, z: Float) -> Float {
        let r: Float = 0.35
        let h0 = TerrainMath.heightWorld(x: x, z: z, cfg: cfg, noise: noise)
        let h1 = TerrainMath.heightWorld(x: x - r, z: z - r, cfg: cfg, noise: noise)
        let h2 = TerrainMath.heightWorld(x: x + r, z: z - r, cfg: cfg, noise: noise)
        let h3 = TerrainMath.heightWorld(x: x - r, z: z + r, cfg: cfg, noise: noise)
        let h4 = TerrainMath.heightWorld(x: x + r, z: z + r, cfg: cfg, noise: noise)
        return max(h0, h1, h2, h3, h4)
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
