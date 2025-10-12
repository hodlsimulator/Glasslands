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
import Metal
import simd
import QuartzCore

// Must match CloudShadowMap.metal
private struct CloudUniforms {
    var sunDirWorld : SIMD4<Float>
    var sunTint     : SIMD4<Float>
    var params0     : SIMD4<Float> // x=time, y=wind.x, z=wind.y, w=baseY
    var params1     : SIMD4<Float> // x=topY, y=coverage, z=densityMul, w=stepMul
    var params2     : SIMD4<Float> // x=mieG, y=powderK, z=horizonLift, w=detailMul
    var params3     : SIMD4<Float> // x=domainOffX, y=domainOffY, z=domainRotate, w=puffScale
}

private struct ShadowUniforms {
    var centerXZ : SIMD2<Float>
    var halfSize : Float
    var pad0     : Float = 0
}

private struct ClusterRec {
    var pos : SIMD3<Float>
    var rad : Float
}

/// All state is MainActor-isolated so SceneKit/Metal setup and flags stay on one thread.
@MainActor
private final class SunDiffusionState {
    static let shared = SunDiffusionState()

    // GPU
    private var device: MTLDevice?
    private var queue:  MTLCommandQueue?
    private var pipe:   MTLComputePipelineState?
    private var lib:    MTLLibrary?

    // Double-buffered shadow maps (A ↔ B)
    private var texA: MTLTexture?
    private var texB: MTLTexture?
    private var propA = SCNMaterialProperty(contents: UIColor.white)
    private var propB = SCNMaterialProperty(contents: UIColor.white)

    // Dummy buffer for clusters==0 (Metal validation)
    private var emptyClusterBuf: MTLBuffer?

    // In-flight throttle
    fileprivate var encodeInFlight = false

    // Blend & recenter bookkeeping
    private var centreA = simd_float2(repeating: 0)
    private var centreB = simd_float2(repeating: 0)
    private var halfA: Float = 1
    private var halfB: Float = 1
    private var blend: Float = 1.0
    private var lastBlendTick: CFTimeInterval = CACurrentMediaTime()
    private var needsEncodeA = true
    private var needsEncodeB = true
    private var ping = false

    // Tunables
    fileprivate func defaultHalfSize(cfg: FirstPersonEngine.Config) -> Float {
        let chunk = cfg.tileSize * Float(cfg.chunkTiles.x) // e.g. 16*64 = 1024
        return max(700, chunk * 0.8)                       // ~820 by default
    }
    private let texSize = 512
    private let recenterFrac: Float = 0.45
    private let blendTime: CFTimeInterval = 0.35
    
    private var compilingPipe = false

    func ensureGPU(view: SCNView) {
        if device == nil {
            device = view.device ?? MTLCreateSystemDefaultDevice()
            if let d = device {
                queue = d.makeCommandQueue()
                lib   = d.makeDefaultLibrary()

                var zero = ClusterRec(pos: .init(0, 0, 0), rad: 0)
                emptyClusterBuf = d.makeBuffer(bytes: &zero,
                                               length: MemoryLayout<ClusterRec>.stride,
                                               options: [])
            }
        }

        // (Re)create textures if needed
        if texA == nil || texA?.width != texSize {
            texA = makeShadowTex(device)
            texB = makeShadowTex(device)

            propA.wrapS = .clamp; propA.wrapT = .clamp
            propB.wrapS = .clamp; propB.wrapT = .clamp
            propA.minificationFilter = .linear; propA.magnificationFilter = .linear
            propB.minificationFilter = .linear; propB.magnificationFilter = .linear

            needsEncodeA = true; needsEncodeB = true
            blend = 1.0
        }

        // Build compute pipeline asynchronously once, without capturing main-actor state in a Sendable closure.
        if pipe == nil, compilingPipe == false, let d = device, let lib, let fn = lib.makeFunction(name: "cloudShadowKernel") {
            compilingPipe = true
            if #available(iOS 14.0, macOS 11.0, *) {
                d.makeComputePipelineState(function: fn, options: []) { [weak self] state, _, _ in
                    // hop back to main to publish
                    DispatchQueue.main.async {
                        self?.pipe = state
                        self?.compilingPipe = false
                    }
                }
            } else {
                // Fallback: compile off-main, then publish on main
                let dev = d
                let fun = fn
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    let state = try? dev.makeComputePipelineState(function: fun)
                    DispatchQueue.main.async {
                        self?.pipe = state
                        self?.compilingPipe = false
                    }
                }
            }
        }
    }

    private func makeShadowTex(_ d: MTLDevice?) -> MTLTexture? {
        guard let d else { return nil }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: texSize, height: texSize, mipmapped: false)
        desc.usage = [.shaderWrite, .shaderRead]
        desc.storageMode = .private
        return d.makeTexture(descriptor: desc)
    }

    func stepBlend(now: CFTimeInterval = CACurrentMediaTime()) {
        let dt = max(0, now - lastBlendTick)
        lastBlendTick = now
        if blend < 1.0 {
            let inc = Float(dt / blendTime)
            blend = min(1.0, blend + inc)
        }
    }

    // Encodes a single map; completion flips the in-flight flag back on the main actor.
    private func encodeMap(
        to tex: MTLTexture?,
        centre: simd_float2,
        half: Float,
        uniforms u: CloudUniforms,
        clusters: UnsafeRawPointer?,
        clusterBytes: Int,
        nClusters: Int
    ) {
        guard let queue, let pipe, let device, let tex else {
            encodeInFlight = false
            return
        }
        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else {
            encodeInFlight = false
            return
        }

        enc.setComputePipelineState(pipe)
        enc.setTexture(tex, index: 0)

        var U = u
        let ubuf = device.makeBuffer(bytes: &U,
                                     length: MemoryLayout<CloudUniforms>.stride,
                                     options: [])
        enc.setBuffer(ubuf, offset: 0, index: 0)

        var SU = ShadowUniforms(centerXZ: centre, halfSize: max(1, half))
        let sbuf = device.makeBuffer(bytes: &SU,
                                     length: MemoryLayout<ShadowUniforms>.stride,
                                     options: [])
        enc.setBuffer(sbuf, offset: 0, index: 1)

        if let clusters, clusterBytes > 0, nClusters > 0 {
            let cbuf = device.makeBuffer(bytes: clusters, length: clusterBytes, options: [])
            enc.setBuffer(cbuf, offset: 0, index: 2)
        } else {
            enc.setBuffer(emptyClusterBuf, offset: 0, index: 2)
        }

        var n = UInt32(max(0, nClusters))
        let nbuf = device.makeBuffer(bytes: &n,
                                     length: MemoryLayout<UInt32>.stride,
                                     options: [])
        enc.setBuffer(nbuf, offset: 0, index: 3)

        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let ng = MTLSize(width: (tex.width  + 15) / 16,
                         height: (tex.height + 15) / 16,
                         depth: 1)
        enc.dispatchThreadgroups(ng, threadsPerThreadgroup: tg)
        enc.endEncoding()

        cmd.addCompletedHandler { [weak self] _ in
            // publish on the main actor without capturing main-actor state in a sendable context
            DispatchQueue.main.async { self?.encodeInFlight = false }
        }
        cmd.commit()
    }

    func bindToMaterials() {
        guard let texA, let texB else { return }
        if propA.contents as? MTLTexture !== texA { propA.contents = texA }
        if propB.contents as? MTLTexture !== texB { propB.contents = texB }

        let p0 = NSValue(scnVector3: SCNVector3(centreA.x, centreA.y, halfA))
        let p1 = NSValue(scnVector3: SCNVector3(centreB.x, centreB.y, halfB))
        let mixNum = NSNumber(value: Double(blend)) // keep type stable (Double)

        for m in GroundShadowMaterials.shared.all() {
            m.setValue(propA, forKey: "gl_shadowTex0")
            m.setValue(propB, forKey: "gl_shadowTex1")
            m.setValue(p0, forKey: "gl_shadowParams0")
            m.setValue(p1, forKey: "gl_shadowParams1")
            m.setValue(mixNum, forKey: "gl_shadowMix")
        }
    }

    func plan(centreWanted: SIMD2<Float>, halfWanted: Float) {
        if blend >= 1.0 {
            let activeC = ping ? centreB : centreA
            let activeH = ping ? halfB   : halfA
            let dx = centreWanted.x - activeC.x
            let dz = centreWanted.y - activeC.y
            let dist = sqrt(dx*dx + dz*dz)
            if dist > max(1, activeH * recenterFrac) || abs(halfWanted - activeH) > 1 {
                ping.toggle()
                if ping {
                    centreB = quantise(centreWanted); halfB = halfWanted; needsEncodeB = true
                } else {
                    centreA = quantise(centreWanted); halfA = halfWanted; needsEncodeA = true
                }
                blend = 0.0
                lastBlendTick = CACurrentMediaTime()
            }
        }
        if centreA == .zero && centreB == .zero && blend == 1.0 {
            centreA = quantise(centreWanted)
            centreB = centreA
            halfA = halfWanted
            halfB = halfWanted
            needsEncodeA = true
            needsEncodeB = true
            blend = 1.0
        }
    }

    private func quantise(_ c: SIMD2<Float>, step: Float = 32) -> SIMD2<Float> {
        SIMD2<Float>(round(c.x / step) * step, round(c.y / step) * step)
    }

    // One encode per call; completion resets the throttle.
    func encodeIfNeeded(uniforms U: CloudUniforms, clusters: [ClusterRec]) {
        if encodeInFlight { return }

        let ptr = clusters.withUnsafeBytes { $0.baseAddress }
        let bytes = clusters.count * MemoryLayout<ClusterRec>.stride

        if needsEncodeA {
            encodeInFlight = true
            encodeMap(to: texA, centre: centreA, half: halfA, uniforms: U,
                      clusters: ptr, clusterBytes: bytes, nClusters: clusters.count)
            needsEncodeA = false
            return
        }

        if needsEncodeB {
            encodeInFlight = true
            encodeMap(to: texB, centre: centreB, half: halfB, uniforms: U,
                      clusters: ptr, clusterBytes: bytes, nClusters: clusters.count)
            needsEncodeB = false
            return
        }
    }
}

extension FirstPersonEngine {

    /// Called each render tick by RendererProxy (MainActor).
    @MainActor
    func updateSunDiffusion() {
        guard let view = scnView else { return }
        let S = SunDiffusionState.shared
        S.ensureGPU(view: view)
        
        // If the billboard layer is hidden by zenith-cull, skip the shadow encode this frame.
        if let layer = skyAnchor.childNode(withName: "CumulusBillboardLayer", recursively: true), layer.isHidden {
            return
        }

        // Giant, cross-faded ground-shadow tile centred near the player.
        let pos = yawNode.presentation.simdWorldPosition
        let centre = SIMD2<Float>(pos.x, pos.z)
        let half   = S.defaultHalfSize(cfg: cfg)

        S.plan(centreWanted: centre, halfWanted: half)
        S.stepBlend()

        // Pull uniforms from the volumetric cloud store.
        let uSnap = VolCloudUniformsStore.shared.snapshot()
        let U = CloudUniforms(
            sunDirWorld: SIMD4<Float>(uSnap.sunDirWorld.x, uSnap.sunDirWorld.y, uSnap.sunDirWorld.z, 0),
            sunTint    : SIMD4<Float>(1, 1, 1, 0),
            params0    : uSnap.params0,
            params1    : uSnap.params1,
            params2    : uSnap.params2,
            params3    : uSnap.params3
        )

        // Lightweight path for now.
        let clusters: [ClusterRec] = []

        // Encode if needed, then bind maps/params to materials.
        S.encodeIfNeeded(uniforms: U, clusters: clusters)
        S.bindToMaterials()
    }
}

@MainActor
extension FirstPersonEngine {
    func prewarmSunDiffusion() {
        guard let v = scnView else { return }
        SunDiffusionState.shared.ensureGPU(view: v)
    }
}
