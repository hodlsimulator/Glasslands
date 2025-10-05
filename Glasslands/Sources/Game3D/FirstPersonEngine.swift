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

        // Update volumetric clouds (shader-modifier path): time + sun in VIEW space.
        if let sphere = skyAnchor.childNode(withName: "VolumetricCloudLayer", recursively: false),
           let m = sphere.geometry?.firstMaterial {
            m.setValue(CGFloat(t), forKey: "time")

            let pov = (scnView?.pointOfView ?? camNode).presentation
            let invView = simd_inverse(pov.simdWorldTransform)
            let sunView4 = invView * simd_float4(sunDirWorld, 0)
            let s = simd_normalize(simd_float3(sunView4.x, sunView4.y, sunView4.z))
            m.setValue(SCNVector3(s.x, s.y, s.z), forKey: "sunDirView")
        }

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

        // Bloom tuned for a hot sun core + gentle halo
        camera.bloomThreshold = 1.0
        camera.bloomIntensity = 1.6
        camera.bloomBlurRadius = 14.0

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
        skyAnchor.removeFromParentNode()
        skyAnchor.childNodes.forEach { $0.removeFromParentNode() }
        scene.rootNode.childNodes
            .filter { ["SunDiscHDR", "SunHaloHDR", "VolumetricCloudLayer", "CumulusBillboardLayer"].contains($0.name ?? "") }
            .forEach { $0.removeFromParentNode() }

        scene.rootNode.addChildNode(skyAnchor)

        // Background gradient; no skydome mesh so there are no seam lines.
        scene.background.contents = SceneKitHelpers.skyEquirectGradient(width: 2048, height: 1024)
        scene.lightingEnvironment.contents = nil
        scene.lightingEnvironment.intensity = 0

        // Build volumetric impostor clouds (billboard clusters).
        CloudBillboardLayer.makeAsync(radius: CGFloat(cfg.skyDistance)) { [weak self] node in
            guard let self else { return }
            node.name = "CumulusBillboardLayer"
            self.skyAnchor.addChildNode(node)
            self.applyCloudSunUniforms()
            self.forceReplaceAndVerifyClouds()
            
            self.debugCloudShaderOnce(tag: "after-attach")
            DispatchQueue.main.async { self.debugCloudShaderOnce(tag: "after-runloop") }
        
            // self.forceAllCloudsToPlainWhite()
            // self.sanitizeCloudBillboards()
            // self.rebindMissingCloudTextures()
            // self.forceReplaceAllCloudBillboards()
        }

        // HDR sun (disc + halo).
        let coreDeg: CGFloat = 6.0
        let haloScale: CGFloat = 2.6
        let coreEDR: CGFloat = 8.0
        let haloEDR: CGFloat = 2.0
        let haloExponent: CGFloat = 2.2
        let haloPixels: Int = 2048
        let sun = makeHDRSunNode(coreAngularSizeDeg: coreDeg,
                                 haloScale: haloScale,
                                 coreIntensity: coreEDR,
                                 haloIntensity: haloEDR,
                                 haloExponent: haloExponent,
                                 haloPixels: haloPixels)
        sun.renderingOrder = 100_000
        skyAnchor.addChildNode(sun)
        sunDiscNode = sun

        applySunDirection(azimuthDeg: 40, elevationDeg: 65)
        applyCloudSunUniforms()
    }
    
    @MainActor
    private func makeHDRSunNode(coreAngularSizeDeg: CGFloat,
                                haloScale: CGFloat,
                                coreIntensity: CGFloat,
                                haloIntensity: CGFloat,
                                haloExponent: CGFloat,
                                haloPixels: Int) -> SCNNode
    {
        let dist = CGFloat(cfg.skyDistance)
        let radians = coreAngularSizeDeg * .pi / 180.0
        let coreDiameter = max(1.0, 2.0 * dist * tan(0.5 * radians))
        let haloDiameter = max(coreDiameter * haloScale, coreDiameter + 1.0)

        // Core: crisp circle via geometry (no texture), additive emission, very hot EDR
        let corePlane = SCNPlane(width: coreDiameter, height: coreDiameter)
        corePlane.cornerRadius = coreDiameter * 0.5

        let coreMat = SCNMaterial()
        coreMat.lightingModel = .constant
        coreMat.diffuse.contents = UIColor.black
        coreMat.blendMode = .add
        coreMat.readsFromDepthBuffer = false
        coreMat.writesToDepthBuffer = false
        coreMat.emission.contents = UIColor.white
        coreMat.emission.intensity = coreIntensity   // HDR punch
        corePlane.firstMaterial = coreMat

        let coreNode = SCNNode(geometry: corePlane)
        coreNode.name = "SunDiscHDR"
        coreNode.castsShadow = false
        let bbCore = SCNBillboardConstraint()
        bbCore.freeAxes = .all
        coreNode.constraints = [bbCore]
        coreNode.renderingOrder = 100_001

        // Halo: radial gradient texture, additive emission, larger than core
        let haloPlane = SCNPlane(width: haloDiameter, height: haloDiameter)
        haloPlane.cornerRadius = haloDiameter * 0.5

        let haloMat = SCNMaterial()
        haloMat.lightingModel = .constant
        haloMat.diffuse.contents = UIColor.black
        haloMat.blendMode = .add
        haloMat.readsFromDepthBuffer = false
        haloMat.writesToDepthBuffer = false
        haloMat.emission.contents = sunHaloImage(diameter: max(256, haloPixels), exponent: haloExponent)
        haloMat.emission.intensity = haloIntensity
        haloMat.transparencyMode = .aOne
        haloPlane.firstMaterial = haloMat

        let haloNode = SCNNode(geometry: haloPlane)
        haloNode.name = "SunHaloHDR"
        haloNode.castsShadow = false
        let bbHalo = SCNBillboardConstraint()
        bbHalo.freeAxes = .all
        haloNode.constraints = [bbHalo]
        haloNode.renderingOrder = 100_000

        // Group so applySunDirection can move them together
        let group = SCNNode()
        group.addChildNode(haloNode)
        group.addChildNode(coreNode)
        return group
    }
    
    @MainActor
    private func sunHaloImage(diameter: Int, exponent: CGFloat) -> UIImage {
        let size = CGSize(width: diameter, height: diameter)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let cg = ctx.cgContext
            cg.setFillColor(UIColor.clear.cgColor)
            cg.fill(CGRect(origin: .zero, size: size))

            let center = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
            let steps = 8
            var colors: [CGColor] = []
            var locations: [CGFloat] = []
            for i in 0...steps {
                let p = CGFloat(i) / CGFloat(steps)
                // Falloff shaped by exponent; alpha is stronger near centre
                let a = pow(1.0 - p, max(0.1, exponent))
                colors.append(UIColor(white: 1.0, alpha: a).cgColor)
                locations.append(p)
            }
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                            colors: colors as CFArray,
                                            locations: locations) else { return }
            let radius = min(size.width, size.height) * 0.5
            cg.drawRadialGradient(gradient,
                                  startCenter: center, startRadius: 0,
                                  endCenter: center,   endRadius: radius,
                                  options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
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
        guard let sphere =
                skyAnchor.childNode(withName: "VolumetricCloudLayer", recursively: false)
                ?? scene.rootNode.childNode(withName: "VolumetricCloudLayer", recursively: false),
              let m = sphere.geometry?.firstMaterial
        else { return }

        // Time for shader-modifier or program paths.
        m.setValue(CGFloat(t), forKey: "time")

        // View-space sun for any billboard/cloud materials still using it.
        let pov = (scnView?.pointOfView ?? camNode).presentation
        let invView = simd_inverse(pov.simdWorldTransform)
        let sunView4 = invView * simd_float4(sunDirWorld, 0)
        let sunView = simd_normalize(simd_float3(sunView4.x, sunView4.y, sunView4.z))
        let sunViewV = SCNVector3(sunView.x, sunView.y, sunView.z)
        m.setValue(sunViewV, forKey: "sunDirView")

        // World-space sun for SCNProgram path.
        m.setValue(SCNVector3(sunDirWorld.x, sunDirWorld.y, sunDirWorld.z), forKey: "sunDirWorld")
        VolumetricCloudProgram.updateUniforms(from: m)
    }
    
    // MARK: - Sun sprite (HDR)

    @MainActor
    private func makeHDRSunDiscNode(angularSizeDeg: CGFloat, spritePixels: Int, edrIntensity: CGFloat) -> SCNNode {
        let dist = CGFloat(cfg.skyDistance)
        let radians = angularSizeDeg * .pi / 180.0
        let worldDiameter = max(1.0, 2.0 * dist * tan(0.5 * radians))

        let plane = SCNPlane(width: worldDiameter, height: worldDiameter)
        plane.cornerRadius = worldDiameter * 0.5

        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = UIColor.black              // not clear → ensures additive shows up
        m.blendMode = .add
        m.readsFromDepthBuffer = false
        m.writesToDepthBuffer = false

        m.emission.contents = SceneKitHelpers.sunSpriteImage(diameter: spritePixels)
        m.emission.intensity = edrIntensity             // >1.0 gives true HDR punch

        plane.firstMaterial = m

        let node = SCNNode(geometry: plane)
        node.name = "SunDiscHDR"
        node.castsShadow = false

        let bb = SCNBillboardConstraint()
        bb.freeAxes = .all
        node.constraints = [bb]

        node.renderingOrder = 100_000
        return node
    }
    
    @MainActor
    private func forceReplaceAllCloudBillboards() {
        guard let cloudLayer = skyAnchor.childNode(withName: "CumulusBillboardLayer", recursively: true) else {
            print("[Clouds] forceReplaceAllCloudBillboards: no layer"); return
        }

        var geometries = 0
        var replaced = 0
        var reboundDiffuse = 0

        cloudLayer.enumerateChildNodes { node, _ in
            guard let geo = node.geometry else { return }
            geometries += 1

            let newM = CloudBillboardMaterial.makeCurrent()

            // Carry over the image (or bind a tiny fallback if none).
            let old = geo.firstMaterial
            if let ui = old?.diffuse.contents as? UIImage, (ui.cgImage != nil || ui.ciImage != nil) {
                newM.diffuse.contents = ui
            } else if let ci = old?.diffuse.contents as? CIImage {
                newM.diffuse.contents = UIImage(ciImage: ci)
            } else if let color = old?.diffuse.contents as? UIColor {
                newM.diffuse.contents = color
            } else {
                newM.diffuse.contents = CloudSpriteTexture.fallbackWhite2x2
                reboundDiffuse += 1
            }

            // Keep opacity / tint users may have set.
            newM.transparency = old?.transparency ?? 1
            newM.multiply.contents = old?.multiply.contents

            // Paranoia: nuke any legacy program/modifiers on the outgoing mat.
            geo.firstMaterial?.program = nil
            geo.firstMaterial?.shaderModifiers = nil

            // Replace.
            geo.firstMaterial = newM
            replaced += 1
        }

        print("[Clouds] force-replaced materials on \(replaced)/\(geometries) geometry nodes (fallback bound to \(reboundDiffuse))")
    }
    
    @MainActor
    private func sanitizeCloudBillboards() {
        guard let cloudLayer = skyAnchor.childNode(withName: "CumulusBillboardLayer", recursively: true) else {
            print("[Clouds] no CumulusBillboardLayer found"); return
        }

        @inline(__always)
        func hasValidDiffuse(_ contents: Any?) -> Bool {
            guard let c = contents else { return false }
            if let ui = c as? UIImage { return ui.cgImage != nil || ui.ciImage != nil }
            if c is UIColor { return true }
            // Treat any other non-nil (CGImage/CIImage/MTLTexture/etc.) as valid without casting.
            return true
        }

        var fixedDiffuse = 0
        var nukedProgram = 0
        var nukedSamplerBased = 0

        cloudLayer.enumerateChildNodes { node, _ in
            guard let geo = node.geometry, let mat = geo.firstMaterial else { return }

            if mat.program != nil {
                mat.program = nil
                nukedProgram += 1
            }

            // If this material used any sampler-based modifier before, wipe it.
            if let frag = mat.shaderModifiers?[.fragment],
               frag.contains("texture2d<") || frag.contains("sampler") || frag.contains("u_diffuseTexture") {
                mat.shaderModifiers = nil
                nukedSamplerBased += 1
            }

            if !hasValidDiffuse(mat.diffuse.contents) {
                mat.diffuse.contents = CloudSpriteTexture.fallbackWhite2x2
                fixedDiffuse += 1
            }
        }

        print("[Clouds] sanitize: fixedDiffuse=\(fixedDiffuse) nukedProgram=\(nukedProgram) nukedSamplerBased=\(nukedSamplerBased)")
    }

    @MainActor
    private func rebindMissingCloudTextures() {
        guard let cloudLayer = skyAnchor.childNode(withName: "CumulusBillboardLayer", recursively: true) else { return }
        @inline(__always)
        func hasValidDiffuse(_ contents: Any?) -> Bool {
            guard let c = contents else { return false }
            if let ui = c as? UIImage { return ui.cgImage != nil || ui.ciImage != nil }
            if c is UIColor { return true }
            return true
        }

        var rebound = 0
        cloudLayer.enumerateChildNodes { node, _ in
            guard let geo = node.geometry, let mat = geo.firstMaterial else { return }
            if !hasValidDiffuse(mat.diffuse.contents) {
                mat.diffuse.contents = CloudSpriteTexture.fallbackWhite2x2
                rebound += 1
            }
        }
        if rebound > 0 { print("[Clouds] rebound diffuse on \(rebound) puff materials") }
    }
    
    /*
    @MainActor
    private func forceAllCloudsToPlainWhite() {
        guard let cloudLayer = skyAnchor.childNode(withName: "CumulusBillboardLayer", recursively: true) else {
            print("[Clouds] plain-white: no layer"); return
        }
        let basic = CloudBillboardMaterial.makeBasic()
        var replaced = 0
        cloudLayer.enumerateChildNodes { node, _ in
            if let g = node.geometry {
                let m = basic.copy() as! SCNMaterial
                m.diffuse.contents = UIColor.white   // unequivocal test: no textures at all
                g.firstMaterial?.program = nil
                g.firstMaterial?.shaderModifiers = nil
                g.firstMaterial = m
                replaced += 1
            }
        }
        print("[Clouds] plain-white replaced \(replaced) materials")
    }
     */
    
    @MainActor
    private func debugCloudShaderOnce(tag: String) {
        // Prevent log spam
        struct Flag { static var logged = false }
        guard !Flag.logged else { return }
        Flag.logged = true

        guard let layer = skyAnchor.childNode(withName: "CumulusBillboardLayer", recursively: true) else {
            print("[CloudFrag] \(tag): layer not found")
            return
        }

        var geoms = 0
        var withFrag = 0
        var withProg = 0
        var risky = 0

        layer.enumerateChildNodes { n, _ in
            guard let g = n.geometry, let m = g.firstMaterial else { return }
            geoms += 1

            if let frag = m.shaderModifiers?[.fragment] {
                withFrag += 1
                // Show length + quick flags so we know what’s actually bound.
                let len = frag.count
                let usesSampler = frag.contains("texture2d<") || frag.contains("sampler")
                let usesPow     = frag.contains("pow(")
                let hasBody     = frag.contains("#pragma body")
                print("[CloudFrag] len=\(len) sampler=\(usesSampler) pow=\(usesPow) body=\(hasBody)")
                if usesSampler { risky += 1 }
            }

            if m.program != nil {
                withProg += 1
                print("[CloudFrag] has SCNProgram on node: \(n.name ?? "<unnamed>")")
            }
        }

        print("[CloudFrag] \(tag): geoms=\(geoms) withFrag=\(withFrag) withProg=\(withProg) risky=\(risky)")
    }
    
    @MainActor
    private func forceReplaceAndVerifyClouds() {
        guard let layer = skyAnchor.childNode(withName: "CumulusBillboardLayer", recursively: true) else {
            print("[Clouds] verify: no layer"); return
        }
        let templ = CloudBillboardMaterial.makeCurrent()
        var geoms = 0, replaced = 0, ok = 0, bad = 0

        layer.enumerateChildNodes { n, _ in
            guard let g = n.geometry else { return }
            geoms += 1

            // Replace with fresh material
            let m = templ.copy() as! SCNMaterial
            m.diffuse.contents = g.firstMaterial?.diffuse.contents ?? CloudSpriteTexture.fallbackWhite2x2
            g.firstMaterial = m
            replaced += 1

            // Verify marker
            let frag = m.shaderModifiers?[.fragment] ?? ""
            if frag.contains(CloudBillboardMaterial.volumetricMarker) { ok += 1 } else { bad += 1 }
        }

        print("[Clouds] verify: geoms=\(geoms) replaced=\(replaced) ok=\(ok) bad=\(bad)")
    }
}
