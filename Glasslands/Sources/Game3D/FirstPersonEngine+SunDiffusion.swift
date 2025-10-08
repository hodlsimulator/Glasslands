//
//  FirstPersonEngine+SunDiffusion.swift
//  Glasslands
//
//  Created by . . on 10/6/25.
//
//  Per-frame sun diffusion + cloud-shadow gobo.
//  – Object shadows follow the stable 786737 lighting setup (no frustum poking here).
//  – Cloud gobo updates its texture only; it never changes the light's projection.
//

import SceneKit
import simd
import Metal
import QuartzCore
import UIKit

extension FirstPersonEngine {

    // MARK: Sun diffusion (intensity, halo, and shadows)
    func updateSunDiffusion() {
        guard let sunNode = sunLightNode, let sun = sunNode.light else { return }

        // Irradiance proxy from billboard overlap (0…1)
        let cover = measureSunCover()
        let E_now: CGFloat = (cover.peak <= 0.010) ? 1.0 : CGFloat(expf(-6.0 * cover.union))

        // Smooth: faster when clearing, gentler when clouding over
        let E_prev = (sunNode.value(forKey: "GL_prevIrradiance") as? CGFloat) ?? E_now
        let k: CGFloat = (E_now >= E_prev) ? 0.50 : 0.15
        let E = E_prev + (E_now - E_prev) * k
        sunNode.setValue(E, forKey: "GL_prevIrradiance")

        // Sun is the only light
        sun.type = .directional
        sun.intensity = 1500 * max(0.06, E)
        sun.color = UIColor.white

        // Object shadow appearance (do NOT alter projection/frustum here)
        let D = max(0.0, 1.0 - E)
        let penClear: CGFloat = 1.2
        let penCloud: CGFloat = 12.0
        sun.shadowRadius = penClear + (penCloud - penClear) * D
        sun.shadowSampleCount = max(1, Int(round(2 + D * 14))) // 2..16
        let alphaClear: CGFloat = 0.82
        let alphaCloudy: CGFloat = 0.22
        sun.shadowColor = UIColor(white: 0.0, alpha: alphaClear + (alphaCloudy - alphaClear) * D)

        // Update cloud-shadow gobo (texture only)
        ensureCloudShadowProjector()
        updateCloudShadowMap()

        // HDR halo intensity follows cloudiness
        if let sunGroup = sunDiscNode,
           let halo = sunGroup.childNode(withName: "SunHaloHDR", recursively: true),
           let haloMat = halo.geometry?.firstMaterial {
            let baseHalo = (haloMat.value(forKey: "GL_baseHaloIntensity") as? CGFloat) ?? haloMat.emission.intensity
            if haloMat.value(forKey: "GL_baseHaloIntensity") == nil {
                haloMat.setValue(baseHalo, forKey: "GL_baseHaloIntensity")
            }
            haloMat.emission.intensity = baseHalo * (1.0 - E)
            halo.isHidden = (1.0 - E) <= 1e-3
        }
    }

    // MARK: Cloud shadow projector (compute → gobo)

    private struct CloudUniforms {
        var sunDirWorld: SIMD4<Float>
        var sunTint: SIMD4<Float>
        var params0: SIMD4<Float>   // time, wind.x, wind.y, baseY
        var params1: SIMD4<Float>   // topY, coverage, densityMul, pad
        var params2: SIMD4<Float>   // pad0, pad1, horizonLift, detailMul
        var params3: SIMD4<Float>   // domainOffset.x, domainOffset.y, domainRotate, pad
    }
    private struct ShadowUniforms {
        var centerXZ: SIMD2<Float>
        var halfSize: Float
        var pad0: Float = 0
    }

    private var shadowTexture: MTLTexture? {
        get { (sunLightNode?.value(forKey: "GL_shadowTex") as? MTLTexture) }
        set { sunLightNode?.setValue(newValue, forKey: "GL_shadowTex") }
    }
    private var shadowPipeline: MTLComputePipelineState? {
        get { (sunLightNode?.value(forKey: "GL_shadowPipe") as? MTLComputePipelineState) }
        set { sunLightNode?.setValue(newValue, forKey: "GL_shadowPipe") }
    }
    private var shadowQueue: MTLCommandQueue? {
        get { (sunLightNode?.value(forKey: "GL_shadowQ") as? MTLCommandQueue) }
        set { sunLightNode?.setValue(newValue, forKey: "GL_shadowQ") }
    }
    private var lastShadowTime: CFTimeInterval {
        get { (sunLightNode?.value(forKey: "GL_shadowT") as? CFTimeInterval) ?? 0 }
        set { sunLightNode?.setValue(newValue, forKey: "GL_shadowT") }
    }

    @MainActor
    private func ensureCloudShadowProjector() {
        guard let view = scnView, let device = view.device, let sun = sunLightNode?.light else { return }

        if shadowQueue == nil { shadowQueue = device.makeCommandQueue() }

        if shadowPipeline == nil {
            guard let lib = try? device.makeDefaultLibrary(bundle: .main),
                  let fn  = lib.makeFunction(name: "cloudShadowKernel"),
                  let pipe = try? device.makeComputePipelineState(function: fn) else { return }
            shadowPipeline = pipe
        }

        if shadowTexture == nil {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                width: 1024, height: 1024,
                                                                mipmapped: false)
            desc.usage = [.shaderWrite, .shaderRead]
            shadowTexture = device.makeTexture(descriptor: desc)
        }

        // Attach as a gobo; do not modify the light's projection here
        if let gobo = sun.gobo {
            gobo.contents = shadowTexture
            gobo.intensity = 1.0
            gobo.wrapS = .clamp
            gobo.wrapT = .clamp
            gobo.minificationFilter = .linear
            gobo.magnificationFilter = .linear
        }
    }

    @MainActor
    private func updateCloudShadowMap() {
        guard let pipe = shadowPipeline,
              let q = shadowQueue,
              let outTex = shadowTexture else { return }

        // Throttle to ~8 Hz
        let tNow = CACurrentMediaTime()
        if tNow - lastShadowTime < 0.12 { return }
        lastShadowTime = tNow

        // Build uniforms
        let pov = (scnView?.pointOfView ?? camNode).presentation
        let camPos = pov.simdWorldPosition
        let halfSize: Float = 2200.0

        var u = CloudUniforms(
            sunDirWorld: SIMD4<Float>(sunDirWorld.x, sunDirWorld.y, sunDirWorld.z, 0),
            sunTint: SIMD4<Float>(1,1,1,1),
            params0: SIMD4<Float>(Float(tNow), cloudWind.x, cloudWind.y, 400.0),
            params1: SIMD4<Float>(1400.0, 0.44, 1.20, 0.0),
            params2: SIMD4<Float>(0, 0, 0.10, 0.90),
            params3: SIMD4<Float>(cloudDomainOffset.x, cloudDomainOffset.y, 0.0, 0.0)
        )
        var su = ShadowUniforms(centerXZ: SIMD2<Float>(camPos.x, camPos.z),
                                halfSize: halfSize)

        guard let device = scnView?.device,
              let bufU = device.makeBuffer(length: MemoryLayout<CloudUniforms>.stride, options: .storageModeShared),
              let bufS = device.makeBuffer(length: MemoryLayout<ShadowUniforms>.stride, options: .storageModeShared),
              let cmd = q.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else { return }

        memcpy(bufU.contents(), &u, MemoryLayout<CloudUniforms>.stride)
        memcpy(bufS.contents(), &su, MemoryLayout<ShadowUniforms>.stride)

        enc.setComputePipelineState(pipe)
        enc.setTexture(outTex, index: 0)
        enc.setBuffer(bufU, offset: 0, index: 0)
        enc.setBuffer(bufS, offset: 0, index: 1)

        let w = pipe.threadExecutionWidth
        let h = max(1, pipe.maxTotalThreadsPerThreadgroup / w)
        enc.dispatchThreads(MTLSize(width: outTex.width, height: outTex.height, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
        enc.endEncoding()
        cmd.commit()
    }

    // MARK: Screen-space cover estimator (unchanged)
    private func measureSunCover() -> (peak: Float, union: Float) {
        guard let layer = skyAnchor.childNode(withName: "CumulusBillboardLayer", recursively: true) else { return (0.0, 0.0) }

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

    @inline(__always)
    private func degreesToRadians(_ deg: Float) -> Float { deg * .pi / 180.0 }
}
