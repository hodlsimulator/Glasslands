//
//  FirstPersonEngine.swift
//  Glasslands
//
//  Created by . . on 9/30/25.
//
//  Camera + movement + world hookup.
//  Adds a visible sun disc and a lightweight cloud dome.
//

import Foundation
import SceneKit
import GameplayKit
import simd
import UIKit

final class FirstPersonEngine: NSObject {
    // MARK: Config
    struct Config {
        let tileSize: Float = 2.0     // world metres per tile
        let heightScale: Float = 8.0  // world metres per height unit

        let chunkTiles = IVec2(64, 64)
        let preloadRadius: Int = 2

        let moveSpeed: Float = 6.0
        let eyeHeight: Float = 1.62

        var tilesX: Int { chunkTiles.x }
        var tilesZ: Int { chunkTiles.y }
    }
    let cfg = Config()

    // MARK: Scene
    private var scene = SCNScene()
    private weak var scnView: SCNView?

    private var recipe: BiomeRecipe!
    private var noise: NoiseFields!
    private var chunker: ChunkStreamer3D!

    // Camera rig
    private let yawNode = SCNNode()
    private let pitchNode = SCNNode()
    private let camNode = SCNNode()

    // Sky bits
    private let skyAnchor = SCNNode()
    private var cloudDome: SCNNode?
    private var sunVisualPivot: SCNNode?
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

    // MARK: Init/attach
    init(onScore: @escaping (Int) -> Void) {
        self.onScore = onScore
        super.init()
    }

    func attach(to view: SCNView, recipe: BiomeRecipe) {
        scnView = view
        view.scene = scene

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
        noise = NoiseFields(recipe: recipe) // flatter noise (see NoiseFields.swift)
        resetWorld()
    }

    @MainActor
    func snapshot() -> UIImage? { scnView?.snapshot() }

    // MARK: Frame stepping (called by RendererProxy)
    @MainActor
    func stepUpdateMain(at t: TimeInterval) {
        let dt: Float = (lastTime == 0) ? 1/60 : Float(min(1/30, max(0, t - lastTime)))
        lastTime = t

        // Move along ground plane
        let forward = SIMD3(-sinf(yaw), 0, -cosf(yaw))
        let right   = SIMD3( cosf(yaw), 0, -sinf(yaw))
        let delta   = (right * moveInput.x + forward * moveInput.y) * (cfg.moveSpeed * dt)

        var pos = yawNode.simdPosition
        pos += delta
        pos.y = sampleHeight(worldX: pos.x, z: pos.z) + cfg.eyeHeight
        yawNode.simdPosition = pos

        // Keep sky centred on the player (infinite-distance effect)
        skyAnchor.simdPosition = pos

        // Stream chunks + collect beacons
        chunker.updateVisible(center: pos)
        collectNearbyBeacons(playerXZ: SIMD2(pos.x, pos.z))
    }

    // MARK: Build scene
    private func resetWorld() {
        scene.rootNode.childNodes.forEach { $0.removeFromParentNode() }

        buildLighting()
        buildSky()

        // Camera
        yaw = 0; pitch = -0.1
        yawNode.position = spawn()
        updateRig()

        let camera = SCNCamera()
        camera.zNear = 0.01
        camera.zFar  = 5000
        camera.fieldOfView = 70
        camNode.camera = camera

        pitchNode.addChildNode(camNode)
        yawNode.addChildNode(pitchNode)
        scene.rootNode.addChildNode(yawNode)
        scnView?.pointOfView = camNode

        // Terrain streamer (3D)
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
        amb.intensity = 400
        amb.color = UIColor(white: 0.92, alpha: 1)
        let ambNode = SCNNode(); ambNode.light = amb
        scene.rootNode.addChildNode(ambNode)

        // Sun (directional)
        let sun = SCNLight()
        sun.type = .directional
        sun.intensity = 1100
        sun.castsShadow = true
        sun.shadowMode = .deferred
        sun.shadowRadius = 4
        sun.shadowColor = UIColor.black.withAlphaComponent(0.35)
        let sunNode = SCNNode(); sunNode.light = sun
        sunNode.eulerAngles = SCNVector3(-Float.pi/3, Float.pi/4, 0) // elevation + azimuth
        scene.rootNode.addChildNode(sunNode)
        self.sunLightNode = sunNode
    }

    private func buildSky() {
        // Clean up (in case of rebuild)
        skyAnchor.removeFromParentNode()
        skyAnchor.childNodes.forEach { $0.removeFromParentNode() }
        cloudDome = nil
        sunVisualPivot = nil

        // Subtle blue gradient background (fallback behind geometry)
        let top = UIColor(red: 0.50, green: 0.74, blue: 0.92, alpha: 1)
        let mid = UIColor(red: 0.72, green: 0.86, blue: 0.96, alpha: 1)
        let img = gradientImage(top: top, bottom: mid, height: 512)
        scene.background.contents = img

        // Anchor that follows the player (but does not rotate with yaw/pitch)
        scene.rootNode.addChildNode(skyAnchor)

        // Cloud dome (large inward-facing sphere)
        let sphere = SCNSphere(radius: 800)
        sphere.segmentCount = 48

        let cloudMat = SCNMaterial()
        cloudMat.lightingModel = .constant
        cloudMat.isDoubleSided = true
        cloudMat.cullMode = .front // render inside of sphere
        cloudMat.diffuse.contents = cloudsImage(size: 1024)
        cloudMat.transparency = 0.82
        cloudMat.writesToDepthBuffer = false
        cloudMat.readsFromDepthBuffer = false

        sphere.firstMaterial = cloudMat

        let cloudNode = SCNNode(geometry: sphere)
        cloudNode.name = "cloudDome"
        cloudNode.renderingOrder = -1 // draw first
        skyAnchor.addChildNode(cloudNode)
        self.cloudDome = cloudNode

        // Slow drift
        let spin = SCNAction.repeatForever(.rotateBy(x: 0, y: 0.03, z: 0, duration: 60))
        cloudNode.runAction(spin)

        // Visible sun disc aligned with the sun light direction
        if let sunLightNode {
            let pivot = SCNNode()
            pivot.eulerAngles = sunLightNode.eulerAngles

            let d: CGFloat = 12.0
            let plane = SCNPlane(width: d, height: d)
            let sunMat = SCNMaterial()
            sunMat.lightingModel = .constant
            sunMat.isDoubleSided = true
            sunMat.emission.contents = sunImage(diameter: 256)
            sunMat.writesToDepthBuffer = false
            sunMat.readsFromDepthBuffer = false
            plane.firstMaterial = sunMat

            let sunDisc = SCNNode(geometry: plane)
            sunDisc.position = SCNVector3(0, 0, -400) // along -Z of pivot (towards light direction)
            sunDisc.constraints = [SCNBillboardConstraint()] // always face camera

            pivot.addChildNode(sunDisc)
            skyAnchor.addChildNode(pivot)
            self.sunVisualPivot = pivot
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
            return SCNVector3(ts * 0.5, sampleHeight(worldX: 0, z: 0) + cfg.eyeHeight, ts * 0.5)
        }

        for radius in 1...32 {
            for z in -radius...radius {
                for x in -radius...radius where abs(x) == radius || abs(z) == radius {
                    if isWalkable(tx: x, tz: z) {
                        let wx = Float(x) * ts + ts * 0.5
                        let wz = Float(z) * ts + ts * 0.5
                        return SCNVector3(wx, sampleHeight(worldX: wx, z: wz) + cfg.eyeHeight, wz)
                    }
                }
            }
        }

        return SCNVector3(0, sampleHeight(worldX: 0, z: 0) + cfg.eyeHeight, 0)
    }

    private func sampleHeight(worldX x: Float, z: Float) -> Float {
        let tx = Double(x) / Double(cfg.tileSize)
        let tz = Double(z) / Double(cfg.tileSize)
        let h0 = noise.sampleHeight(tx, tz)
        let h1 = noise.sampleHeight(tx + 0.5, tz + 0.5)
        return Float((h0 * 0.7 + h1 * 0.3)) * cfg.heightScale
    }

    private func collectNearbyBeacons(playerXZ: SIMD2<Float>) {
        var picked: [SCNNode] = []
        for n in beacons {
            let p = n.worldPosition
            let dx = playerXZ.x - p.x
            let dz = playerXZ.y - p.z
            if dx*dx + dz*dz < 1.25 * 1.25 { picked.append(n) }
        }
        if !picked.isEmpty {
            picked.forEach { $0.removeAllActions(); $0.removeFromParentNode(); beacons.remove($0) }
            score += picked.count
            DispatchQueue.main.async { [score, onScore] in onScore(score) }
        }
    }
}
