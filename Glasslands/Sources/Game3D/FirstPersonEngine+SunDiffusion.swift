//
//  FirstPersonEngine+SunDiffusion.swift
//  Glasslands
//
//  Created by . . on 10/6/25.
//
//  Cloud-shadow map + projector-light that ONLY affects terrain (0x0400).
//  Main sun stays deferred for crisp geometry shadows; projector uses
//  .modulated so the gobo darkens terrain wherever the map is dark.
//

import SceneKit
import simd
import Metal
import QuartzCore
import UIKit

extension FirstPersonEngine {

    // MARK: Sun diffusion (key light + halo)

    @MainActor
    func updateSunDiffusion() {
        guard let sunNode = sunLightNode, let sun = sunNode.light else { return }

        // Soft veil estimate just for halo aesthetics
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
        sun.shadowSampleCount = max(1, Int(round(6 + D * 8)))
        sun.shadowColor = UIColor(white: 0.0, alpha: 0.70)

        ensureCloudShadowProjector()
        updateCloudShadowMap()

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

    // MARK: Cloud-shadow projector (compute → modulated shadow on terrain)

    @MainActor
    private func ensureCloudShadowProjector() {
        guard let view = scnView, let device = view.device else { return }

        // Command queue
        if (sunLightNode?.value(forKey: "GL_shadowQ") as? MTLCommandQueue) == nil {
            sunLightNode?.setValue(device.makeCommandQueue(), forKey: "GL_shadowQ")
        }

        // Compute pipeline
        if (sunLightNode?.value(forKey: "GL_shadowPipe") as? MTLComputePipelineState) == nil {
            guard let lib  = try? device.makeDefaultLibrary(bundle: .main),
                  let fn   = lib.makeFunction(name: "cloudShadowKernel"),
                  let pipe = try? device.makeComputePipelineState(function: fn)
            else { return }
            sunLightNode?.setValue(pipe, forKey: "GL_shadowPipe")
        }

        // Output texture
        if (sunLightNode?.value(forKey: "GL_shadowTex") as? MTLTexture) == nil {
            let W = 256, H = 256
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: W, height: H, mipmapped: false)
            desc.usage = [.shaderWrite, .shaderRead]
            desc.storageMode = .shared
            guard let tex = device.makeTexture(descriptor: desc) else { return }
            sunLightNode?.setValue(tex, forKey: "GL_shadowTex")

            let white = [UInt8](repeating: 0xFF, count: W * H * 4)
            white.withUnsafeBytes { ptr in
                tex.replace(region: MTLRegionMake2D(0, 0, W, H),
                            mipmapLevel: 0, withBytes: ptr.baseAddress!, bytesPerRow: W * 4)
            }
        }

        // Fallback empty clusters buffer (always bind something at index 2)
        if (sunLightNode?.value(forKey: "GL_emptyClusters") as? MTLBuffer) == nil {
            let buf = device.makeBuffer(length: MemoryLayout<Cluster>.stride, options: .storageModeShared)!
            memset(buf.contents(), 0, MemoryLayout<Cluster>.stride)
            sunLightNode?.setValue(buf, forKey: "GL_emptyClusters")
        }

        // Dedicated projector light: modulated shadows on terrain only
        if (sunLightNode?.value(forKey: "GL_shadowProjector") as? SCNNode) == nil {
            let L = SCNLight()
            L.type = .directional
            L.castsShadow = true
            L.shadowMode = .modulated         // ← use gobo as the shadow mask
            L.shadowColor = UIColor(white: 0.0, alpha: 1.0)
            L.categoryBitMask = 0x0000_0400   // ← terrain only

            let N = SCNNode()
            N.name = "GL_CloudShadowProjector"
            N.light = L
            scene.rootNode.addChildNode(N)

            sunLightNode?.setValue(N, forKey: "GL_shadowProjector")
        }

        // (Optional) If you previously attached the gobo to the main sun, clear it
        // to avoid double-darkening from two gobos:
        if let sun = sunLightNode?.light { sun.gobo?.contents = nil }
    }

    // Swift mirrors of Metal structs
    private struct CloudUniforms {
        var sunDirWorld: simd_float4
        var sunTint    : simd_float4
        var params0    : simd_float4 // time, wind.x, wind.y, baseY
        var params1    : simd_float4 // topY, coverage, densityMul, pad
        var params2    : simd_float4 // pad0, pad1, horizonLift, detailMul
        var params3    : simd_float4 // domainOffset.x, domainOffset.y, domainRotate, pad
    }
    private struct ShadowUniforms {
        var centerXZ: simd_float2
        var halfSize: Float
        var pad0: Float = 0 // keep layouts in sync with Metal
    }
    private struct Cluster {
        var pos: simd_float3
        var rad: Float
    }

    @MainActor
    private func updateCloudShadowMap() {
        guard
            let pipe = sunLightNode?.value(forKey: "GL_shadowPipe") as? MTLComputePipelineState,
            let q    = sunLightNode?.value(forKey: "GL_shadowQ") as? MTLCommandQueue,
            let out  = sunLightNode?.value(forKey: "GL_shadowTex") as? MTLTexture
        else { return }

        // Projector tracks the sun’s pose and uses the map as gobo
        if let proj = sunLightNode?.value(forKey: "GL_shadowProjector") as? SCNNode {
            let origin = yawNode.presentation.position
            let dir = simd_normalize(sunDirWorld)
            let target = SCNVector3(origin.x - dir.x, origin.y - dir.y, origin.z - dir.z)
            proj.position = origin
            proj.look(at: target, up: scene.rootNode.worldUp, localFront: SCNVector3(0, 0, -1))

            _ = proj.light?.gobo // ensure property exists
            proj.light?.gobo?.contents = out
            proj.light?.gobo?.intensity = 1.0
            proj.light?.gobo?.wrapS = .clamp
            proj.light?.gobo?.wrapT = .clamp
            proj.light?.gobo?.minificationFilter = .linear
            proj.light?.gobo?.magnificationFilter = .linear
        }

        // World-anchored domain near camera; snap to grid to avoid swimming
        let pov = (scnView?.pointOfView ?? camNode).presentation
        let camPos = pov.simdWorldPosition

        let grid: Float = 256.0
        let anchor = simd_float2(
            round(camPos.x / grid) * grid,
            round(camPos.z / grid) * grid
        )

        // Throttle compute to ~5 Hz
        let tNow = CACurrentMediaTime()
        let tPrev = (sunLightNode?.value(forKey: "GL_shadowT") as? CFTimeInterval) ?? 0
        if tNow - tPrev < 0.20 { return }
        sunLightNode?.setValue(tNow, forKey: "GL_shadowT")

        // ---- Uniforms
        var u = CloudUniforms(
            sunDirWorld: simd_float4(sunDirWorld.x, sunDirWorld.y, sunDirWorld.z, 0),
            sunTint    : simd_float4(1, 1, 1, 1),
            params0    : simd_float4(Float(tNow), cloudWind.x, cloudWind.y, 400.0),
            params1    : simd_float4(1400.0, 0.44, 3.6, 0.0),   // topY, coverage, densityMul
            params2    : simd_float4(0, 0, 0.10, 0.75),         // horizon lift, detailMul
            params3    : simd_float4(cloudDomainOffset.x, cloudDomainOffset.y, 0.0, 0.0)
        )
        var su = ShadowUniforms(centerXZ: anchor, halfSize: 560.0)

        // ---- Billboard clusters (may be empty if using volumetric-only sky)
        let clusters = buildShadowClusters(centerXZ: anchor, halfSize: su.halfSize)

        guard
            let device = scnView?.device,
            let bufU   = device.makeBuffer(length: MemoryLayout<CloudUniforms>.stride, options: .storageModeShared),
            let bufS   = device.makeBuffer(length: MemoryLayout<ShadowUniforms>.stride, options: .storageModeShared),
            let cmd    = q.makeCommandBuffer(),
            let enc    = cmd.makeComputeCommandEncoder()
        else { return }

        memcpy(bufU.contents(), &u, MemoryLayout<CloudUniforms>.stride)
        memcpy(bufS.contents(), &su, MemoryLayout<ShadowUniforms>.stride)

        // Cluster buffers — ALWAYS bind something at index 2
        let emptyBuf = sunLightNode?.value(forKey: "GL_emptyClusters") as! MTLBuffer
        var nC: UInt32 = UInt32(clusters.count)
        let bufC: MTLBuffer? = clusters.isEmpty
            ? nil
            : device.makeBuffer(bytes: clusters,
                                length: clusters.count * MemoryLayout<Cluster>.stride,
                                options: .storageModeShared)

        enc.setComputePipelineState(pipe)
        enc.setTexture(out, index: 0)
        enc.setBuffer(bufU, offset: 0, index: 0)
        enc.setBuffer(bufS, offset: 0, index: 1)
        enc.setBuffer(emptyBuf, offset: 0, index: 2)
        if let bufC { enc.setBuffer(bufC, offset: 0, index: 2) }
        enc.setBytes(&nC, length: MemoryLayout<UInt32>.stride, index: 3)

        let w = pipe.threadExecutionWidth
        let h = max(1, pipe.maxTotalThreadsPerThreadgroup / w)
        enc.dispatchThreads(
            MTLSize(width: out.width, height: out.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1)
        )
        enc.endEncoding()
        cmd.commit()
    }

    // Build compact set of billboard clusters (OK if empty w/ volumetrics)
    @MainActor
    private func buildShadowClusters(centerXZ: simd_float2, halfSize: Float) -> [Cluster] {
        guard let layer = skyAnchor.childNode(withName: "CumulusBillboardLayer", recursively: true) else {
            return []
        }

        let margin: Float = max(80.0, halfSize * 0.12)
        let minRad: Float = 80.0

        var out: [Cluster] = []
        out.reserveCapacity(128)

        for group in layer.childNodes {
            // Centroid cache (safe with SCNVector3)
            let centroidLocal: simd_float3 = {
                if let cached = group.value(forKey: "GL_centroidLocal") as? NSValue {
                    let v = cached.scnVector3Value
                    return simd_float3(Float(v.x), Float(v.y), Float(v.z))
                }
                var sum = simd_float3.zero
                var n = 0
                for bb in group.childNodes {
                    if let cs = bb.constraints, cs.contains(where: { $0 is SCNBillboardConstraint }) {
                        sum += bb.simdPosition; n += 1
                    }
                }
                let c = (n > 0) ? (sum / Float(n)) : .zero
                group.setValue(NSValue(scnVector3: SCNVector3(CGFloat(c.x), CGFloat(c.y), CGFloat(c.z))),
                               forKey: "GL_centroidLocal")
                return c
            }()

            let radiusLocal: Float = {
                if let cached = group.value(forKey: "GL_radiusLocal") as? NSNumber {
                    return cached.floatValue
                }
                var r: Float = 0
                for bb in group.childNodes {
                    guard let plane = bb.childNodes.first?.geometry as? SCNPlane else { continue }
                    r = max(r, Float(plane.width) * 0.5)
                }
                r *= 0.90
                group.setValue(NSNumber(value: r), forKey: "GL_radiusLocal")
                return r
            }()

            let cw = centroidLocal + group.presentation.simdWorldPosition

            if abs(cw.x - centerXZ.x) > (halfSize + radiusLocal + margin) { continue }
            if abs(cw.z - centerXZ.y) > (halfSize + radiusLocal + margin) { continue }

            out.append(Cluster(pos: cw, rad: max(minRad, radiusLocal)))
        }

        if out.isEmpty { return [] }

        out.sort {
            let a = $0.pos, b = $1.pos
            let da = hypot(a.x - centerXZ.x, a.z - centerXZ.y)
            let db = hypot(b.x - centerXZ.x, b.z - centerXZ.y)
            return da < db
        }

        let cap = min(out.count, 128)
        return Array(out.prefix(cap))
    }

    // Billboard-cover estimator used only for halo aesthetics
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
