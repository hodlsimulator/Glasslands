//
//  FirstPersonEngine+SunDiffusion.swift
//  Glasslands
//
//  Created by . . on 10/6/25.
//
//  Direct sun response and cloud‑shadow projection (gobo).
//  – Keeps earlier “diffused sun under cover” behaviour
//  – Adds GPU‑generated cloud shadow texture and projects it using a
//    secondary directional light in .modulated shadow mode.
//  – The projector’s orthographic area tracks the camera.
//
//  Note: SceneKit supports directional‑light gobos and exposes
//        `orthographicScale` to set the projection extent.
//        (See Apple docs for SCNLight.orthographicScale and
//         “modulated” shadow mode.)
//

import SceneKit
import simd
import Metal
import CoreImage
import UIKit

extension FirstPersonEngine {

    // MARK: - Per‑frame driver
    @MainActor
    func updateSunDiffusion() {
        guard let sunNode = sunLightNode, let sun = sunNode.light else { return }

        // Existing cover logic (kept intact)
        let cover = measureSunCover() // (peak, union) in [0,1]
        let E_now: CGFloat = (cover.peak <= 0.010) ? 1.0 : CGFloat(expf(-6.0 * cover.union))
        let E_prev = (sunNode.value(forKey: "GL_prevIrradiance") as? CGFloat) ?? E_now
        let k: CGFloat = (E_now >= E_prev) ? 0.50 : 0.15
        let E = E_prev + (E_now - E_prev) * k
        sunNode.setValue(E, forKey: "GL_prevIrradiance")

        let D = max(0.0, 1.0 - E)
        let thickF = CGFloat(smoothstep(0.82, 0.97, cover.union))

        // --- Direct sun ---
        let baseIntensity: CGFloat = 1500
        sun.intensity = baseIntensity * max(0.06, E)

        // --- Geometry shadow softness/strength (as before) ---
        let penClear: CGFloat = 0.35
        let penCloudBase: CGFloat = 13.0
        let penCloud = penCloudBase + 3.0 * thickF
        sun.shadowRadius = penClear + (penCloud - penClear) * D
        sun.shadowSampleCount = max(1, Int(round(2 + D * 16)))
        let alphaClear: CGFloat = 0.82
        let alphaSoftFloor: CGFloat = 0.28
        let alphaThickFloor: CGFloat = 0.06
        let floorA = mix(alphaSoftFloor, alphaThickFloor, thickF)
        let a = alphaClear + (floorA - alphaClear) * D
        sun.shadowColor = UIColor(white: 0.0, alpha: a)

        // --- Sky fill lift under cloud (unchanged) ---
        if let skyFill = scene.rootNode.childNode(withName: "GL_SkyFill", recursively: false)?.light {
            let minFill: CGFloat = 12
            let maxFillSoft: CGFloat = 380
            let maxFillThick: CGFloat = 560
            let maxFill = mix(maxFillSoft, maxFillThick, thickF)
            skyFill.intensity = minFill + (maxFill - minFill) * pow(D, 0.85)
        }

        // --- HDR halo visibility ---
        if let sunGroup = sunDiscNode,
           let halo = sunGroup.childNode(withName: "SunHaloHDR", recursively: true),
           let haloMat = halo.geometry?.firstMaterial
        {
            let baseHalo = (haloMat.value(forKey: "GL_baseHaloIntensity") as? CGFloat) ?? haloMat.emission.intensity
            if haloMat.value(forKey: "GL_baseHaloIntensity") == nil {
                haloMat.setValue(baseHalo, forKey: "GL_baseHaloIntensity")
            }
            haloMat.emission.intensity = baseHalo * D
            halo.isHidden = D <= 1e-3
        }

        // --- Cloud Shadow Gobo (NEW) ---
        ensureCloudShadowProjector()
        updateCloudShadowTextureAndProject()
    }

    // MARK: - Sun cover (peak + union) – unchanged
    @MainActor
    private func measureSunCover() -> (peak: Float, union: Float) {
        guard let layer = skyAnchor.childNode(withName: "CumulusBillboardLayer", recursively: true) else {
            return (0.0, 0.0)
        }
        let pov = (scnView?.pointOfView ?? camNode).presentation
        let cam = pov.simdWorldPosition
        let sunW = simd_normalize(sunDirWorld)
        let sunR: Float = degreesToRadians(6.0) * 0.5
        let feather: Float = 0.15 * (.pi / 180.0)

        var peak: Float = 0.0
        var oneMinus: Float = 1.0

        layer.enumerateChildNodes { node, _ in
            guard let plane = node.geometry as? SCNPlane else { return }
            let pw = node.presentation.simdWorldPosition
            let toP = simd_normalize(pw - cam)
            let cosAng = simd_clamp(simd_dot(sunW, toP), -1.0, 1.0)
            let dAngle = acosf(cosAng)
            let dist: Float = simd_length(pw - cam)
            if dist <= 1e-3 { return }
            let size: Float = Float(plane.width)
            let puffR: Float = atanf((size * 0.30) / max(1e-3, dist))
            let overlap = (puffR + sunR + feather) - dAngle
            if overlap <= 0 { return }
            let denom = max(1e-3, puffR + sunR + feather)
            var t = max(0.0, min(1.0, overlap / denom))
            let angArea = min(1.0, (puffR * puffR) / (sunR * sunR))
            t *= angArea
            peak = max(peak, t)
            oneMinus *= max(0.0, 1.0 - min(0.98, t))
        }

        let union = 1.0 - oneMinus
        return ((peak < 0.01) ? 0.0 : peak, min(1.0, union))
    }

    @inline(__always) private func degreesToRadians(_ deg: Float) -> Float { deg * .pi / 180.0 }
    @inline(__always) private func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
        if e0 == e1 { return x >= e1 ? 1 : 0 }
        let t = max(0, min(1, (x - e0) / (e1 - e0)))
        return t * t * (3 - 2 * t)
    }
    @inline(__always) private func mix(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
}

// MARK: - Cloud shadow generation + projection
private final class CloudShadowRenderer {
    private weak var engine: FirstPersonEngine?
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState

    private var tex: MTLTexture
    private var ciContext: CIContext?

    // Ring buffer of uniforms (keeps CPU writes minimal)
    private struct CloudUniforms {
        var sunDirWorld : SIMD4<Float>
        var sunTint     : SIMD4<Float>
        var params0     : SIMD4<Float> // time, wind.x, wind.y, baseY
        var params1     : SIMD4<Float> // topY, coverage, densityMul, stepMul
        var params2     : SIMD4<Float> // mieG, powderK, horizonLift, detailMul
        var params3     : SIMD4<Float> // domainOffX, domainOffY, domainRotate, 0
    }
    private struct ShadowUniforms {
        var centerXZ : SIMD2<Float>
        var halfSize : Float
        var pad0     : Float
    }

    private var lastCenterXZ = SIMD2<Float>(repeating: .nan)
    private var lastHalfSize : Float = .nan

    init?(engine: FirstPersonEngine, device: MTLDevice) {
        self.engine = engine
        self.device = device
        guard let q = device.makeCommandQueue(),
              let lib = device.makeDefaultLibrary(),
              let fn  = lib.makeFunction(name: "cloudShadowKernel"),
              let ps  = try? device.makeComputePipelineState(function: fn)
        else { return nil }

        self.queue    = q
        self.pipeline = ps

        let desc = MTLTextureDescriptor()
        desc.pixelFormat = .rgba8Unorm
        desc.width  = 1024
        desc.height = 1024
        desc.usage  = [.shaderWrite, .shaderRead]
        guard let t = device.makeTexture(descriptor: desc) else { return nil }
        self.tex = t

        // Optional: CIContext fallback if a UIImage gobo is ever needed
        self.ciContext = CIContext(mtlDevice: device)
    }

    var texture: MTLTexture { tex }

    func update(centerXZ: SIMD2<Float>, halfSize: Float, time: Float) {
        guard let e = engine else { return }
        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else { return }

        enc.setComputePipelineState(pipeline)
        enc.setTexture(tex, index: 0)

        // Pack cloud uniforms straight from engine/material state
        var U = CloudUniforms(
            sunDirWorld: SIMD4<Float>(normalize(e.sunDirWorld), 0),
            sunTint    : SIMD4<Float>(e.cloudSunTint, 0),
            params0    : SIMD4<Float>( time,
                                       e.cloudWind.x, e.cloudWind.y,
                                       e.cloudBaseY ),
            params1    : SIMD4<Float>( e.cloudTopY,
                                       e.cloudCoverage,
                                       e.cloudDensityMul,
                                       1.0 ),
            params2    : SIMD4<Float>( e.cloudMieG,
                                       e.cloudPowderK,
                                       e.cloudHorizonLift,
                                       e.cloudDetailMul ),
            params3    : SIMD4<Float>( e.cloudDomainOffset.x,
                                       e.cloudDomainOffset.y,
                                       e.cloudDomainRotate,
                                       0)
        )
        var SU = ShadowUniforms(centerXZ: centerXZ, halfSize: halfSize, pad0: 0)

        enc.setBytes(&U,  length: MemoryLayout<CloudUniforms>.size, index: 0)
        enc.setBytes(&SU, length: MemoryLayout<ShadowUniforms>.size, index: 1)

        let w = pipeline.threadExecutionWidth
        let h = pipeline.maxTotalThreadsPerThreadgroup / w
        let tg = MTLSize(width: w, height: h, depth: 1)
        let grid = MTLSize(width: tex.width, height: tex.height, depth: 1)
        enc.dispatchThreads(grid, threadsPerThreadgroup: tg)
        enc.endEncoding()
        cmd.commit()

        lastCenterXZ = centerXZ
        lastHalfSize = halfSize
    }
}

private var _cloudShadowRenderer: CloudShadowRenderer?
private var _cloudShadowNode: SCNNode?

private extension FirstPersonEngine {

    @MainActor
    func ensureCloudShadowProjector() {
        if _cloudShadowRenderer == nil, let dev = scnView?.device {
            _cloudShadowRenderer = CloudShadowRenderer(engine: self, device: dev)
        }
        if _cloudShadowNode == nil {
            // Directional projector that multiplies scene colour by its gobo.
            let L = SCNLight()
            L.type = .directional
            L.intensity = 0                // no additive light — only modulation
            L.castsShadow = false
            L.shadowMode = .modulated      // project gobo; multiply scene colour
            L.orthographicScale = 1200.0   // extent (meters) covered by the gobo
            L.categoryBitMask = 0x0000_0403

            let node = SCNNode()
            node.name = "GL_CloudShadows"
            node.light = L
            scene.rootNode.addChildNode(node)
            _cloudShadowNode = node
        }

        // Aim the projector along the incoming sunlight (−dir)
        if let node = _cloudShadowNode {
            let dir = -sunDirWorld
            let origin = yawNode.presentation.position
            node.position = origin
            let target = SCNVector3(origin.x + dir.x, origin.y + dir.y, origin.z + dir.z)
            node.look(at: target, up: scene.rootNode.worldUp, localFront: SCNVector3(0,0,-1))
        }
    }

    /// Builds/updates the cloud shadow gobo and projects it from the sun‑aligned light.
    @MainActor
    func updateCloudShadowTextureAndProject() {
        guard let proj = _cloudShadowNode?.light,
              let renderer = _cloudShadowRenderer else { return }

        // Keep the gobo’s orthographic area centred near the player; if a very
        // large world is streamed, this updates seamlessly as the camera moves.
        let pos = (scnView?.pointOfView ?? camNode).presentation.simdWorldPosition
        let centerXZ = SIMD2<Float>(pos.x, pos.z)

        // Optionally scale the coverage by height scale / gameplay area
        let halfSize: Float = max(600, cfg.tileSize * Float(cfg.tilesX) * 2)
        proj.orthographicScale = CGFloat(halfSize * 2)

        // Advance shadow map at a modest cadence (still very cheap on GPU)
        let t = Float(CACurrentMediaTime())
        renderer.update(centerXZ: centerXZ, halfSize: halfSize, time: t)

        // Bind the GPU texture directly as the gobo image
        proj.gobo?.contents = renderer.texture
        proj.gobo?.intensity = 1.0
        proj.gobo?.layer = nil
    }
}
