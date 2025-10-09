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

    // MARK: Sun diffusion + cloud-ground shadows (projector + surface shader)
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
        sun.shadowSampleCount = max(1, Int(round(6 + D * 8)))
        sun.shadowColor = UIColor(white: 0.0, alpha: 0.70)

        ensureCloudShadowProjector()
        updateCloudShadowMap()
    }

    // MARK: Setup
    @MainActor
    private func ensureCloudShadowProjector() {
        guard let view = scnView, let device = view.device else { return }

        // Command queue
        if (sunLightNode?.value(forKey: "GL_shadowQ") as? MTLCommandQueue) == nil {
            sunLightNode?.setValue(device.makeCommandQueue(), forKey: "GL_shadowQ")
        }

        // Compute pipeline
        if (sunLightNode?.value(forKey: "GL_shadowPipe") as? MTLComputePipelineState) == nil {
            guard
                let lib = try? device.makeDefaultLibrary(bundle: .main),
                let fn  = lib.makeFunction(name: "cloudShadowKernel"),
                let pipe = try? device.makeComputePipelineState(function: fn)
            else { return }
            sunLightNode?.setValue(pipe, forKey: "GL_shadowPipe")
        }

        // Two shadow textures for crossfade smoothing
        func makeShadowTex() -> MTLTexture? {
            let W = 256, H = 256
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: W, height: H, mipmapped: false
            )
            desc.usage = [.shaderWrite, .shaderRead]
            desc.storageMode = .shared
            return device.makeTexture(descriptor: desc)
        }
        if (sunLightNode?.value(forKey: "GL_shadowTexA") as? MTLTexture) == nil {
            guard let texA = makeShadowTex(), let texB = makeShadowTex() else { return }
            sunLightNode?.setValue(texA, forKey: "GL_shadowTexA")
            sunLightNode?.setValue(texB, forKey: "GL_shadowTexB")
            sunLightNode?.setValue(NSNumber(value: 1), forKey: "GL_shadowFrontIndex") // 0→A, 1→B; front initially B
            // Initialise both to white (no shade)
            for t in [texA, texB] {
                let W = t.width, H = t.height
                let white = [UInt8](repeating: 0xFF, count: W * H * 4)
                white.withUnsafeBytes { ptr in
                    t.replace(region: MTLRegionMake2D(0, 0, W, H),
                              mipmapLevel: 0, withBytes: ptr.baseAddress!, bytesPerRow: W * 4)
                }
            }
            sunLightNode?.setValue(CFTimeInterval(0), forKey: "GL_shadowFadeStart")
            sunLightNode?.setValue(CFTimeInterval(0.25), forKey: "GL_shadowFadeDur")
            sunLightNode?.setValue(CFTimeInterval(0.16), forKey: "GL_shadowUpdateInterval") // ~6 Hz
            sunLightNode?.setValue(NSValue(scnVector3: SCNVector3Zero), forKey: "GL_anchor0")
            sunLightNode?.setValue(NSValue(scnVector3: SCNVector3Zero), forKey: "GL_anchor1")
        }

        // Padded empty-clusters buffer (fixes validator crash)
        if (sunLightNode?.value(forKey: "GL_emptyClusters") as? MTLBuffer) == nil {
            let bytes = max(MemoryLayout<Cluster>.stride, 64) // >= one Cluster, headroom safe
            let buf = device.makeBuffer(length: bytes, options: .storageModeShared)!
            memset(buf.contents(), 0, bytes)
            sunLightNode?.setValue(buf, forKey: "GL_emptyClusters")
        }

        // Dedicated projector light: modulated shadows on terrain only
        if (sunLightNode?.value(forKey: "GL_shadowProjector") as? SCNNode) == nil {
            let L = SCNLight()
            L.type = .directional
            L.castsShadow = true
            L.shadowMode = .modulated
            L.shadowColor = UIColor(white: 0.0, alpha: 1.0)
            L.categoryBitMask = 0x0000_0400   // terrain only

            let N = SCNNode()
            N.name = "GL_CloudShadowProjector"
            N.light = L
            scene.rootNode.addChildNode(N)
            sunLightNode?.setValue(N, forKey: "GL_shadowProjector")
        }

        // Ensure main sun has no leftover gobo
        if let sun = sunLightNode?.light { sun.gobo?.contents = nil }
    }

    // Swift mirrors of Metal structs (match CloudShadowMap.metal)
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
        var pad0: Float = 0
    }
    private struct Cluster {
        var pos: simd_float3
        var rad: Float
    }

    // MARK: Per-frame update (compute when needed; always update crossfade + bindings)
    @MainActor
    private func updateCloudShadowMap() {
        guard
            let q    = sunLightNode?.value(forKey: "GL_shadowQ") as? MTLCommandQueue,
            let pipe = sunLightNode?.value(forKey: "GL_shadowPipe") as? MTLComputePipelineState,
            let texA = sunLightNode?.value(forKey: "GL_shadowTexA") as? MTLTexture,
            let texB = sunLightNode?.value(forKey: "GL_shadowTexB") as? MTLTexture
        else { return }

        // Current front/back textures for projector + materials
        let frontIndex = (sunLightNode?.value(forKey: "GL_shadowFrontIndex") as? NSNumber)?.intValue ?? 1
        let front = (frontIndex == 0) ? texA : texB
        let back  = (frontIndex == 0) ? texB : texA

        // Projector follows the sun; gobo = current front (no crossfade needed there)
        if let proj = sunLightNode?.value(forKey: "GL_shadowProjector") as? SCNNode {
            let origin = yawNode.presentation.position
            let dir = simd_normalize(sunDirWorld)
            let target = SCNVector3(origin.x - dir.x, origin.y - dir.y, origin.z - dir.z)
            proj.position = origin
            proj.look(at: target, up: scene.rootNode.worldUp, localFront: SCNVector3(0, 0, -1))

            _ = proj.light?.gobo
            proj.light?.gobo?.contents = front
            proj.light?.gobo?.intensity = 1.0
            proj.light?.gobo?.wrapS = .clamp
            proj.light?.gobo?.wrapT = .clamp
            proj.light?.gobo?.minificationFilter = .linear
            proj.light?.gobo?.magnificationFilter = .linear
        }

        // Grid-anchored domain with hysteresis
        let pov = (scnView?.pointOfView ?? camNode).presentation
        let camPos = pov.simdWorldPosition
        let grid: Float = 256.0
        let desired = simd_float2(
            round(camPos.x / grid) * grid,
            round(camPos.z / grid) * grid
        )

        // Previous anchors for crossfade
        let oldA0 = (sunLightNode?.value(forKey: "GL_anchor0") as? NSValue)?.scnVector3Value ?? SCNVector3Zero
        let oldA1 = (sunLightNode?.value(forKey: "GL_anchor1") as? NSValue)?.scnVector3Value ?? SCNVector3Zero
        var anchor0 = simd_float2(Float(oldA0.x), Float(oldA0.z))
        var anchor1 = simd_float2(Float(oldA1.x), Float(oldA1.z))

        // Throttle compute, but also re-compute when the desired grid cell changes
        let tNow = CACurrentMediaTime()
        let tPrev = (sunLightNode?.value(forKey: "GL_shadowT") as? CFTimeInterval) ?? 0
        let interval = (sunLightNode?.value(forKey: "GL_shadowUpdateInterval") as? CFTimeInterval) ?? 0.16
        let needCellShift = (desired.x != anchor1.x || desired.y != anchor1.y)
        let shouldCompute = (tNow - tPrev >= interval) || needCellShift

        // Compute uniforms
        var u = CloudUniforms(
            sunDirWorld: simd_float4(simd_normalize(sunDirWorld), 0),
            sunTint    : simd_float4(1, 1, 1, 1),
            params0    : simd_float4(Float(tNow), cloudWind.x, cloudWind.y, 400.0),
            params1    : simd_float4(1400.0, 0.44, 3.6, 0.0),
            params2    : simd_float4(0, 0, 0.10, 0.75),
            params3    : simd_float4(cloudDomainOffset.x, cloudDomainOffset.y, 0.0, 0.0)
        )

        // Half-size of the projected domain; keep consistent across anchors
        let halfSize: Float = 560.0

        // Smooth crossfade parameter (even if we don’t compute this frame)
        let fadeDur = (sunLightNode?.value(forKey: "GL_shadowFadeDur") as? CFTimeInterval) ?? 0.25
        let fadeStart = (sunLightNode?.value(forKey: "GL_shadowFadeStart") as? CFTimeInterval) ?? 0
        let blend = CGFloat(max(0.0, min(1.0, (fadeDur > 0) ? (tNow - fadeStart) / fadeDur : 1.0)))

        // If computing, render into back texture, then flip and restart crossfade
        if shouldCompute, let device = scnView?.device,
           let bufU = device.makeBuffer(length: MemoryLayout<CloudUniforms>.stride, options: .storageModeShared),
           let bufS = device.makeBuffer(length: MemoryLayout<ShadowUniforms>.stride, options: .storageModeShared),
           let cmd  = q.makeCommandBuffer(),
           let enc  = cmd.makeComputeCommandEncoder()
        {
            // New anchor targets the desired grid cell; old anchor becomes previous
            anchor0 = anchor1
            anchor1 = desired

            var su = ShadowUniforms(centerXZ: anchor1, halfSize: halfSize)

            memcpy(bufU.contents(), &u, MemoryLayout<CloudUniforms>.stride)
            memcpy(bufS.contents(), &su, MemoryLayout<ShadowUniforms>.stride)

            // Billboard clusters (can be empty); validator still expects a padded buffer at index 2
            let clusters = buildShadowClusters(centerXZ: anchor1, halfSize: halfSize)
            let emptyBuf = sunLightNode?.value(forKey: "GL_emptyClusters") as! MTLBuffer
            var nC: UInt32 = UInt32(clusters.count)
            let bufC: MTLBuffer? = clusters.isEmpty
                ? nil
                : device.makeBuffer(bytes: clusters,
                                    length: clusters.count * MemoryLayout<Cluster>.stride,
                                    options: .storageModeShared)

            enc.setComputePipelineState(pipe)
            enc.setTexture(back, index: 0)
            enc.setBuffer(bufU, offset: 0, index: 0)
            enc.setBuffer(bufS, offset: 0, index: 1)
            enc.setBuffer(bufC ?? emptyBuf, offset: 0, index: 2) // one or the other (crash fix)
            enc.setBytes(&nC, length: MemoryLayout<UInt32>.stride, index: 3)

            let w = pipe.threadExecutionWidth
            let h = max(1, pipe.maxTotalThreadsPerThreadgroup / w)
            enc.dispatchThreads(
                MTLSize(width: back.width, height: back.height, depth: 1),
                threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1)
            )
            enc.endEncoding()
            cmd.commit()

            // Flip front/back and start a new fade
            sunLightNode?.setValue(NSNumber(value: (frontIndex == 0) ? 1 : 0), forKey: "GL_shadowFrontIndex")
            sunLightNode?.setValue(tNow, forKey: "GL_shadowFadeStart")
            sunLightNode?.setValue(tNow, forKey: "GL_shadowT")
        }

        // Update anchors we expose to the shader (as SCNVector3 for convenience)
        sunLightNode?.setValue(NSValue(scnVector3: SCNVector3(anchor0.x, 0, anchor0.y)), forKey: "GL_anchor0")
        sunLightNode?.setValue(NSValue(scnVector3: SCNVector3(anchor1.x, 0, anchor1.y)), forKey: "GL_anchor1")

        // ---- Feed terrain materials (crossfade + params each frame)
        let params0 = NSValue(scnVector3: SCNVector3(anchor0.x, anchor0.y, halfSize))
        let params1 = NSValue(scnVector3: SCNVector3(anchor1.x, anchor1.y, halfSize))
        for mat in GroundShadowMaterials.shared.all() {
            // Bind as SCNMaterialProperty so SceneKit provides a sampler
            func setTex(_ key: String, _ tex: MTLTexture) {
                let prop: SCNMaterialProperty = (mat.value(forKey: key) as? SCNMaterialProperty)
                    ?? SCNMaterialProperty(contents: tex)
                prop.contents = tex
                prop.wrapS = .clamp; prop.wrapT = .clamp
                prop.minificationFilter = .linear; prop.magnificationFilter = .linear
                mat.setValue(prop, forKey: key)
            }
            setTex("gl_shadowTex0", front) // previous front (already shown via projector)
            setTex("gl_shadowTex1", (front === texA) ? texA : texB) // current front after flip

            mat.setValue(params0, forKey: "gl_shadowParams0")
            mat.setValue(params1, forKey: "gl_shadowParams1")
            mat.setValue(NSNumber(value: Double(blend)), forKey: "gl_shadowMix")
        }
    }

    // Build compact set of billboard clusters (OK if empty with volumetrics)
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

    @inline(__always) private func degreesToRadians(_ deg: Float) -> Float { deg * .pi / 180.0 }
}
