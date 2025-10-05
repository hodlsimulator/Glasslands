//
//  FirstPersonEngine.swift
//  Glasslands
//
//  Created by . . on 9/30/25.
//
//  Updated: full engine restored; perf-safe view config; sky generator tuned for real gaps.
//

import SceneKit
import GameplayKit
import simd
import UIKit
import CoreGraphics
import QuartzCore

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
    private var pendingLookDeltaPts = SIMD2<Float>(repeating: 0)
    private var yaw: Float = 0
    private var pitch: Float = -0.1

    private let skyAnchor = SCNNode()
    private var sunDiscNode: SCNNode?
    private var sunLightNode: SCNNode?

    private var sunDirWorld: simd_float3 = simd_float3(0, 1, 0)

    private let cloudSunTint = simd_float3(1.00, 0.94, 0.82)
    private let cloudSunBacklight: CGFloat = 0.45
    private let cloudHorizonFade: CGFloat = 0.20

    private var lastTime: TimeInterval = 0

    private var beacons = Set<SCNNode>()
    private var score = 0
    private var onScore: (Int) -> Void
    
    private var vegSunLightNode: SCNNode?

    private struct Obstacle {
        weak var node: SCNNode?
        let position: SIMD2<Float>
        let radius: Float
    }
    private var obstaclesByChunk: [IVec2: [Obstacle]] = [:]

    init(onScore: @escaping (Int) -> Void) {
        self.onScore = onScore
        super.init()
    }

    // MARK: - Sun

    @inline(__always)
    private func sunDirection(azimuthDeg: Float, elevationDeg: Float) -> simd_float3 {
        let az = azimuthDeg * Float.pi / 180
        let el = elevationDeg * Float.pi / 180
        let x = sinf(az) * cosf(el)
        let y = sinf(el)
        let z = cosf(az) * cosf(el)
        return simd_normalize(simd_float3(x, y, z))
    }

    @MainActor
    private func applySunDirection(azimuthDeg: Float, elevationDeg: Float) {
        var dir = sunDirection(azimuthDeg: azimuthDeg, elevationDeg: elevationDeg)

        if let pov = (scnView?.pointOfView ?? camNode) as SCNNode? {
            let look = -pov.presentation.simdWorldFront
            if simd_dot(dir, look) < 0 { dir = -dir }
        }

        sunDirWorld = dir

        if let sunLightNode {
            let origin = yawNode.presentation.position
            let target = SCNVector3(origin.x + dir.x, origin.y + dir.y, origin.z + dir.z)
            sunLightNode.position = origin
            sunLightNode.look(at: target, up: scene.rootNode.worldUp, localFront: SCNVector3(0, 0, -1))
        }

        if let vegSunLightNode {
            let origin = yawNode.presentation.position
            let target = SCNVector3(origin.x + dir.x, origin.y + dir.y, origin.z + dir.z)
            vegSunLightNode.position = origin
            vegSunLightNode.look(at: target, up: scene.rootNode.worldUp, localFront: SCNVector3(0, 0, -1))
        }

        if let disc = sunDiscNode {
            let dist = CGFloat(cfg.skyDistance)
            disc.simdPosition = simd_float3(dir.x, dir.y, dir.z) * Float(dist)
        }

        applyCloudSunUniforms()
    }

    @MainActor
    private func applyCloudSunUniforms() {
        let sunW = simd_normalize(sunDirWorld)
        let tintV = SCNVector3(cloudSunTint.x, cloudSunTint.y, cloudSunTint.z)

        // Compute sun in view space once
        let pov = (scnView?.pointOfView ?? camNode).presentation
        let invView = simd_inverse(pov.simdWorldTransform)
        let sunView4 = invView * simd_float4(sunW, 0)          // w = 0 → direction
        let sunView  = simd_normalize(simd_float3(sunView4.x, sunView4.y, sunView4.z))
        let sunViewV = SCNVector3(sunView.x, sunView.y, sunView.z)

        // Billboards
        if let layer = skyAnchor.childNode(withName: "CumulusBillboardLayer", recursively: true) {
            layer.enumerateChildNodes { node, _ in
                guard let g = node.geometry else { return }
                for m in g.materials {
                    m.setValue(sunViewV, forKey: "sunDirView")
                    m.setValue(tintV,    forKey: "sunTint")
                    m.setValue(cloudSunBacklight, forKey: "sunBacklight")
                    m.setValue(cloudHorizonFade,  forKey: "horizonFade")
                }
            }
        }

        // Volumetric sphere
        let sphere =
            skyAnchor.childNode(withName: "VolumetricCloudLayer", recursively: false)
            ?? scene.rootNode.childNode(withName: "VolumetricCloudLayer", recursively: false)

        if let m = sphere?.geometry?.firstMaterial {
            m.setValue(sunViewV, forKey: "sunDirView")
            m.setValue(tintV,    forKey: "sunTint")
        }
    }

    // MARK: - Lifecycle

    func attach(to view: SCNView, recipe: BiomeRecipe) {
        scnView = view
        view.scene = scene
        view.antialiasingMode = .none
        view.isJitteringEnabled = false
        view.preferredFramesPerSecond = 60
        view.rendersContinuously = true
        view.isPlaying = true
        view.isOpaque = true
        view.backgroundColor = UIColor.black

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
    }

    func setPaused(_ paused: Bool) {
        scnView?.isPlaying = !paused
    }

    func setMoveInput(_ v: SIMD2<Float>) {
        moveInput = v
    }

    func setLookRate(_ _: SIMD2<Float>) { }

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
    func snapshot() -> UIImage? {
        scnView?.snapshot()
    }

    // MARK: - Per-frame

    @MainActor
    func stepUpdateMain(at t: TimeInterval) {
        let sp = Signposts.begin("Frame"); defer { Signposts.end("Frame", sp) }

        let dt: Float = (lastTime == 0) ? 1/60 : Float(min(1/30, max(0, t - lastTime)))
        lastTime = t

        if pendingLookDeltaPts != .zero {
            let yawRadPerPt = cfg.swipeYawDegPerPt * (Float.pi / 180)
            let pitchRadPerPt = cfg.swipePitchDegPerPt * (Float.pi / 180)
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

        if let sg = scene.rootNode.childNode(withName: "SafetyGround", recursively: false) {
            sg.simdPosition = simd_float3(next.x, groundY - 0.02, next.z)
        }
    }

    // MARK: - World

    @MainActor private func resetWorld() {
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

        // Keep HDR/EDR enabled so the sun can go “over 1.0”
        camera.wantsHDR = true
        camera.wantsExposureAdaptation = true
        camera.exposureOffset = 0.0
        camera.averageGray = 0.18
        camera.whitePoint = 1.0
        camera.minimumExposure = -1.0
        camera.maximumExposure = 2.0
        // Bloom only catches genuinely hot pixels (EDR sun), not SDR terrain
        camera.bloomThreshold = 1.15
        camera.bloomIntensity = 1.25
        camera.bloomBlurRadius = 12.0

        camNode.camera = camera
        pitchNode.addChildNode(camNode)
        yawNode.addChildNode(pitchNode)
        scene.rootNode.addChildNode(yawNode)
        scnView?.pointOfView = camNode

        addSafetyGround(at: yawNode.simdPosition)

        chunker = ChunkStreamer3D(
            cfg: cfg,
            noise: noise,
            recipe: recipe,
            root: scene.rootNode,
            renderer: scnView!,
            beaconSink: { [weak self] beacons in beacons.forEach { self?.beacons.insert($0) } },
            obstacleSink: { [weak self] chunk, nodes in self?.registerObstacles(for: chunk, from: nodes) },
            onChunkRemoved: { [weak self] chunk in self?.obstaclesByChunk.removeValue(forKey: chunk) }
        )

        chunker.warmupInitial(at: yawNode.simdPosition, radius: 1)

        score = 0
        DispatchQueue.main.async { [score, onScore] in onScore(score) }
    }

    @MainActor
    private func buildLighting() {
        scene.rootNode.childNodes
            .filter { $0.light != nil }
            .forEach { $0.removeFromParentNode() }

        let amb = SCNLight()
        amb.type = .ambient
        amb.intensity = 400
        amb.color = UIColor(white: 1.0, alpha: 1.0)
        amb.categoryBitMask = 0x00000401
        let ambNode = SCNNode()
        ambNode.light = amb
        scene.rootNode.addChildNode(ambNode)

        // Main sun for terrain + default nodes (not vegetation).
        let sun = SCNLight()
        sun.type = .directional
        sun.intensity = 1100
        sun.color = UIColor.white
        sun.castsShadow = true
        sun.shadowMapSize = CGSize(width: 512, height: 512)
        sun.shadowSampleCount = 4
        sun.shadowRadius = 2.0
        sun.shadowColor = UIColor(white: 0.0, alpha: 0.55)
        sun.automaticallyAdjustsShadowProjection = true
        sun.categoryBitMask = 0x00000401
        let sunNode = SCNNode()
        sunNode.light = sun
        scene.rootNode.addChildNode(sunNode)
        self.sunLightNode = sunNode

        // Softer directional just for vegetation (category 0x2).
        let vegSun = SCNLight()
        vegSun.type = .directional
        vegSun.intensity = 650
        vegSun.color = UIColor.white
        vegSun.castsShadow = false
        vegSun.categoryBitMask = 0x00000002
        let vegNode = SCNNode()
        vegNode.light = vegSun
        scene.rootNode.addChildNode(vegNode)
        self.vegSunLightNode = vegNode

        applySunDirection(azimuthDeg: 40, elevationDeg: 65)
    }

    // MARK: - Sky

    @MainActor
    private func buildSky() {
        // Clean slate
        skyAnchor.removeFromParentNode()
        skyAnchor.childNodes.forEach { $0.removeFromParentNode() }
        scene.rootNode.childNode(withName: "VolumetricCloudLayer", recursively: true)?.removeFromParentNode()
        scene.rootNode.childNodes.filter { $0.name == "SunDiscHDR" }.forEach { $0.removeFromParentNode() }
        scene.rootNode.addChildNode(skyAnchor)

        // Gradient only (no clouds yet)
        scene.background.contents = SceneKitHelpers.skyEquirectGradient(width: 2048, height: 1024)
        scene.lightingEnvironment.contents = nil
        scene.lightingEnvironment.intensity = 0

        // EDR sun disc (additive), drawn after everything else
        let sun = makeHDRSunDiscNode(angularSizeDeg: 1.05)
        sun.renderingOrder = 9_999
        skyAnchor.addChildNode(sun)
        sunDiscNode = sun

        // Point the sun where we want it and push uniforms
        applySunDirection(azimuthDeg: 40, elevationDeg: 65)
        applyCloudSunUniforms() // safe even without clouds; keeps billboards in sync later
    }

    private func addSafetyGround(at worldPos: simd_float3) {
        let size: Float = cfg.tileSize * Float(cfg.tilesX * 10)
        let plane = SCNPlane(width: CGFloat(size), height: CGFloat(size))

        let mat = SCNMaterial()
        mat.lightingModel = .constant
        let green = UIColor(red: 0.32, green: 0.62, blue: 0.34, alpha: 1.0)
        mat.emission.contents = green
        mat.diffuse.contents = green
        mat.isDoubleSided = true
        plane.firstMaterial = mat

        let node = SCNNode(geometry: plane)
        node.eulerAngles = SCNVector3(-Float.pi/2, 0, 0)

        let y = TerrainMath.heightWorld(x: worldPos.x, z: worldPos.z, cfg: cfg, noise: noise) - 0.02
        node.simdPosition = simd_float3(worldPos.x, y, worldPos.z)
        node.renderingOrder = -500
        node.name = "SafetyGround"
        node.categoryBitMask = 0

        scene.rootNode.childNodes.filter { $0.name == "SafetyGround" }.forEach { $0.removeFromParentNode() }
        scene.rootNode.addChildNode(node)
    }

    private func updateRig() {
        yawNode.eulerAngles = SCNVector3(0, yaw, 0)
        pitchNode.eulerAngles = SCNVector3(pitch, 0, 0)
        camNode.position = SCNVector3(0, 0, 0)
    }

    private func clampAngles() {
        let halfPi = Float.pi / 2
        pitch = max(-halfPi + 0.01, min(halfPi - 0.01, pitch))
        if yaw > Float.pi { yaw -= 2 * Float.pi }
        else if yaw < -Float.pi { yaw += 2 * Float.pi }
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

        return SCNVector3(
            0,
            TerrainMath.heightWorld(x: 0, z: 0, cfg: cfg, noise: noise) + cfg.eyeHeight,
            0
        )
    }

    private func groundHeightFootprint(worldX x: Float, z: Float) -> Float {
        if let y = groundHeightRaycast(worldX: x, z: z) { return y }

        let r: Float = 0.35
        let h0 = TerrainMath.heightWorld(x: x, z: z, cfg: cfg, noise: noise)
        let h1 = TerrainMath.heightWorld(x: x - r, z: z - r, cfg: cfg, noise: noise)
        let h2 = TerrainMath.heightWorld(x: x + r, z: z - r, cfg: cfg, noise: noise)
        let h3 = TerrainMath.heightWorld(x: x - r, z: z + r, cfg: cfg, noise: noise)
        let h4 = TerrainMath.heightWorld(x: x + r, z: z + r, cfg: cfg, noise: noise)
        return max(h0, h1, h2, h3, h4)
    }

    private func groundHeightRaycast(worldX x: Float, z: Float) -> Float? {
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
            picked.forEach {
                $0.removeAllActions()
                $0.removeFromParentNode()
                beacons.remove($0)
            }
            score += picked.count
            DispatchQueue.main.async { [score, onScore] in onScore(score) }
        }
    }

    private enum SunSprite {
        static let image: UIImage = {
            let N = 256
            let size = CGSize(width: N, height: N)
            UIGraphicsBeginImageContextWithOptions(size, false, 0)
            guard let ctx = UIGraphicsGetCurrentContext() else { return UIImage() }
            let colors = [
                UIColor(white: 1.0, alpha: 1.0).cgColor,
                UIColor(red: 1.0, green: 0.98, blue: 0.90, alpha: 0.75).cgColor,
                UIColor(red: 1.0, green: 0.96, blue: 0.80, alpha: 0.0).cgColor
            ] as CFArray
            let locs: [CGFloat] = [0.0, 0.55, 1.0]
            let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: locs)!
            let c = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
            ctx.drawRadialGradient(grad, startCenter: c, startRadius: 0, endCenter: c, endRadius: size.width * 0.5, options: .drawsAfterEndLocation)
            let img = UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
            UIGraphicsEndImageContext()
            return img
        }()
    }
    
    // Called by RendererProxy each frame
    @MainActor
    func tickVolumetricClouds(atRenderTime t: TimeInterval) {
        guard
            let sphere =
                skyAnchor.childNode(withName: "VolumetricCloudLayer", recursively: false)
                ?? scene.rootNode.childNode(withName: "VolumetricCloudLayer", recursively: false),
            let m = sphere.geometry?.firstMaterial
        else { return }

        // Update time + view-space sun each frame
        m.setValue(CGFloat(t), forKey: "time")

        let pov = (scnView?.pointOfView ?? camNode).presentation
        let invView = simd_inverse(pov.simdWorldTransform)
        let sunView4 = invView * simd_float4(sunDirWorld, 0)
        let sunView  = simd_normalize(simd_float3(sunView4.x, sunView4.y, sunView4.z))
        let sunViewV = SCNVector3(sunView.x, sunView.y, sunView.z)
        m.setValue(sunViewV, forKey: "sunDirView")

        // Keep billboards in sync too
        if let layer = skyAnchor.childNode(withName: "CumulusBillboardLayer", recursively: true) {
            layer.enumerateChildNodes { node, _ in
                guard let g = node.geometry else { return }
                for m in g.materials {
                    m.setValue(sunViewV, forKey: "sunDirView")
                }
            }
        }
    }
    
    // MARK: - Sun sprite (HDR)

    @MainActor
    private func makeHDRSunDiscNode(angularSizeDeg: CGFloat) -> SCNNode {
        // Place the quad on the sun direction at sky distance so its apparent size is right.
        let dist = CGFloat(cfg.skyDistance)
        let radians = angularSizeDeg * .pi / 180.0
        let worldDiameter = 2.0 * dist * tan(0.5 * radians)

        let plane = SCNPlane(width: worldDiameter, height: worldDiameter)

        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = UIColor.clear
        // Emissive sprite with EDR headroom (the image already carries >1.0 values)
        m.emission.contents = SceneKitHelpers.sunSpriteImage(diameter: 512)
        m.emission.intensity = 1.0
        m.isDoubleSided = false
        m.readsFromDepthBuffer = false
        m.writesToDepthBuffer = false
        m.transparencyMode = .aOne
        m.blendMode = .add
        plane.firstMaterial = m

        let node = SCNNode(geometry: plane)
        node.name = "SunDiscHDR"
        node.castsShadow = false

        // Face the camera at all times
        let bb = SCNBillboardConstraint()
        bb.freeAxes = .all
        node.constraints = [bb]

        // Position gets set by applySunDirection(...)
        return node
    } 
}
