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
    #if DEBUG
    @MainActor
    private func logLightingState(_ tag: String) {
        let lights = scene.rootNode.childNodes.filter { $0.light != nil }
        let dirLights = lights.filter { $0.light?.type == .directional }
        let sun = scene.rootNode.childNode(withName: "GL_SunLight", recursively: true)?.light
        let sky = scene.rootNode.childNode(withName: "SkyAtmosphere", recursively: true)
        let cloud = scene.rootNode.childNode(withName: "CumulusBillboardLayer", recursively: true)
        let bgDesc = scene.background.contents.map { String(describing: type(of: $0)) } ?? "nil"
        let envDesc = scene.lightingEnvironment.contents.map { String(describing: type(of: $0)) } ?? "nil"
        let cam = camNode.camera ?? scnView?.pointOfView?.camera
        print(String(
            format: "[LIGHT] %@ bg=%@ env=%@ envI=%.2f lights=%d dir=%d sunI=%.1f sky=%@ cloud=%@ hdr=%@ exp=%.2f",
            tag,
            bgDesc,
            envDesc,
            scene.lightingEnvironment.intensity,
            lights.count,
            dirLights.count,
            sun?.intensity ?? -1,
            (sky != nil) ? "yes" : "no",
            (cloud != nil) ? "yes" : "no",
            (cam?.wantsHDR == true) ? "on" : "off",
            cam?.exposureOffset ?? 0
        ))
    }
    #endif

    // MARK: - Lifecycle / rebuild

    @MainActor
    func resetWorld() {
        resolveCloudFixedProfileOnce()
        #if DEBUG
        logLightingState("pre-reset")
        #endif
        let rng = GKRandomSource.sharedRandom()
        cloudSeed = UInt32(bitPattern: Int32(rng.nextInt()))
        cloudInitialYaw = (rng.nextUniform() * 2.0 - 1.0) * Float.pi
        cloudSpinAccum = 0

        // 5° per minute (radians/second)
        cloudSpinRate = 0.0014544410
        cloudWind = simd_float2(0.60, 0.20)

        let ang = rng.nextUniform() * 6.2831853
        let rad: Float = 87.0
        cloudDomainOffset = simd_float2(cosf(ang), sinf(ang)) * rad

        scene.rootNode.childNodes.forEach { $0.removeFromParentNode() }
        beaconsByChunk.removeAll()
        obstaclesByChunk.removeAll()
        waystoneNode = nil

        // Ensure no stale sky references keep doing work after a reset (they may no longer be in the scene graph).
        cloudLayerNode = nil
        cloudBillboardNodes.removeAll()
        cloudClusterGroups.removeAll()
        cloudClusterCentroidLocal.removeAll()
        cloudRMin = 1
        cloudRMax = 1
        cloudUpdateAccumulator = 0
        cloudAdaptiveTier = fixedCloudTierForCurrentProfile()
        cloudAppliedVisualTier = -1
        cloudVisiblePuffsPerCluster = 10
        cloudCheapShaderEnabled = false

        buildLighting()
        buildSky()

        yaw = 0
        pitch = -0.08
        let playerSpawn = spawn()
        yawNode.position = playerSpawn
        updateRig()
        pickupCheckAccumulator = 0
        carriedBeacons = 0
        bankedBeacons = 0
        banksCompleted = 0
        score = 0
        runEnded = false
        runStartTime = CACurrentMediaTime()
        lastTime = 0

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
            beaconSink: { [weak self] chunk, nodes in
                guard let self else { return }
                self.beaconsByChunk[chunk] = nodes
            },
            obstacleSink: { [weak self] chunk, nodes in
                self?.registerObstacles(for: chunk, from: nodes)
            },
            onChunkRemoved: { [weak self] chunk in
                self?.obstaclesByChunk.removeValue(forKey: chunk)
                self?.beaconsByChunk.removeValue(forKey: chunk)
            }
        )

        chunker.warmupInitial(at: yawNode.simdPosition, radius: 0)   // was 1
        spawnWaystoneNearSpawn(near: yawNode.simdWorldPosition)
        DispatchQueue.main.async { [score, onScore] in onScore(score) }
        #if DEBUG
        logLightingState("post-reset")
        #endif
    }

    // MARK: - Lighting
    @MainActor
    func buildLighting() {
        scene.rootNode.childNodes
            .filter { $0.light != nil }
            .forEach { $0.removeFromParentNode() }

        #if DEBUG
        if debugDisableDynamicLights {
            let amb = SCNLight()
            amb.type = .ambient
            amb.intensity = 900
            amb.color = UIColor(white: 1.0, alpha: 1.0)
            let ambNode = SCNNode()
            ambNode.name = "GL_AmbientOnly"
            ambNode.light = amb
            scene.rootNode.addChildNode(ambNode)
            self.sunLightNode = nil
            self.vegSunLightNode = nil
            return
        }
        #endif

        // iOS 26: get the actual screen from this view’s window
        let screenBounds = scnView?.window?.windowScene?.screen.bounds ?? (scnView?.bounds ?? .zero)
        let isLandscape = screenBounds.width > screenBounds.height

        let sun = SCNLight()
        sun.type = .directional
        sun.intensity = 1500
        sun.color = UIColor.white

        // Shadows tuned for mobile; lighter in landscape.
        sun.castsShadow = true
        sun.shadowMode = .deferred
        sun.shadowMapSize = CGSize(
            width:  isLandscape ? 1280 : 2048,
            height: isLandscape ? 1280 : 2048
        )
        sun.shadowSampleCount       = isLandscape ? 1 : 3   // ← place it here
        sun.shadowRadius            = 1.2
        sun.shadowColor             = UIColor(white: 0.0, alpha: 0.70)
        sun.shadowBias              = 0.004
        sun.automaticallyAdjustsShadowProjection = false
        sun.orthographicScale       = isLandscape ? 360 : 440
        sun.maximumShadowDistance   = isLandscape ? 420 : 720
        sun.shadowCascadeCount      = isLandscape ? 2 : 3
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

        #if DEBUG
        if debugDisableSky {
            scene.background.contents = UIColor(red: 0.60, green: 0.78, blue: 0.95, alpha: 1.0)
            scene.background.wrapS = .clamp
            scene.background.wrapT = .clamp
            scene.lightingEnvironment.contents = nil
            scene.lightingEnvironment.intensity = 0.0
            return
        }
        #endif

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
        skyNode.categoryBitMask = 1
        skyAnchor.addChildNode(skyNode)
        skyAnchor.simdPosition = yawNode.presentation.simdWorldPosition

        // Background gradient, no IBL (sun is sole illuminant)
        let bg = SkyGradientImage.make()
        scene.background.contents = bg
        scene.background.wrapS = .clamp
        scene.background.wrapT = .clamp
        scene.lightingEnvironment.contents = nil
        scene.lightingEnvironment.intensity = 0.0

        // Clouds are provided by the billboard cumulus layer (raymarched impostor puffs).
        // Make sure no volumetric dome is lingering, as it can cover the entire sky.
        removeVolumetricDomeIfPresent()

        // Ensure any leftover billboard layer is gone/disabled before the async rebuild.
        scene.rootNode.childNodes
            .filter { $0.name == "CumulusBillboardLayer" }
            .forEach { $0.removeFromParentNode() }
        enableVolumetricCloudImpostors(false)
        #if DEBUG
        if debugDisableCloudRender {
            return
        }
        #endif

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
        prewarmSunDiffusion()
        prewarmSkyAndSun()
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
