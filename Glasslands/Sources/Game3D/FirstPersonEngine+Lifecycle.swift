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
        // Remove any existing lights.
        scene.rootNode.childNodes
            .filter { $0.light != nil }
            .forEach { $0.removeFromParentNode() }

        // Directional sun (casts shadows).
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
        sun.categoryBitMask = 0x0000_0403

        let sunNode = SCNNode()
        sunNode.name = "GL_SunLight"
        sunNode.light = sun
        scene.rootNode.addChildNode(sunNode)

        // Ambient skylight: used to lift shadows under clouds; driven in updateSunDiffusion().
        let sky = SCNLight()
        sky.type = .ambient
        sky.color = UIColor.white
        sky.intensity = 0  // clear sky → almost zero fill
        sky.categoryBitMask = 0x0000_0403

        let skyNode = SCNNode()
        skyNode.name = "GL_Skylight"
        skyNode.light = sky
        scene.rootNode.addChildNode(skyNode)

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

        scene.background.contents = SceneKitHelpers.skyEquirectGradient(width: 2048, height: 1024)
        scene.lightingEnvironment.contents = SceneKitHelpers.skyEquirectGradient(width: 1024, height: 512)
        scene.lightingEnvironment.intensity = 0.18

        CloudBillboardLayer.makeAsync(radius: CGFloat(cfg.skyDistance), seed: cloudSeed) { [weak self] node in
            guard let self else { return }

            @inline(__always) func norm2(_ v: simd_float2) -> simd_float2 {
                let L = simd_length(v); return (L < 1e-5) ? simd_float2(1, 0) : (v / L)
            }
            @inline(__always) func windLocal(_ w: simd_float2, _ yaw: Float) -> simd_float2 {
                let c = cosf(yaw), s = sinf(yaw)
                // rotate world→layer: rot(-yaw) * w
                return simd_float2(w.x * c + w.y * s, -w.x * s + w.y * c)
            }

            node.name = "CumulusBillboardLayer"
            node.eulerAngles.y = self.cloudInitialYaw
            self.skyAnchor.addChildNode(node)
            self.cloudLayerNode = node

            // Cache clusters (direct children) and puff parents.
            self.cloudBillboardNodes.removeAll()
            self.cloudClusterGroups = node.childNodes
            self.cloudClusterCentroidLocal.removeAll()

            var rMin: Float = .greatestFiniteMagnitude
            var rMax: Float = 0

            for group in self.cloudClusterGroups {
                var sum = simd_float3.zero
                var count = 0

                for bb in group.childNodes {
                    if let cs = bb.constraints, cs.contains(where: { $0 is SCNBillboardConstraint }) {
                        let p = bb.simdPosition
                        self.cloudBillboardNodes.append(bb)
                        sum += p
                        count += 1

                        let r = simd_length(SIMD2(p.x, p.z))
                        if r < rMin { rMin = r }
                        if r > rMax { rMax = r }
                    }
                }

                let c = (count > 0) ? (sum / Float(count)) : .zero
                self.cloudClusterCentroidLocal[ObjectIdentifier(group)] = c
            }

            self.cloudRMin = max(0, rMin.isFinite ? rMin : 0)
            self.cloudRMax = max(self.cloudRMin + 1, rMax.isFinite ? rMax : self.cloudRMin + 1)

            // Stable one-time alpha order: back→front along *layer-local* wind axis.
            let wL = norm2(windLocal(self.cloudWind, node.eulerAngles.y))
            let R = self.cloudRMax

            for group in self.cloudClusterGroups {
                let gid = ObjectIdentifier(group)
                let c0 = self.cloudClusterCentroidLocal[gid] ?? .zero
                let ax0 = simd_dot(SIMD2(c0.x, c0.z), wL)         // local along-wind coordinate
                let axNorm = (ax0 + R) / max(1, 2 * R)             // 0..1
                let baseOrder = -9_000 + Int(axNorm * 3000.0)

                for bb in group.childNodes {
                    let tie = Int(bitPattern: Unmanaged.passUnretained(bb).toOpaque()) & 0x3FF
                    let order = baseOrder + tie
                    bb.renderingOrder = order
                    for s in bb.childNodes { s.renderingOrder = order }
                    bb.setValue(NSNumber(value: order), forKey: "GL_roKey")
                }
            }

            self.applyCloudSunUniforms()
            self.enableVolumetricCloudImpostors(true)
            self.debugCloudShaderOnce(tag: "after-attach")
            DispatchQueue.main.async { self.debugCloudShaderOnce(tag: "after-runloop") }
        }

        // HDR sun (unchanged)
        let coreDeg: CGFloat = 6.0
        let haloScale: CGFloat = 2.6
        let evBoost: CGFloat = pow(2.0, 1.5)
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
