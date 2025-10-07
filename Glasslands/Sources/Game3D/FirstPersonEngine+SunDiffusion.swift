//
//  FirstPersonEngine+SunDiffusion.swift
//  Glasslands
//
//  Created by . . on 10/6/25.
//
//  Direct sun response + cloud shadow projection (gobo via modulated shadows).
//

import SceneKit
import simd
import Metal
import QuartzCore
import UIKit

extension FirstPersonEngine {

    @MainActor
    func updateSunDiffusion() {
        guard let sunNode = sunLightNode, let sun = sunNode.light else { return }

        let cover = measureSunCover()
        let E_now: CGFloat = (cover.peak <= 0.010) ? 1.0 : CGFloat(expf(-6.0 * cover.union))
        let E_prev = (sunNode.value(forKey: "GL_prevIrradiance") as? CGFloat) ?? E_now
        let k: CGFloat = (E_now >= E_prev) ? 0.50 : 0.15
        let E = E_prev + (E_now - E_prev) * k
        sunNode.setValue(E, forKey: "GL_prevIrradiance")

        let D = max(0.0, 1.0 - E)
        let thickF = CGFloat(smoothstep(0.82, 0.97, cover.union))

        // Sun (the only illuminant)
        let baseIntensity: CGFloat = 1500
        sun.intensity = baseIntensity * max(0.06, E)

        // Softness and darkness react to cover
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

        // No extra sky fill: keep it at zero so sun is the only light
        if let skyFill = scene.rootNode.childNode(withName: "GL_SkyFill", recursively: false)?.light {
            skyFill.intensity = 0
        }

        // HDR halo visibility
        if let sunGroup = sunDiscNode,
           let halo = sunGroup.childNode(withName: "SunHaloHDR", recursively: true),
           let haloMat = halo.geometry?.firstMaterial {
            let baseHalo = (haloMat.value(forKey: "GL_baseHaloIntensity") as? CGFloat) ?? haloMat.emission.intensity
            if haloMat.value(forKey: "GL_baseHaloIntensity") == nil {
                haloMat.setValue(baseHalo, forKey: "GL_baseHaloIntensity")
            }
            haloMat.emission.intensity = baseHalo * D
            halo.isHidden = D <= 1e-3
        }

        ensureCloudShadowProjector()
        updateCloudShadowTextureAndProject()
    }

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

// MARK: - Cloud shadow generation + projection (modulated)

private final class CloudShadowRenderer {
    private weak var engine: FirstPersonEngine?
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private var tex: MTLTexture

    private struct CloudUniforms {
        var sunDirWorld : SIMD4<Float>
        var sunTint     : SIMD4<Float>
        var params0     : SIMD4<Float>
        var params1     : SIMD4<Float>
        var params2     : SIMD4<Float>
        var params3     : SIMD4<Float>
    }
    private struct ShadowUniforms {
        var centerXZ : SIMD2<Float>
        var halfSize : Float
        var pad0     : Float
    }

    init?(engine: FirstPersonEngine, device: MTLDevice) {
        self.engine = engine
        self.device = device
        guard let q = device.makeCommandQueue(),
              let lib = device.makeDefaultLibrary(),
              let fn  = lib.makeFunction(name: "cloudShadowKernel"),
              let ps  = try? device.makeComputePipelineState(function: fn) else { return nil }
        self.queue = q
        self.pipeline = ps

        let desc = MTLTextureDescriptor()
        desc.pixelFormat = .rgba8Unorm
        desc.width  = 1024
        desc.height = 1024
        desc.usage  = [.shaderWrite, .shaderRead]
        guard let t = device.makeTexture(descriptor: desc) else { return nil }
        self.tex = t
    }

    var texture: MTLTexture { tex }

    func update(from mat: SCNMaterial, centerXZ: SIMD2<Float>, halfSize: Float, time: Float) {
        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else { return }

        enc.setComputePipelineState(pipeline)
        enc.setTexture(tex, index: 0)

        func f(_ v: Any?) -> Float { (v as? NSNumber)?.floatValue ?? 0 }
        func v3(_ v: Any?) -> SIMD3<Float> {
            if let v = v as? SCNVector3 { return SIMD3(Float(v.x), Float(v.y), Float(v.z)) }
            return .zero
        }

        let wind      = v3(mat.value(forKey: "wind"))
        let baseY     = f(mat.value(forKey: "baseY"))
        let topY      = f(mat.value(forKey: "topY"))
        let coverage  = f(mat.value(forKey: "coverage"))
        let density   = f(mat.value(forKey: "densityMul"))
        let mieG      = f(mat.value(forKey: "mieG"))
        let powderK   = f(mat.value(forKey: "powderK"))
        let horizon   = f(mat.value(forKey: "horizonLift"))
        let detailMul = f(mat.value(forKey: "detailMul"))
        let domOff3   = v3(mat.value(forKey: "domainOffset"))
        let domRot    = f(mat.value(forKey: "domainRotate"))
        let sunW3     = v3(mat.value(forKey: "sunDirWorld"))
        let sunTint3  = v3(mat.value(forKey: "sunTint"))

        var U = CloudUniforms(
            sunDirWorld: SIMD4<Float>(normalize(SIMD3<Float>(sunW3)), 0),
            sunTint    : SIMD4<Float>(sunTint3, 0),
            params0    : SIMD4<Float>( time, wind.x, wind.y, baseY ),
            params1    : SIMD4<Float>( topY, coverage, max(0, density), 1.0 ),
            params2    : SIMD4<Float>( mieG, max(0, powderK), horizon, max(0, detailMul) ),
            params3    : SIMD4<Float>( domOff3.x, domOff3.y, domRot, 0 )
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
            let L = SCNLight()
            L.type = .directional

            // ⬇️ CRITICAL: for SCNShadowMode.modulated to work, this light must cast shadows.
            L.castsShadow = true
            L.shadowMode = .modulated
            L.shadowMapSize = CGSize(width: 1024, height: 1024)
            L.shadowSampleCount = 1
            L.shadowRadius = 0
            L.shadowColor = UIColor(white: 0, alpha: 1.0) // darken fully where gobo is dark

            L.intensity = 0                 // does not illuminate, only modulates
            L.orthographicScale = 2400.0    // coverage (metres)
            L.zNear = 0.1
            L.zFar  = 20000
            L.automaticallyAdjustsShadowProjection = false

            // Only affect ground (matches TerrainChunkNode)
            L.categoryBitMask = 0x0000_0400

            // Set up the gobo property once; bind contents every frame.
            if let g = L.gobo {
                g.wrapS = .clamp
                g.wrapT = .clamp
                g.mipFilter = .linear
                g.minificationFilter = .linear
                g.magnificationFilter = .linear
                g.intensity = 1.0
            }

            let node = SCNNode()
            node.name = "GL_CloudShadows"
            node.light = L
            node.categoryBitMask = 0x0000_0400
            scene.rootNode.addChildNode(node)
            _cloudShadowNode = node
        }

        if let node = _cloudShadowNode {
            let dir = -sunDirWorld
            let origin = yawNode.presentation.position
            node.position = origin
            let target = SCNVector3(origin.x + dir.x, origin.y + dir.y, origin.z + dir.z)
            node.look(at: target, up: scene.rootNode.worldUp, localFront: SCNVector3(0,0,-1))
        }
    }

    @MainActor
    func updateCloudShadowTextureAndProject() {
        guard let proj = _cloudShadowNode?.light,
              let renderer = _cloudShadowRenderer else { return }

        // Get cloud parameters from the volumetric layer material
        guard let cloudMat = scene.rootNode
            .childNode(withName: "VolumetricCloudLayer", recursively: true)?
            .geometry?.firstMaterial else { return }

        // Centre the orthographic gobo around the camera XZ; sync scale
        let pos = (scnView?.pointOfView ?? camNode).presentation.simdWorldPosition
        let centerXZ = SIMD2<Float>(pos.x, pos.z)
        let halfSize: Float = 1200
        proj.orthographicScale = CGFloat(halfSize * 2)

        // Generate the cloud transmittance texture
        let t = Float(CACurrentMediaTime())
        renderer.update(from: cloudMat, centerXZ: centerXZ, halfSize: halfSize, time: t)

        // Bind as gobo; modulated shadows read the gobo as the “shadow”
        if let gobo = proj.gobo {
            gobo.contents = renderer.texture
            gobo.intensity = 1.0
        }
    }
}
