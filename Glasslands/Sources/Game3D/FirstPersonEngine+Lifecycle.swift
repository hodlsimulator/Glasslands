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
        // Fresh per-session cloud parameters (formation + motion).
        let rng = GKRandomSource.sharedRandom()
        cloudSeed = UInt32(bitPattern: Int32(rng.nextInt()))
        cloudInitialYaw = (rng.nextUniform() * 2.0 - 1.0) * Float.pi
        cloudSpinAccum = 0
        cloudSpinRate = 0.000145 // very slow, consistent drift
        cloudWind = simd_float2(0.60, 0.20) // gentle push for volumetrics

        // Domain offset gives the volumetric field a different “formation” each launch
        // without changing structural rules.
        let ang = rng.nextUniform() * 6.2831853
        let rad: Float = 87.0
        cloudDomainOffset = simd_float2(cosf(ang), sinf(ang)) * rad

        // Clear scene
        scene.rootNode.childNodes.forEach { $0.removeFromParentNode() }
        beacons.removeAll()
        obstaclesByChunk.removeAll()

        buildLighting()
        buildSky()

        yaw = 0
        pitch = -0.08
        yawNode.position = spawn()
        updateRig()

        // Camera
        let camera = SCNCamera()
        camera.zNear = 0.02
        camera.zFar = 20_000
        camera.fieldOfView = 70
        camera.wantsHDR = true
        camera.wantsExposureAdaptation = false
        camera.exposureOffset = -0.25 // 1.25 − 1.5 stops = −0.25
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

        let sun = SCNLight()
        sun.type = .directional
        sun.intensity = 1500
        sun.color = UIColor.white
        sun.castsShadow = true
        sun.shadowMapSize = CGSize(width: 512, height: 512)
        sun.shadowSampleCount = 4
        sun.shadowRadius = 2.0
        sun.shadowColor = UIColor(white: 0.0, alpha: 0.55)
        sun.automaticallyAdjustsShadowProjection = true
        // Terrain (0x400) + props (0x001) + vegetation (0x002) = 0x403
        sun.categoryBitMask = 0x00000403

        let sunNode = SCNNode()
        sunNode.light = sun
        scene.rootNode.addChildNode(sunNode)
        self.sunLightNode = sunNode
        self.vegSunLightNode = nil

        applySunDirection(azimuthDeg: 40, elevationDeg: 65)
    }

    // MARK: - Sky

    @MainActor
    func buildSky() {
        skyAnchor.removeFromParentNode()
        skyAnchor.childNodes.forEach { $0.removeFromParentNode() }
        scene.rootNode.childNodes
            .filter { ["SunDiscHDR", "SunHaloHDR", "VolumetricCloudLayer", "CumulusBillboardLayer"].contains($0.name ?? "") }
            .forEach { $0.removeFromParentNode() }

        scene.rootNode.addChildNode(skyAnchor)

        // Background sky (LDR image for the clear gradient).
        scene.background.contents = SceneKitHelpers.skyEquirectGradient(width: 2048, height: 1024)

        // Subtle SKY BOUNCE for PBR materials only (trees/rocks).
        // Lambert terrain is unaffected by lightingEnvironment, so the ground stays as-is.
        scene.lightingEnvironment.contents = SceneKitHelpers.skyEquirectGradient(width: 1024, height: 512)
        scene.lightingEnvironment.intensity = 0.18 // tweak 0.12–0.25 to taste

        // Clouds (billboards → impostors). Seeded per-session and pre-rotated.
        CloudBillboardLayer.makeAsync(radius: CGFloat(cfg.skyDistance), seed: cloudSeed) { [weak self] node in
            guard let self else { return }
            node.name = "CumulusBillboardLayer"
            node.eulerAngles.y = self.cloudInitialYaw
            self.skyAnchor.addChildNode(node)
            self.applyCloudSunUniforms()
            self.enableVolumetricCloudImpostors(true)
            self.debugCloudShaderOnce(tag: "after-attach")
            DispatchQueue.main.async { self.debugCloudShaderOnce(tag: "after-runloop") }
        }

        // HDR sun disc + halo — keep max brightness/boost.
        let coreDeg: CGFloat = 6.0
        let haloScale: CGFloat = 2.6
        let evBoost: CGFloat = pow(2.0, 1.5) // keep the strong, white-hot look
        let coreEDR: CGFloat = 8.0 * evBoost
        let haloEDR: CGFloat = 2.0 * evBoost
        let haloExponent: CGFloat = 2.2
        let haloPixels: Int = 2048

        let sun = makeHDRSunNode(
            coreAngularSizeDeg: coreDeg,
            haloScale: haloScale,
            coreIntensity: coreEDR,
            haloIntensity: haloEDR,
            haloExponent: haloExponent,
            haloPixels: haloPixels
        )
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
