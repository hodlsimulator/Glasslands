//
//  FirstPersonEngine+Lifecycle.swift
//  Glasslands
//
//  Created by . . on 10/5/25.
//

import SceneKit
import simd
import UIKit
import QuartzCore
import CoreGraphics
import GameplayKit

extension FirstPersonEngine {

    // MARK: - Lifecycle / rebuild

    @MainActor
    func resetWorld() {
        let rng = GKRandomSource.sharedRandom()
        cloudSeed = UInt32(bitPattern: Int32(rng.nextInt()))
        cloudInitialYaw = (rng.nextUniform() * 2.0 - 1.0) * Float.pi
        cloudSpinAccum = 0

        // 12° per minute (radians/second)
        cloudSpinRate = 0.0034906586
        cloudWind = simd_float2(0.60, 0.20)

        let ang = rng.nextUniform() * 6.2831853
        let rad: Float = 87.0
        cloudDomainOffset = simd_float2(cosf(ang), sinf(ang)) * rad

        scene.rootNode.childNodes.forEach { $0.removeFromParentNode() }
        beacons.removeAll()
        obstaclesByChunk.removeAll()
        cloudBillboardNodes.removeAll()
        cloudRMin = 1
        cloudRMax = 1

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
        camera.wantsHDR = true
        camera.wantsExposureAdaptation = false
        camera.exposureOffset = -0.25
        camera.averageGray = 0.18
        camera.whitePoint = 1.0

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
            beaconSink: { [weak self] nodes in
                guard let self else { return }
                nodes.forEach { self.beacons.insert($0) }
            },
            obstacleSink: { [weak self] chunk, nodes in
                self?.registerObstacles(for: chunk, from: nodes)
            },
            onChunkRemoved: { [weak self] chunk in
                self?.obstaclesByChunk.removeValue(forKey: chunk)
            }
        )

        chunker.warmupInitial(at: yawNode.simdPosition, radius: 1)
        score = 0
        DispatchQueue.main.async { [score, onScore] in onScore(score) }
    }

    // MARK: - Lighting
    @MainActor
    func buildLighting() {
        scene.rootNode.childNodes
            .filter { $0.light != nil }
            .forEach { $0.removeFromParentNode() }

        // Sun (only illuminant)
        let sun = SCNLight()
        sun.type = .directional
        sun.intensity = 1500
        sun.color = UIColor.white
        sun.castsShadow = true
        sun.shadowMapSize = CGSize(width: 1024, height: 1024)
        sun.shadowSampleCount = 4
        sun.shadowRadius = 1.2
        sun.shadowColor = UIColor(white: 0.0, alpha: 0.65)
        sun.automaticallyAdjustsShadowProjection = true
        sun.categoryBitMask = 0x0000_0403

        let sunNode = SCNNode()
        sunNode.name = "GL_SunLight"
        sunNode.light = sun
        scene.rootNode.addChildNode(sunNode)

        // Keep sky fill present but OFF (we may animate later)
        let skyFill = SCNLight()
        skyFill.type = .directional
        skyFill.color = UIColor.white
        skyFill.intensity = 0     // ← off
        skyFill.castsShadow = false
        skyFill.categoryBitMask = 0x0000_0403
        let skyFillNode = SCNNode()
        skyFillNode.name = "GL_SkyFill"
        skyFillNode.light = skyFill
        scene.rootNode.addChildNode(skyFillNode)

        // Aim sky fill straight down for completeness
        let origin = yawNode.presentation.position
        skyFillNode.position = origin
        skyFillNode.look(at: SCNVector3(origin.x, origin.y - 1.0, origin.z),
                         up: scene.rootNode.worldUp, localFront: SCNVector3(0, 0, -1))

        self.sunLightNode = sunNode
        self.vegSunLightNode = nil
        applySunDirection(azimuthDeg: 40, elevationDeg: 65)
    }

    // MARK: - Sky
    @MainActor
    func buildSky() {
        // Clear old sky nodes/materials that might compile shaders
        skyAnchor.removeFromParentNode()
        skyAnchor.childNodes.forEach { $0.removeFromParentNode() }
        scene.rootNode.childNodes
            .filter { ["SunDiscHDR", "SunHaloHDR", "VolumetricCloudLayer", "CumulusBillboardLayer", "SkyAtmosphere"].contains($0.name ?? "") }
            .forEach { $0.removeFromParentNode() }
        scene.rootNode.addChildNode(skyAnchor)

        skyAnchor.simdPosition = yawNode.presentation.simdWorldPosition

        // Precompute the same band radii as the builder and seed the advection bounds
        do {
            let R = Float(cfg.skyDistance)
            let rNearMax : Float = max(560, R * 0.22)
            let rNearHole: Float = rNearMax * 0.34
            let rBridge0 : Float = rNearMax * 1.06
            let rBridge1 : Float = rBridge0 + max(900,  R * 0.42)
            let rMid0    : Float = rBridge1 - 100
            let rMid1    : Float = rMid0    + max(2100, R * 1.05)
            let rFar0    : Float = rMid1    + max(650,  R * 0.34)
            let rFar1    : Float = rFar0    + max(3000, R * 1.40)
            let rUltra0  : Float = rFar1    + max(700,  R * 0.40)
            let rUltra1  : Float = rUltra0  + max(1600, R * 0.60)
            cloudRMin = rNearHole
            cloudRMax = rUltra1
        }

        // Background = static blue gradient image (no SCNProgram / shader)
        let bg = SkyGradientImage.make()
        scene.background.contents = bg
        scene.background.wrapS = .clamp
        scene.background.wrapT = .clamp

        // Kill IBL so sun is the only light, but keep things visible
        scene.lightingEnvironment.contents = nil
        scene.lightingEnvironment.intensity = 0.0

        // DO NOT add the volumetric cloud sphere (it’s the lag). Keep billboards.
        CloudBillboardLayer.makeAsync(radius: CGFloat(cfg.skyDistance), seed: cloudSeed) { [weak self] node in
            guard let self else { return }
            node.name = "CumulusBillboardLayer"
            node.eulerAngles.y = self.cloudInitialYaw
            self.skyAnchor.addChildNode(node)
            self.cloudLayerNode = node
            self.applyCloudSunUniforms()
            self.enableVolumetricCloudImpostors(true)
        }

        // HDR sun sprites (unchanged)
        let coreDeg: CGFloat = 6.0, haloScale: CGFloat = 2.6
        let evBoost: CGFloat = pow(2.0, 1.5)
        let sun = makeHDRSunNode(coreAngularSizeDeg: coreDeg,
                                 haloScale: haloScale,
                                 coreIntensity: 8.0 * evBoost,
                                 haloIntensity: 2.0 * evBoost,
                                 haloExponent: 2.2,
                                 haloPixels: 2048)
        sun.renderingOrder = 100_000
        skyAnchor.addChildNode(sun)
        sunDiscNode = sun

        applySunDirection(azimuthDeg: 40, elevationDeg: 65)
        applyCloudSunUniforms()
    } 

    // MARK: - Safety ground

    func addSafetyGround(at worldPos: simd_float3) {
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
}
