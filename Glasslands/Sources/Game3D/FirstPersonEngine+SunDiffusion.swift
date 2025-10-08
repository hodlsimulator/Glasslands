//
//  FirstPersonEngine+SunDiffusion.swift
//  Glasslands
//
//  Created by . . on 10/6/25.
//
//  Per-frame sun diffusion + cloud-shadow gobo.
//

import SceneKit
import simd
import Metal
import QuartzCore
import UIKit

extension FirstPersonEngine {

    // MARK: Sun diffusion (key light + gobo control)
    @MainActor
    func updateSunDiffusion() {
        guard let sunNode = sunLightNode, let sun = sunNode.light else { return }

        let cover = measureSunCover()
        let E_now: CGFloat = (cover.peak <= 0.010) ? 1.0 : CGFloat(expf(-6.0 * cover.union))
        let E_prev = (sunNode.value(forKey: "GL_prevIrradiance") as? CGFloat) ?? E_now
        let k: CGFloat = (E_now >= E_prev) ? 0.50 : 0.15
        let E = E_prev + (E_now - E_prev) * k
        sunNode.setValue(E, forKey: "GL_prevIrradiance")

        sun.type = .directional
        sun.intensity = 1500
        sun.color = UIColor.white

        let D = max(0.0, 1.0 - E)
        sun.shadowRadius = 1.2 + (10.0 - 1.2) * D
        sun.shadowSampleCount = max(1, Int(round(6 + D * 8))) // 6…14
        sun.shadowColor = UIColor(white: 0.0, alpha: 0.60)

        ensureCloudShadowProjector()
        updateCloudShadowMap()

        if
            let sunGroup = sunDiscNode,
            let halo = sunGroup.childNode(withName: "SunHaloHDR", recursively: true),
            let haloMat = halo.geometry?.firstMaterial
        {
            let baseHalo = (haloMat.value(forKey: "GL_baseHaloIntensity") as? CGFloat) ?? haloMat.emission.intensity
            if haloMat.value(forKey: "GL_baseHaloIntensity") == nil {
                haloMat.setValue(baseHalo, forKey: "GL_baseHaloIntensity")
            }
            haloMat.emission.intensity = baseHalo * (1.0 - E)
            halo.isHidden = (1.0 - E) <= 1e-3
        }
    }

    // MARK: Cloud-shadow projector (compute → material uniform)
    @MainActor
    private func ensureCloudShadowProjector() {
        guard let view = scnView, let device = view.device, let sun = sunLightNode?.light else { return }

        if (sunLightNode?.value(forKey: "GL_shadowQ") as? MTLCommandQueue) == nil {
            sunLightNode?.setValue(device.makeCommandQueue(), forKey: "GL_shadowQ")
        }

        if (sunLightNode?.value(forKey: "GL_shadowPipe") as? MTLComputePipelineState) == nil {
            guard
                let lib  = try? device.makeDefaultLibrary(bundle: .main),
                let fn   = lib.makeFunction(name: "cloudShadowKernel"),
                let pipe = try? device.makeComputePipelineState(function: fn)
            else { return }
            sunLightNode?.setValue(pipe, forKey: "GL_shadowPipe")
        }

        if (sunLightNode?.value(forKey: "GL_shadowTex") as? MTLTexture) == nil {
            let W = 256, H = 256
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: W, height: H, mipmapped: false
            )
            desc.usage = [.shaderWrite, .shaderRead]
            desc.storageMode = .shared
            guard let tex = device.makeTexture(descriptor: desc) else { return }
            sunLightNode?.setValue(tex, forKey: "GL_shadowTex")

            let white = [UInt8](repeating: 0xFF, count: W * H * 4)
            white.withUnsafeBytes { ptr in
                tex.replace(
                    region: MTLRegionMake2D(0, 0, W, H),
                    mipmapLevel: 0,
                    withBytes: ptr.baseAddress!,
                    bytesPerRow: W * 4
                )
            }

            // Create and cache a single SCNMaterialProperty bound to this texture.
            let prop = SCNMaterialProperty(contents: tex)
            prop.minificationFilter = .linear
            prop.magnificationFilter = .linear
            prop.mipFilter = .linear
            sunLightNode?.setValue(prop, forKey: "GL_shadowTexProp")
        }

        // Keep the gobo around if wanted, but never let it shade the world; material-based shadows will do that.
        if let tex = (sunLightNode?.value(forKey: "GL_shadowTex") as? MTLTexture) {
            sun.gobo?.contents = tex
        }
        sun.gobo?.intensity = 0.0
        sun.gobo?.wrapS = .clamp
        sun.gobo?.wrapT = .clamp
        sun.gobo?.minificationFilter = .linear
        sun.gobo?.magnificationFilter = .linear
    }

    @MainActor
    private func updateCloudShadowMap() {
        guard
            let pipe = sunLightNode?.value(forKey: "GL_shadowPipe") as? MTLComputePipelineState,
            let q    = sunLightNode?.value(forKey: "GL_shadowQ")    as? MTLCommandQueue,
            let out  = sunLightNode?.value(forKey: "GL_shadowTex")  as? MTLTexture,
            let sun  = sunLightNode?.light
        else { return }

        // Make sure the gobo never contributes, even on throttled frames.
        sun.gobo?.intensity = 0.0

        let tNow = CACurrentMediaTime()
        let tPrev = (sunLightNode?.value(forKey: "GL_shadowT") as? CFTimeInterval) ?? 0
        if tNow - tPrev < 0.12 {
            // Even when throttled, still update the param uniform so there’s no “pop” when crossing grid cells.
            pushShadowUniformsWithoutCompute()
            return
        }
        sunLightNode?.setValue(tNow, forKey: "GL_shadowT")

        // World-anchored domain near the camera; snapped to avoid texture swimming.
        let pov = (scnView?.pointOfView ?? camNode).presentation
        let camPos = pov.simdWorldPosition
        let grid: Float = 256.0
        let anchor = simd_float2(
            round(camPos.x / grid) * grid,
            round(camPos.z / grid) * grid
        )

        let halfSize: Float = 560.0
        sun.orthographicScale = CGFloat(halfSize)

        var u = CloudUniforms(
            sunDirWorld: simd_float4(sunDirWorld.x, sunDirWorld.y, sunDirWorld.z, 0),
            sunTint:     simd_float4(1, 1, 1, 1),
            params0:     simd_float4(Float(tNow), cloudWind.x, cloudWind.y, 400.0),
            params1:     simd_float4(1400.0, 0.44, 2.6, 0.0),
            params2:     simd_float4(0, 0, 0.10, 0.75),
            params3:     simd_float4(cloudDomainOffset.x, cloudDomainOffset.y, 0.0, 0.0)
        )
        var su = ShadowUniforms(centerXZ: anchor, halfSize: halfSize)

        guard
            let device = scnView?.device,
            let bufU = device.makeBuffer(length: MemoryLayout<CloudUniforms>.stride, options: .storageModeShared),
            let bufS = device.makeBuffer(length: MemoryLayout<ShadowUniforms>.stride, options: .storageModeShared),
            let cmd  = q.makeCommandBuffer(),
            let enc  = cmd.makeComputeCommandEncoder()
        else { return }

        memcpy(bufU.contents(), &u, MemoryLayout<CloudUniforms>.stride)
        memcpy(bufS.contents(), &su, MemoryLayout<ShadowUniforms>.stride)

        enc.setComputePipelineState(pipe)
        enc.setTexture(out, index: 0)
        enc.setBuffer(bufU, offset: 0, index: 0)
        enc.setBuffer(bufS, offset: 0, index: 1)

        let w = pipe.threadExecutionWidth
        let h = max(1, pipe.maxTotalThreadsPerThreadgroup / w)
        enc.dispatchThreads(
            MTLSize(width: out.width, height: out.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1)
        )
        enc.endEncoding()
        cmd.commit()

        // Push uniforms + texture to ground materials.
        let prop = (sunLightNode?.value(forKey: "GL_shadowTexProp") as? SCNMaterialProperty)
            ?? {
                let p = SCNMaterialProperty(contents: out)
                p.minificationFilter = .linear
                p.magnificationFilter = .linear
                p.mipFilter = .linear
                sunLightNode?.setValue(p, forKey: "GL_shadowTexProp")
                return p
            }()

        prop.contents = out // same texture; harmless if unchanged.

        let params = SCNVector3(anchor.x, anchor.y, halfSize)
        for m in GroundShadowMaterials.shared.all() {
            m.setValue(prop,   forKey: "gl_shadowTex")
            m.setValue(params, forKey: "gl_shadowParams")
        }
    }

    // When throttled, keep params in sync so crossing a grid boundary doesn’t “pop”.
    @MainActor
    private func pushShadowUniformsWithoutCompute() {
        guard
            let out = sunLightNode?.value(forKey: "GL_shadowTex") as? MTLTexture
        else { return }

        let pov = (scnView?.pointOfView ?? camNode).presentation
        let camPos = pov.simdWorldPosition
        let grid: Float = 256.0
        let anchor = simd_float2(
            round(camPos.x / grid) * grid,
            round(camPos.z / grid) * grid
        )
        let halfSize: Float = 560.0

        let prop = (sunLightNode?.value(forKey: "GL_shadowTexProp") as? SCNMaterialProperty)
            ?? {
                let p = SCNMaterialProperty(contents: out)
                p.minificationFilter = .linear
                p.magnificationFilter = .linear
                p.mipFilter = .linear
                sunLightNode?.setValue(p, forKey: "GL_shadowTexProp")
                return p
            }()

        prop.contents = out

        let params = SCNVector3(anchor.x, anchor.y, halfSize)
        for m in GroundShadowMaterials.shared.all() {
            m.setValue(prop,   forKey: "gl_shadowTex")
            m.setValue(params, forKey: "gl_shadowParams")
        }
    }

    // MARK: - Types / helpers

    private struct CloudUniforms {
        var sunDirWorld: simd_float4        // xyz = dir
        var sunTint:     simd_float4
        var params0:     simd_float4        // time, wind.x, wind.y, baseY
        var params1:     simd_float4        // topY, coverage, densityMul, pad
        var params2:     simd_float4        // pad0, pad1, horizonLift, detailMul
        var params3:     simd_float4        // domainOffset.x, domainOffset.y, domainRotate, pad
    }

    private struct ShadowUniforms {
        var centerXZ: simd_float2
        var halfSize: Float
        var pad0:     Float = 0
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

    // Billboard cover estimator used for sun halo / penumbra feel.
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

    @inline(__always)
    private func degreesToRadians(_ deg: Float) -> Float { deg * .pi / 180.0 }
}
