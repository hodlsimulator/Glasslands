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
        
        // Keep the camera rig out of all light/shadow interaction.
        let playerCategory = 0x0000_0800
        [yawNode, pitchNode, camNode].forEach { n in
            n.castsShadow = false
            n.categoryBitMask = playerCategory
        }

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

        chunker.warmupInitial(at: yawNode.simdPosition, radius: 1)   // was 0
        score = 0
        DispatchQueue.main.async { [score, onScore] in onScore(score) }
    }

    // MARK: - Lighting
    @MainActor
    func buildLighting() {
        scene.rootNode.childNodes
            .filter { $0.light != nil }
            .forEach { $0.removeFromParentNode() }

        let sun = SCNLight()
        sun.type = .directional
        sun.intensity = 1500
        sun.color = UIColor.white

        // Shadows tuned for crisp outline + firm ground contact
        sun.castsShadow = true
        sun.shadowMode = .deferred
        sun.shadowMapSize = CGSize(width: 3072, height: 3072)
        sun.shadowSampleCount = 8
        sun.shadowRadius = 1.4
        sun.shadowColor = UIColor(white: 0.0, alpha: 0.70)

        // Key: very low bias to eliminate the "halo" around the trunk base
        sun.shadowBias = 0.004

        sun.automaticallyAdjustsShadowProjection = false
        sun.orthographicScale = 440
        sun.maximumShadowDistance = 720
        sun.shadowCascadeCount = 4
        sun.shadowCascadeSplittingFactor = 0.72

        // Terrain (0x400) + vegetation (0x2) + default (0x1)
        sun.categoryBitMask = 0x0000_0403

        let sunNode = SCNNode()
        sunNode.name = "GL_SunLight"
        sunNode.light = sun
        scene.rootNode.addChildNode(sunNode)

        let skyFill = SCNLight()
        skyFill.type = .directional
        skyFill.color = UIColor.white
        skyFill.intensity = 0
        skyFill.castsShadow = false
        skyFill.categoryBitMask = 0x0000_0403

        let skyFillNode = SCNNode()
        skyFillNode.name = "GL_SkyFill"
        skyFillNode.light = skyFill
        scene.rootNode.addChildNode(skyFillNode)

        let origin = yawNode.presentation.position
        skyFillNode.position = origin
        skyFillNode.look(
            at: SCNVector3(origin.x, origin.y - 1.0, origin.z),
            up: scene.rootNode.worldUp,
            localFront: SCNVector3(0, 0, -1)
        )

        self.sunLightNode = sunNode
        self.vegSunLightNode = nil

        // Same sun direction as before
        applySunDirection(azimuthDeg: 40, elevationDeg: 65)
    }

    // MARK: - Sky
    @MainActor
    func buildSky() {
        // Clear old sky bits
        skyAnchor.removeFromParentNode()
        skyAnchor.childNodes.forEach { $0.removeFromParentNode() }
        scene.rootNode.childNodes
            .filter { ["SunDiscHDR", "SunHaloHDR", "VolumetricCloudLayer", "CumulusBillboardLayer", "SkyAtmosphere"].contains($0.name ?? "") }
            .forEach { $0.removeFromParentNode() }
        scene.rootNode.addChildNode(skyAnchor)

        // Atmosphere dome
        let skyR = CGFloat(cfg.skyDistance) * 0.995
        let skySphere = SCNSphere(radius: max(10, skyR))
        skySphere.segmentCount = 96
        let skyMat = SkyAtmosphereMaterial.make()
        skySphere.firstMaterial = skyMat
        let skyNode = SCNNode(geometry: skySphere)
        skyNode.name = "SkyAtmosphere"
        skyNode.castsShadow = false
        skyNode.renderingOrder = -200_000
        skyNode.categoryBitMask = 0
        skyAnchor.addChildNode(skyNode)
        skyAnchor.simdPosition = yawNode.presentation.simdWorldPosition

        // Background gradient, no IBL (sun is sole illuminant)
        let bg = SkyGradientImage.make()
        scene.background.contents = bg
        scene.background.wrapS = .clamp
        scene.background.wrapT = .clamp
        scene.lightingEnvironment.contents = nil
        scene.lightingEnvironment.intensity = 0.0

        // True volumetric vapour (no billboard sprites = no circles)
        let vol = VolumetricCloudLayer.make(
            radius: CGFloat(cfg.skyDistance),
            baseY: 400, topY: 1400, coverage: 0.50
        )
        skyAnchor.addChildNode(vol)

        // Ensure any leftover billboard layer is gone/disabled
        scene.rootNode.childNodes
            .filter { $0.name == "CumulusBillboardLayer" }
            .forEach { $0.removeFromParentNode() }
        enableVolumetricCloudImpostors(false)

        // HDR sun sprites
        let coreDeg: CGFloat = 6.0, haloScale: CGFloat = 2.6
        let evBoost: CGFloat = pow(2.0, 1.5)
        let sun = makeHDRSunNode(coreAngularSizeDeg: coreDeg,
                                 haloScale: haloScale,
                                 coreIntensity: 8.0 * evBoost,
                                 haloIntensity: 2.0 * evBoost,
                                 haloExponent: 2.2,
                                 haloPixels: 2048)
        sun.renderingOrder = 200_000
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
